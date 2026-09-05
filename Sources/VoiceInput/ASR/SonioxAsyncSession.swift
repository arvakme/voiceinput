import Foundation
import os.log

/// Soniox async (batch) transcription session.
///
/// Soniox's batch API is not OpenAI-compatible. The flow (verified against
/// soniox.com/docs api-reference, June 2026) is:
///   1. `POST {base}/files` — multipart upload, field `file` → `{"id": …}`
///   2. `POST {base}/transcriptions` — JSON `{model, file_id, language_hints,
///      context}` → `{"id": …, "status": "queued"}`
///   3. `GET {base}/transcriptions/{id}` — poll until `status` is
///      `"completed"` or `"error"`
///   4. `GET {base}/transcriptions/{id}/transcript` → `{"text": …}`
/// plus best-effort `DELETE` cleanup of the file and transcription.
///
/// Nothing streams during recording: `onTranscript`/`onUtteranceEnd` stay
/// silent until `stop()` resolves, so hands-free silence auto-stop is
/// unavailable on this backend.
final class SonioxAsyncSession: TranscriptionSession {
    // MARK: - TranscriptionSession callbacks

    var onTranscript: ((TranscriptSnapshot) -> Void)?
    var onUtteranceEnd: (() -> Void)?   // Never fired by the batch backend
    var onError: ((String) -> Void)?
    var audioLevelHandler: ((Float) -> Void)? {
        didSet { capture.onLevel = audioLevelHandler }
    }

    var capturedAudioWAV: Data? { capture.capturedAudioWAV }

    var isStreaming: Bool { false }

    // MARK: - Private state

    private let settings: AppSettings
    private let vocabulary: VocabularyStore
    private let capture = AudioCapture()

    private var generation: UInt64 = 0
    private let genLock = NSLock()

    private var workTask: Task<Void, Never>?

    private let pollInterval: UInt64 = 1_000_000_000      // 1 s
    private let overallTimeout: TimeInterval = 180        // upload + queue + processing

    init(settings: AppSettings, vocabulary: VocabularyStore) {
        self.settings = settings
        self.vocabulary = vocabulary
    }

    // MARK: - TranscriptionSession

    func start() throws {
        bumpGeneration()
        try capture.start()
        Log.asr.info("SonioxAsyncSession recording started")
    }

