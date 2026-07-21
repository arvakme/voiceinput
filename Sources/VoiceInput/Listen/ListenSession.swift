import Foundation
import os.log

/// Soniox realtime session for Live Captions: streams audio (mic or system)
/// and receives BOTH original-language tokens and one-way-translated tokens on
/// the same WebSocket (`translation: {type: "one_way", target_language: …}`).
///
/// Tokens carry `translation_status`: "original" routes to the left column,
/// "translation" to the right. Standard Soniox semantics per track: finals are
/// append-only, non-finals are replaced wholesale on every message, and the
/// `<end>`/`<fin>` control tokens are filtered.
final class SonioxListenSession: LiveCaptionSession {
    /// All callbacks on the main thread.
    var onOriginal: ((TranscriptSnapshot) -> Void)?
    var onTranslation: ((TranscriptSnapshot) -> Void)?
    var onConnected: (() -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "VoiceInput.ListenWS")
    private var ws: URLSessionWebSocketTask?
    private var keepalive: DispatchSourceTimer?

    private var finalsOriginal = ""
    private var finalsTranslation = ""

    private var generation: UInt64 = 0
    private let genLock = NSLock()

    // MARK: - Lifecycle

    func start(settings: AppSettings) {
        let apiKey = settings.sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.sonioxModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let languageHints = settings.languageHintsArray
        let targetLanguage = settings.listenTargetLanguage
        let vocabularyTerms = VocabularyStore.shared.sonioxTerms

        bumpGeneration()
        let gen = currentGeneration()

        guard !apiKey.isEmpty else {
            DispatchQueue.main.async { self.onError?("Soniox API key not configured (Settings → Providers → Live Captions).") }
            return
        }
        guard let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket") else { return }

        var config: [String: Any] = [
            "api_key": apiKey,
            "model": model.isEmpty ? SonioxDefaults.realtimeModel : model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "enable_language_identification": true,
            "translation": ["type": "one_way", "target_language": targetLanguage],
        ]
        if !languageHints.isEmpty { config["language_hints"] = languageHints }
        if !vocabularyTerms.isEmpty { config["context"] = ["terms": vocabularyTerms] }

        queue.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.closeOnQueue()
            self.finalsOriginal = ""
            self.finalsTranslation = ""

            let task = URLSession.shared.webSocketTask(with: url)
            self.ws = task
            task.resume()

            if let data = try? JSONSerialization.data(withJSONObject: config),
               let json = String(data: data, encoding: .utf8) {
                task.send(.string(json)) { [weak self] error in
                    if let error {
                        self?.reportError("Listen connect failed: \(error.localizedDescription)", gen: gen)
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.isCurrent(gen) else { return }
                            self.onConnected?()
                        }
                    }
                }
            }
            self.receiveLoop(task, gen: gen)
            self.startKeepaliveOnQueue(gen: gen)
            Log.asr.info("ListenSession started target=\(targetLanguage)")
        }
    }

    /// Feed 16 kHz mono s16le audio (any thread).
    func sendAudio(_ data: Data) {
        let gen = currentGeneration()
        queue.async { [weak self] in
            guard let self, self.isCurrent(gen), let ws = self.ws else { return }
            ws.send(.data(data)) { _ in }
        }
    }

    func stop() {
        bumpGeneration()
        queue.async { [weak self] in self?.closeOnQueue() }
    }

    // MARK: - Receive (on `queue`)

    private func receiveLoop(_ task: URLSessionWebSocketTask, gen: UInt64) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.ws === task, self.isCurrent(gen) else { return }
                switch result {
                case .failure(let error):
                    let nsError = error as NSError
                    if nsError.code == NSURLErrorCancelled { return }
                    self.reportError("Listen stream error: \(error.localizedDescription)", gen: gen)
                case .success(let message):
                    if case let .string(text) = message,
                       let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let code = json["error_code"] as? Int {
                            let msg = json["error_message"] as? String ?? "error \(code)"
                            self.reportError("Soniox: \(msg)", gen: gen)
                            return
                        }
                        self.handleTokensOnQueue(json, gen: gen)
                        if json["finished"] as? Bool == true {
                            // Server closed the realtime session (e.g. the
                            // 300-minute cap). In continuous captions we never
                            // send an end frame, so surface it rather than
                            // freezing silently.
                            self.reportError("Caption stream ended — press Fn+Space to resume.", gen: gen)
                            return
                        }
                    }
                    self.receiveLoop(task, gen: gen)
                }
            }
        }
    }

    private func handleTokensOnQueue(_ json: [String: Any], gen: UInt64) {
        guard let tokens = json["tokens"] as? [[String: Any]] else { return }
        var interimOriginal = ""
        var interimTranslation = ""

        for token in tokens {
            let text = token["text"] as? String ?? ""
            if text == "<end>" || text == "<fin>" { continue }
            let isFinal = token["is_final"] as? Bool ?? false
            let isTranslation = (token["translation_status"] as? String) == "translation"

            if isFinal {
                if isTranslation { finalsTranslation += text } else { finalsOriginal += text }
            } else {
                if isTranslation { interimTranslation += text } else { interimOriginal += text }
            }
        }

        let original = TranscriptSnapshot(finalText: finalsOriginal, interimText: interimOriginal)
        let translation = TranscriptSnapshot(finalText: finalsTranslation, interimText: interimTranslation)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.onOriginal?(original)
            self.onTranslation?(translation)
        }
    }

    // MARK: - Keepalive (system audio can be silent for long stretches)

    private func startKeepaliveOnQueue(gen: UInt64) {
        keepalive?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 8, repeating: 8)
        timer.setEventHandler { [weak self] in
            guard let self, self.isCurrent(gen), let ws = self.ws else { return }
            ws.send(.string(#"{"type": "keepalive"}"#)) { _ in }
        }
        timer.resume()
        keepalive = timer
    }

    // MARK: - Helpers

    private func reportError(_ message: String, gen: UInt64) {
        queue.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.closeOnQueue()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(gen) else { return }
                self.onError?(message)
            }
        }
    }

    private func closeOnQueue() {
        keepalive?.cancel()
        keepalive = nil
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
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
}
