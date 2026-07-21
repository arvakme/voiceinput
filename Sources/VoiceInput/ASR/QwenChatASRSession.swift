import AVFoundation
import Foundation
import os.log

/// Qwen3-ASR (Alibaba DashScope) batch transcription session.
///
/// The endpoint is an OpenAI-compatible *chat completions* gateway, but ASR
/// there is NOT `/audio/transcriptions` — it's a chat completion with the
/// full session WAV embedded as base64 `input_audio` content. Verified
/// request/response shape (2026-07):
///   POST {baseURL}/chat/completions
///   {"model", "messages": [system?, user w/ input_audio],
///    "asr_options": {"enable_lid": true, "enable_itn": true}}
///   → transcript at choices[0].message.content
///
/// Like `HTTPTranscriptionSession`/`SonioxAsyncSession`, nothing streams
/// during recording: `onTranscript`/`onUtteranceEnd` stay silent until
/// `stop()` resolves, so hands-free silence auto-stop is unavailable on this
/// backend. Timeout is 60 s (long dictations → large base64 request bodies).
final class QwenChatASRSession: TranscriptionSession {
    // MARK: - TranscriptionSession callbacks

    var onTranscript: ((TranscriptSnapshot) -> Void)?
    var onUtteranceEnd: (() -> Void)?   // Never fired by the batch backend
    var onError: ((String) -> Void)?
    var audioLevelHandler: ((Float) -> Void)? {
        didSet { capture.onLevel = audioLevelHandler }
    }

    /// Captured session audio as a WAV (materialised lazily on read).
    var capturedAudioWAV: Data? { capture.capturedAudioWAV }

    var isStreaming: Bool { false }

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
        Log.asr.info("QwenChatASRSession started, gen=\(gen)")
    }

    /// Stop recording and POST the accumulated WAV as a chat-completions
    /// request with embedded audio.
    func stop(completion: @escaping (String) -> Void) {
        let gen = currentGeneration()
        Log.asr.info("QwenChatASRSession stop(), gen=\(gen)")

        // Stop first, then snapshot — stop() flushes the sub-chunk remainder,
        // so reading sessionWAV afterward captures every sample.
        capture.stop()
        let wavData = capture.sessionWAV

        guard wavData.count > 44 else {
            // No audio recorded; deliver empty string.
            Log.asr.info("QwenChatASRSession: no audio captured")
            DispatchQueue.main.async { completion("") }
            return
        }

        postChatASR(wavData: wavData, gen: gen, completion: completion)
    }

    func cancel() {
        _ = newGeneration()
        capture.stop()

        taskLock.lock()
        let task = dataTask
        dataTask = nil
        taskLock.unlock()

        task?.cancel()
        Log.asr.info("QwenChatASRSession cancelled")
    }

    // MARK: - Chat-completions upload

    private func postChatASR(wavData: Data, gen: UInt64, completion: @escaping (String) -> Void) {
        var baseURL = settings.qwenBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty { baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1" }
        while baseURL.hasSuffix("/") { baseURL.removeLast() }
        let endpointString = baseURL + "/chat/completions"
        guard let url = URL(string: endpointString) else {
            let msg = "QwenChatASRSession: invalid ASR URL '\(endpointString)'"
            Log.asr.error("\(msg)")
            deliverError(msg, gen: gen, completion: completion)
            return
        }

        let apiKey = settings.qwenAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.qwenModel.trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var messages: [[String: Any]] = []

        // Recognition-biasing context (verified to fix proper-noun casing) —
        // sent only when the user has vocabulary terms configured.
        let terms = vocabulary.sonioxTerms
        if !terms.isEmpty {
            let contextText = "转写上下文。说话人常用词汇：" + terms.joined(separator: "、") + "。英文品牌名保持原始大小写。"
            messages.append([
                "role": "system",
                "content": [["type": "text", "text": contextText]],
            ])
        }

        messages.append([
            "role": "user",
            "content": [[
                "type": "input_audio",
                "input_audio": [
                    "data": "data:audio/wav;base64,\(wavData.base64EncodedString())",
                    "format": "wav",
                ],
            ]],
        ])

        let body: [String: Any] = [
            "model": model.isEmpty ? "qwen3-asr-flash" : model,
            "messages": messages,
            "asr_options": ["enable_lid": true, "enable_itn": true],
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            let msg = "QwenChatASRSession: failed to encode request body"
            Log.asr.error("\(msg)")
            deliverError(msg, gen: gen, completion: completion)
            return
        }
        request.httpBody = httpBody

        Log.asr.info("QwenChatASRSession: POSTing \(wavData.count) audio bytes to \(endpointString)")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard self.isCurrentGen(gen) else { return }

            if let error = error {
                let nsErr = error as NSError
                if nsErr.code == NSURLErrorCancelled { return }
                let msg = "Qwen ASR request failed: \(error.localizedDescription)"
                Log.asr.error("\(msg)")
                self.deliverError(msg, gen: gen, completion: completion)
                return
            }

            guard let data = data else {
                let msg = "Qwen ASR response empty"
                Log.asr.error("\(msg)")
                self.deliverError(msg, gen: gen, completion: completion)
                return
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let raw = String(data: data, encoding: .utf8) ?? "<binary>"
                let msg = "Qwen ASR error \(http.statusCode): \(String(raw.prefix(300)))"
                Log.asr.error("\(msg)")
                self.deliverError(msg, gen: gen, completion: completion)
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                let raw = String(data: data, encoding: .utf8) ?? "<binary>"
                let msg = "Qwen ASR parse failed: \(String(raw.prefix(300)))"
                Log.asr.error("\(msg)")
                self.deliverError(msg, gen: gen, completion: completion)
                return
            }

            let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.asr.info("QwenChatASRSession: got transcript '\(String(finalText.prefix(80)))'")

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
            // Deliver empty string so caller can handle gracefully — the
            // transcript is sacred, but there is nothing recoverable to hand
            // back on a failed upload, so this is the same fallback
            // HTTPTranscriptionSession uses.
            completion("")
        }
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
