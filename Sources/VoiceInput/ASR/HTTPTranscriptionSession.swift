import AVFoundation
import Foundation
import os.log

/// HTTP batch transcription session (OpenAI-compatible `/audio/transcriptions`).
///
/// This backend records the entire session as a WAV via `AudioCapture` and
/// POSTs it as a multipart form on `stop()`.
///
/// **Important (from SPEC.md):** This backend streams nothing during recording.
/// `onTranscript` and `onUtteranceEnd` are never fired until `stop()` completes.
/// Hands-free silence auto-stop is impossible on this backend; the controller
/// must not arm the silence countdown and must rely on a user hotkey tap.
final class HTTPTranscriptionSession: TranscriptionSession {
    // MARK: - TranscriptionSession callbacks

    var onTranscript: ((TranscriptSnapshot) -> Void)?
    var onUtteranceEnd: (() -> Void)?   // Never fired by HTTP backend
    var onError: ((String) -> Void)?
    var audioLevelHandler: ((Float) -> Void)? {
        didSet { capture.onLevel = audioLevelHandler }
    }

    /// Captured session audio as a WAV (materialised lazily on read).
    var capturedAudioWAV: Data? { capture.capturedAudioWAV }

    // MARK: - Private state

    private let settings: AppSettings
    private let vocabulary: VocabularyStore
    private let capture = AudioCapture()

    /// Generation counter: incremented on each `start()` or `cancel()`.
    private var generation: UInt64 = 0
    private let genLock = NSLock()

    /// Active URLSession data task so we can cancel it.
    private var dataTask: URLSessionDataTask?
    private let taskLock = NSLock()

    // MARK: - Init

    init(settings: AppSettings, vocabulary: VocabularyStore) {
        self.settings = settings
        self.vocabulary = vocabulary
    }

    // MARK: - TranscriptionSession

    func start() throws {
        let gen = newGeneration()

        capture.onLevel = audioLevelHandler
        // onChunk is not needed — AudioCapture assembles sessionWAV internally.
        capture.onChunk = nil

        try capture.start()
        Log.asr.info("HTTPTranscriptionSession started, gen=\(gen)")
    }

    /// Stop recording and POST the accumulated WAV to the HTTP ASR endpoint.
    func stop(completion: @escaping (String) -> Void) {
        let gen = currentGeneration()
        Log.asr.info("HTTPTranscriptionSession stop(), gen=\(gen)")

        // Stop first, then snapshot — stop() flushes the sub-chunk remainder,
        // so reading sessionWAV afterward captures every sample.
        capture.stop()
        let wavData = capture.sessionWAV

        guard wavData.count > 44 else {
            // No audio recorded; deliver empty string.
            Log.asr.info("HTTPTranscriptionSession: no audio captured")
            DispatchQueue.main.async { completion("") }
            return
        }

        postTranscription(wavData: wavData, gen: gen, completion: completion)
    }

    func cancel() {
        _ = newGeneration()
        capture.stop()

        taskLock.lock()
        let task = dataTask
        dataTask = nil
        taskLock.unlock()

        task?.cancel()
        Log.asr.info("HTTPTranscriptionSession cancelled")
    }

    // MARK: - HTTP upload

    private func postTranscription(wavData: Data, gen: UInt64, completion: @escaping (String) -> Void) {
        var baseURL = settings.httpASRBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty { baseURL = "https://api.openai.com/v1" }
        while baseURL.hasSuffix("/") { baseURL.removeLast() }
        let endpointString = baseURL + "/audio/transcriptions"
        guard let url = URL(string: endpointString) else {
            let msg = "HTTPTranscriptionSession: invalid ASR URL '\(endpointString)'"
            Log.asr.error("\(msg)")
            deliverError(msg, gen: gen, completion: completion)
            return
        }

        let apiKey = settings.httpASRAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.httpASRModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundary = "VoiceInput-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Build multipart body.
        var fields: [String: String] = [
            "model": model.isEmpty ? "gpt-4o-mini-transcribe" : model,
            "response_format": "json",
        ]

        // Include language only when exactly one hint is configured (per SPEC).
        let hints = settings.languageHintsArray
        if hints.count == 1, let lang = hints.first {
            fields["language"] = lang
        }

        request.httpBody = makeMultipartBody(
            fields: fields,
            fileFieldName: "file",
            fileName: "voiceinput.wav",
            fileData: wavData,
            mimeType: "audio/wav",
            boundary: boundary
        )

        Log.asr.info("HTTPTranscriptionSession: POSTing \(wavData.count) bytes to \(endpointString)")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard self.isCurrentGen(gen) else { return }

            if let error = error {
                let nsErr = error as NSError
                if nsErr.code == NSURLErrorCancelled { return }
                let msg = "HTTP ASR request failed: \(error.localizedDescription)"
                Log.asr.error("\(msg)")
                self.deliverError(msg, gen: gen, completion: completion)
                return
            }

            guard let data = data else {
                let msg = "HTTP ASR response empty"
                Log.asr.error("\(msg)")
                self.deliverError(msg, gen: gen, completion: completion)
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let raw = String(data: data, encoding: .utf8) ?? "<binary>"
                let msg = "HTTP ASR error \(http.statusCode): \(String(raw.prefix(300)))"
                Log.asr.error("\(msg)")
                self.deliverError(msg, gen: gen, completion: completion)
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                let raw = String(data: data, encoding: .utf8) ?? "<binary>"
                let msg = "HTTP ASR parse failed: \(String(raw.prefix(300)))"
                Log.asr.error("\(msg)")
                self.deliverError(msg, gen: gen, completion: completion)
                return
            }

            let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.asr.info("HTTPTranscriptionSession: got transcript '\(String(finalText.prefix(80)))'")

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentGen(gen) else { return }
                // Emit a single transcript snapshot so consumers can observe the result.
                var snap = TranscriptSnapshot()
                snap.finalText = finalText
                snap.interimText = ""
                self.onTranscript?(snap)
                completion(finalText)
            }
        }

        taskLock.lock()
        dataTask = task
        taskLock.unlock()

        task.resume()
    }

    // MARK: - Error delivery

    private func deliverError(_ message: String, gen: UInt64, completion: @escaping (String) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentGen(gen) else { return }
            self.onError?(message)
            // Deliver empty string so caller can handle gracefully.
            completion("")
        }
    }

    // MARK: - Multipart helpers

    private func makeMultipartBody(
        fields: [String: String],
        fileFieldName: String,
        fileName: String,
        fileData: Data,
        mimeType: String,
        boundary: String
    ) -> Data {
        var body = Data()
        // Text fields — sorted for deterministic output.
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        // File field.
        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\r\n"
        )
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Generation counter

    private func newGeneration() -> UInt64 {
        genLock.lock(); defer { genLock.unlock() }
        generation &+= 1
        return generation
    }

    private func currentGeneration() -> UInt64 {
        genLock.lock(); defer { genLock.unlock() }
        return generation
    }

    private func isCurrentGen(_ gen: UInt64) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return gen == generation
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendString(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
