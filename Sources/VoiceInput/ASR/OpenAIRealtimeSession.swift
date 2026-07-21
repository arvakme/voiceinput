import Foundation
import os.log

/// OpenAI Realtime transcription session (`wss://api.openai.com/v1/realtime?intent=transcription`).
///
/// Faithful port of the proven protocol from the previous app's SpeechEngine:
/// - Connect with Bearer auth, then `session.update` declaring
///   `{type: "transcription", audio.input.format {audio/pcm, 24000}, transcription {model, language?}}`.
/// - Stream base64 PCM16 via `input_audio_buffer.append`. Server VAD segments
///   utterances automatically; each yields `…transcription.delta` events
///   (interim, keyed by item_id) and a `…transcription.completed` (final).
/// - Graceful stop: commit the tail (only if ≥ 100 ms of audio is uncommitted),
///   wait for outstanding completions, 3 s timeout falls back to accumulated text.
///
/// AudioCapture delivers 16 kHz mono s16le; OpenAI's pcm format is 24 kHz, so
/// chunks are linearly upsampled 2→3 before sending.
final class OpenAIRealtimeSession: TranscriptionSession {
    // MARK: - TranscriptionSession callbacks

    var onTranscript: ((TranscriptSnapshot) -> Void)?
    var onUtteranceEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    var audioLevelHandler: ((Float) -> Void)? {
        didSet { capture.onLevel = audioLevelHandler }
    }

    var capturedAudioWAV: Data? { capture.capturedAudioWAV }

    var isStreaming: Bool { true }

    // MARK: - Private state

    private let settings: AppSettings
    private let vocabulary: VocabularyStore
    private let capture = AudioCapture()

    private let queue = DispatchQueue(label: "VoiceInput.OpenAIRealtime")
    private var task: URLSessionWebSocketTask?

    private var generation: UInt64 = 0
    private let genLock = NSLock()

    // Transcript assembly (accessed on `queue`).
    private var finalParts: [String] = []
    private var activeDeltas: [String: String] = [:]     // item_id → interim text
    private var uncommittedBytes = 0
    private var pendingCommits = 0
    private var finishing = false
    private var stopCompletion: ((String) -> Void)?

    /// 100 ms at 24 kHz mono 16-bit — OpenAI rejects smaller commits.
    private let minimumCommitBytes = 4800

    init(settings: AppSettings, vocabulary: VocabularyStore) {
        self.settings = settings
        self.vocabulary = vocabulary
    }

    // MARK: - TranscriptionSession

    func start() throws {
        bumpGeneration()
        let gen = currentGeneration()

        let apiKey = settings.httpASRAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw SessionError.message("OpenAI API key not configured (Voice model → OpenAI).")
        }
        var model = settings.openAIRealtimeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { model = "gpt-4o-mini-transcribe" }

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        guard let url = components.url else { throw SessionError.message("Invalid OpenAI Realtime URL") }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let ws = URLSession.shared.webSocketTask(with: request)
        queue.sync {
            task = ws
            finalParts = []
            activeDeltas = [:]
            uncommittedBytes = 0
            pendingCommits = 0
            finishing = false
            stopCompletion = nil
        }
        ws.resume()
        receiveLoop(ws, gen: gen)