    func stop(completion: @escaping (String) -> Void) {
        let gen = currentGeneration()
        capture.stop()

        guard let wav = capture.capturedAudioWAV, wav.count > 44 else {
            Log.asr.info("SonioxAsync: no audio captured")
            DispatchQueue.main.async { completion("") }
            return
        }

        let base = "https://api.soniox.com/v1"
        let apiKey = settings.sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.sonioxAsyncModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let hints = settings.languageHintsArray
        let terms = vocabulary.sonioxTerms

        workTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(self.overallTimeout)
            var fileID: String?
            var transcriptionID: String?
            do {
                let fid = try await self.uploadFile(wav, base: base, apiKey: apiKey)
                fileID = fid
                try Task.checkCancellation()

                let tid = try await self.createTranscription(
                    fileID: fid, model: model, hints: hints, terms: terms,
                    base: base, apiKey: apiKey
                )
                transcriptionID = tid
                try Task.checkCancellation()

                while true {
                    let status = try await self.pollStatus(id: tid, base: base, apiKey: apiKey)
                    if status.0 == "completed" { break }
                    if status.0 == "error" {
                        throw AsyncError.transcriptionFailed(status.1 ?? "transcription failed")
                    }
                    if Date() > deadline { throw AsyncError.timedOut }
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: self.pollInterval)
                }

                let text = try await self.fetchTranscript(id: tid, base: base, apiKey: apiKey)
                await self.cleanup(fileID: fileID, transcriptionID: transcriptionID,
                                   base: base, apiKey: apiKey)

                await MainActor.run {
                    guard self.isCurrent(gen) else { return }
                    let snapshot = TranscriptSnapshot(finalText: text, interimText: "")
                    self.onTranscript?(snapshot)
                    completion(text)
                }
            } catch is CancellationError {
                await self.cleanup(fileID: fileID, transcriptionID: transcriptionID,
                                   base: base, apiKey: apiKey)
            } catch {
                Log.asr.error("SonioxAsync failed: \(error.localizedDescription)")
                await self.cleanup(fileID: fileID, transcriptionID: transcriptionID,
                                   base: base, apiKey: apiKey)
                await MainActor.run {
                    guard self.isCurrent(gen) else { return }
                    self.onError?("Soniox transcription failed: \(error.localizedDescription)")
                    completion("")
                }
            }
        }
    }

    func cancel() {
        bumpGeneration()
        capture.stop()
        workTask?.cancel()
        workTask = nil
    }

    // MARK: - REST steps

    private func uploadFile(_ wav: Data, base: String, apiKey: String) async throws -> String {
        let boundary = "voiceinput-\(UUID().uuidString)"
        var request = URLRequest(url: try url(base, "files"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let json = try await send(request)
        guard let id = json["id"] as? String else { throw AsyncError.badResponse("file id missing") }
        Log.asr.debug("SonioxAsync uploaded file \(id) (\(wav.count) bytes)")
        return id
    }

    private func createTranscription(fileID: String, model: String, hints: [String],
                                     terms: [String], base: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: try url(base, "transcriptions"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model.isEmpty ? "stt-async-v5" : model,
            "file_id": fileID,
        ]
        if !hints.isEmpty { body["language_hints"] = hints }
        if !terms.isEmpty { body["context"] = ["terms": terms] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request)
        guard let id = json["id"] as? String else { throw AsyncError.badResponse("transcription id missing") }
        Log.asr.debug("SonioxAsync created transcription \(id)")
        return id
    }

    /// Returns (status, errorMessage).
    private func pollStatus(id: String, base: String, apiKey: String) async throws -> (String, String?) {
        var request = URLRequest(url: try url(base, "transcriptions/\(id)"), timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let json = try await send(request)
        let status = json["status"] as? String ?? "unknown"
        return (status, json["error_message"] as? String)
    }

    private func fetchTranscript(id: String, base: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: try url(base, "transcriptions/\(id)/transcript"), timeoutInterval: 30)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let json = try await send(request)
        if let text = json["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback: concatenate token texts (token text carries its own spacing).
        if let tokens = json["tokens"] as? [[String: Any]] {
            let text = tokens.compactMap { $0["text"] as? String }.joined()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw AsyncError.badResponse("transcript missing")
    }

    private func cleanup(fileID: String?, transcriptionID: String?, base: String, apiKey: String) async {
        for path in [transcriptionID.map { "transcriptions/\($0)" },
                     fileID.map { "files/\($0)" }].compactMap({ $0 }) {
            guard let u = try? url(base, path) else { continue }
            var request = URLRequest(url: u, timeoutInterval: 15)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: - Helpers

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["message"] as? String ?? $0["error_message"] as? String }
            throw AsyncError.http(http.statusCode, detail)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AsyncError.badResponse("not a JSON object")
        }
        return json
    }

    private func url(_ base: String, _ path: String) throws -> URL {
        guard let u = URL(string: "\(base)/\(path)") else { throw AsyncError.badResponse("bad URL") }
        return u
    }

    private func bumpGeneration() {
        genLock.lock(); defer { genLock.unlock() }
        generation &+= 1
    }

    private func currentGeneration() -> UInt64 {
        genLock.lock(); defer { genLock.unlock() }
        return generation
    }

    private func isCurrent(_ gen: UInt64) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return gen == generation
    }

    private enum AsyncError: LocalizedError {
        case badResponse(String)
        case http(Int, String?)
        case transcriptionFailed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .badResponse(let why):        return "Unexpected response (\(why))"
            case .http(let code, let detail):  return "HTTP \(code)\(detail.map { ": \($0)" } ?? "")"
            case .transcriptionFailed(let m):  return m
            case .timedOut:                    return "Timed out waiting for transcription"
            }
        }
    }
}