        var transcription: [String: Any] = ["model": model]
        if let language = primaryLanguageHint { transcription["language"] = language }
        send([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transcription": transcription,
                    ],
                ],
            ],
        ])

        capture.onChunk = { [weak self] pcm16k in
            guard let self, self.isCurrent(gen) else { return }
            let pcm24k = Self.upsample16to24(pcm16k)
            self.queue.async {
                guard self.task != nil, !self.finishing else { return }
                self.uncommittedBytes += pcm24k.count
                self.sendOnQueue([
                    "type": "input_audio_buffer.append",
                    "audio": pcm24k.base64EncodedString(),
                ])
            }
        }

        try capture.start()
        Log.asr.info("OpenAIRealtimeSession started, model=\(model)")
    }

    func stop(completion: @escaping (String) -> Void) {
        let gen = currentGeneration()
        capture.stop()
        queue.async { [weak self] in
            guard let self, self.isCurrent(gen) else {
                DispatchQueue.main.async { completion("") }
                return
            }
            guard self.stopCompletion == nil else { return }   // double-stop guard
            self.stopCompletion = completion
            self.finishing = true

            if self.uncommittedBytes >= self.minimumCommitBytes {
                self.uncommittedBytes = 0
                self.pendingCommits += 1
                self.sendOnQueue(["type": "input_audio_buffer.commit"])
            } else if self.pendingCommits == 0, self.activeDeltas.isEmpty {
                self.deliverFinishOnQueue()
                return
            }

            // Timeout fallback: deliver whatever has accumulated.
            self.queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                self.deliverFinishOnQueue()
            }
        }
    }

    func cancel() {
        bumpGeneration()
        capture.stop()
        capture.onChunk = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.stopCompletion = nil
            self.closeSocketOnQueue()
        }
    }

    // MARK: - Receive loop (on `queue`)

    private func receiveLoop(_ ws: URLSessionWebSocketTask, gen: UInt64) {
        ws.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === ws, self.isCurrent(gen) else { return }
                switch result {
                case .success(let message):
                    if self.handleMessageOnQueue(message, gen: gen) {
                        self.receiveLoop(ws, gen: gen)
                    }
                case .failure(let error):
                    let nsError = error as NSError
                    if nsError.code == NSURLErrorCancelled { return }
                    if self.finishing {
                        self.deliverFinishOnQueue()
                        return
                    }
                    self.reportErrorOnQueue("OpenAI Realtime: \(error.localizedDescription)", gen: gen)
                }
            }
        }
    }

    /// Returns false to stop the receive loop.
    private func handleMessageOnQueue(_ message: URLSessionWebSocketTask.Message, gen: UInt64) -> Bool {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let d):      data = d
        @unknown default:       return true
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return true }

        switch type {
        case "input_audio_buffer.committed", "input_audio_buffer.cleared":
            uncommittedBytes = 0
            return true

        case "conversation.item.input_audio_transcription.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return true }
            let itemID = json["item_id"] as? String ?? "default"
            activeDeltas[itemID, default: ""] += delta
            emitSnapshotOnQueue(gen: gen)
            return true

        case "conversation.item.input_audio_transcription.completed":
            let itemID = json["item_id"] as? String ?? "default"
            let transcript = ((json["transcript"] as? String) ?? activeDeltas[itemID] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            activeDeltas.removeValue(forKey: itemID)
            pendingCommits = max(0, pendingCommits - 1)
            if !transcript.isEmpty { finalParts.append(transcript) }
            emitSnapshotOnQueue(gen: gen)

            // Server-VAD utterance boundary — drives hands-free silence stop.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                self.onUtteranceEnd?()
            }

            if finishing, pendingCommits == 0, activeDeltas.isEmpty {
                deliverFinishOnQueue()
                return false
            }
            return true

        case "error":
            let info = json["error"] as? [String: Any]
            let message = info?["message"] as? String ?? "OpenAI Realtime transcription failed"
            // A final tail commit with <100 ms audio yields "buffer too small";
            // that is not a real failure — finish with what we have.
            if message.contains("buffer too small") {
                pendingCommits = max(0, pendingCommits - 1)
                if finishing { deliverFinishOnQueue(); return false }
                return true
            }
            if finishing, !combinedOnQueue().isEmpty {
                deliverFinishOnQueue()
                return false
            }
            reportErrorOnQueue(message, gen: gen)
            return false

        default:
            return true
        }
    }

    // MARK: - Helpers (on `queue` unless noted)

    private func combinedOnQueue() -> String {
        let interim = activeDeltas.values.joined(separator: " ")
        return (finalParts + (interim.isEmpty ? [] : [interim]))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emitSnapshotOnQueue(gen: UInt64) {
        let finals = finalParts.joined(separator: " ")
        var interim = activeDeltas.values.joined(separator: " ")
        if !finals.isEmpty && !interim.isEmpty { interim = " " + interim }
        let snapshot = TranscriptSnapshot(finalText: finals, interimText: interim)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.onTranscript?(snapshot)
        }
    }

    private func deliverFinishOnQueue() {
        guard let completion = stopCompletion else { return }
        stopCompletion = nil
        let text = combinedOnQueue()
        closeSocketOnQueue()
        DispatchQueue.main.async { completion(text) }
    }

    private func reportErrorOnQueue(_ message: String, gen: UInt64) {
        Log.asr.error("OpenAIRealtime error: \(message)")
        let pendingStop = stopCompletion
        stopCompletion = nil
        let text = combinedOnQueue()
        closeSocketOnQueue()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            if let pendingStop {
                pendingStop(text)   // transcript is sacred: deliver best text
            } else {
                self.onError?(message)
            }
        }
    }

    private func closeSocketOnQueue() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func send(_ event: [String: Any]) {
        queue.async { [weak self] in self?.sendOnQueue(event) }
    }

    private func sendOnQueue(_ event: [String: Any]) {
        guard let task,
              JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let payload = String(data: data, encoding: .utf8) else { return }
        task.send(.string(payload)) { _ in }
    }

    private var primaryLanguageHint: String? {
        // OpenAI takes a single ISO language; only pin it when exactly one hint
        // is configured (mixed zh/en works better with auto-detect).
        let hints = settings.languageHintsArray
        return hints.count == 1 ? hints.first : nil
    }

    /// Linear 16 kHz → 24 kHz upsample of interleaved s16le data (ratio 2:3).
    static func upsample16to24(_ input: Data) -> Data {
        let sampleCount = input.count / 2
        guard sampleCount > 1 else { return input }
        var output = Data(capacity: sampleCount * 3)
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            let outCount = sampleCount * 3 / 2
            for i in 0..<outCount {
                // Position in source space.
                let pos = Double(i) * 2.0 / 3.0
                let idx = Int(pos)
                let frac = pos - Double(idx)
                let a = Double(samples[Swift.min(idx, sampleCount - 1)])
                let b = Double(samples[Swift.min(idx + 1, sampleCount - 1)])
                var value = Int(a + (b - a) * frac)
                value = Swift.max(Int(Int16.min), Swift.min(Int(Int16.max), value))
                var sample = Int16(value).littleEndian
                withUnsafeBytes(of: &sample) { output.append(contentsOf: $0) }
            }
        }
        return output
    }

    // MARK: - Generation

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

    private enum SessionError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m }
            return nil
        }
    }
}
