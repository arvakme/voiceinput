import Foundation
import os.log

/// Gemini Live API session for Live Captions.
///
/// Two configurations, chosen by whether the model id contains "translate":
///
/// - **Translate model** (`gemini-3.5-live-translate-preview`): purpose-built
///   speech translation. `responseModalities: ["AUDIO"]` is mandatory, so the
///   text we want arrives as transcription sidecars — `inputTranscription`
///   (original speech) → left column, `outputTranscription` (translation) →
///   right column. The synthesized translated audio (`modelTurn` inlineData)
///   is discarded. `translationConfig.targetLanguageCode` sets the target;
///   source language is auto-detected.
///
/// - **General live model** (e.g. `gemini-2.5-flash-native-audio`):
///   `responseModalities: ["TEXT"]` + `inputAudioTranscription` for the
///   original, and a `systemInstruction` instructs it to translate; the
///   model's text output is the translation. Cheaper for a captions-only UI.
///
/// Audio in is the shared 16 kHz mono s16le chunk format (no resampling —
/// Gemini wants exactly that). Handles `setupComplete` gating, `goAway`
/// reconnect with `sessionResumption`, and sliding-window compression to lift
/// the 15-minute audio cap. All callbacks land on the main thread.
final class GeminiListenSession: LiveCaptionSession {
    var onOriginal: ((TranscriptSnapshot) -> Void)?
    var onTranslation: ((TranscriptSnapshot) -> Void)?
    var onConnected: (() -> Void)?
    var onError: ((LiveCaptionError) -> Void)?

    private let queue = DispatchQueue(label: "VoiceInput.GeminiLive")
    private var task: URLSessionWebSocketTask?

    // Config captured at start (reused on goAway reconnect).
    private var apiKey = ""
    private var model = ""
    private var targetCode = ""
    private var targetEnglishName = ""
    private var isTranslateModel = false

    // Stream state (on `queue`).
    private var ready = false
    private var announcedConnect = false
    private var pendingAudio: [Data] = []
    private var pendingBytes = 0
    private let maxPendingBytes = 16_000 * 2 * 3   // ~3 s of 16 kHz s16le

    private var finalsOriginal = ""
    private var finalsTranslation = ""
    private var resumeHandle: String?

    private var generation: UInt64 = 0
    private let genLock = NSLock()

    // MARK: - LiveCaptionSession

    func start(settings: AppSettings) {
        apiKey = settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        model = settings.geminiLiveModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { model = "gemini-3.5-live-translate-preview" }
        isTranslateModel = model.lowercased().contains("translate")
        targetCode = ListenLanguages.bcp47(for: settings.listenTargetLanguage)
        targetEnglishName = ListenLanguages.englishName(for: settings.listenTargetLanguage)

        guard !apiKey.isEmpty else {
            DispatchQueue.main.async {
                self.onError?(.terminal("Gemini API key not configured (Settings → Providers → Live Captions)."))
            }
            return
        }

        bumpGeneration()
        let gen = currentGeneration()
        queue.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.finalsOriginal = ""
            self.finalsTranslation = ""
            self.resumeHandle = nil
            self.announcedConnect = false
            self.connectOnQueue(gen: gen)
        }
    }

    func sendAudio(_ data: Data) {
        let gen = currentGeneration()
        queue.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            guard self.ready, let task = self.task else {
                // Buffer until setupComplete; cap so a slow handshake can't grow
                // memory without bound (drop oldest).
                self.pendingAudio.append(data)
                self.pendingBytes += data.count
                while self.pendingBytes > self.maxPendingBytes, !self.pendingAudio.isEmpty {
                    self.pendingBytes -= self.pendingAudio.removeFirst().count
                }
                return
            }
            self.sendRealtimeAudio(data, task: task)
        }
    }

    func stop() {
        bumpGeneration()
        queue.async { [weak self] in self?.closeOnQueue() }
    }

    // MARK: - Connect (on `queue`)

    private func connectOnQueue(gen: UInt64, resuming: Bool = false) {
        guard isCurrent(gen) else { return }
        var components = URLComponents(string:
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return }

        ready = false
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()

        sendJSON(setupMessage(), task: task, gen: gen)
        receiveLoop(task, gen: gen)
        Log.asr.info("GeminiListenSession connecting (model=\(self.model), resuming=\(resuming))")
    }

    private func setupMessage() -> [String: Any] {
        let modelPath = model.hasPrefix("models/") ? model : "models/\(model)"

        var generationConfig: [String: Any] = [:]
        var setup: [String: Any] = ["model": modelPath]

        // IMPORTANT: inputAudioTranscription / outputAudioTranscription are
        // fields on `setup` itself, NOT on generationConfig (the server rejects
        // them under generationConfig — verified live, June 2026). Only
        // responseModalities and translationConfig live in generationConfig.
        setup["inputAudioTranscription"] = [:]

        if isTranslateModel {
            generationConfig["responseModalities"] = ["AUDIO"]
            generationConfig["translationConfig"] = [
                "targetLanguageCode": targetCode,
                "echoTargetLanguage": false,
            ]
            setup["outputAudioTranscription"] = [:]
        } else {
            generationConfig["responseModalities"] = ["TEXT"]
            setup["systemInstruction"] = [
                "parts": [["text":
                    "You are a simultaneous interpreter. Translate the speech you hear into \(targetEnglishName). "
                    + "Output ONLY the translation, no commentary, no quotation marks, no source text."]],
            ]
        }

        setup["generationConfig"] = generationConfig
        // Lift the 15-minute audio cap and allow seamless reconnects.
        setup["contextWindowCompression"] = ["slidingWindow": [:]]
        if let handle = resumeHandle {
            setup["sessionResumption"] = ["handle": handle]
        } else {
            setup["sessionResumption"] = [:]
        }
        return ["setup": setup]
    }

    private func sendRealtimeAudio(_ data: Data, task: URLSessionWebSocketTask) {
        sendJSON([
            "realtimeInput": [
                "audio": [
                    "data": data.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000",
                ],
            ],
        ], task: task, gen: currentGeneration())
    }

    // MARK: - Receive (on `queue`)

    private func receiveLoop(_ task: URLSessionWebSocketTask, gen: UInt64) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === task, self.isCurrent(gen) else { return }
                switch result {
                case .failure(let error):
                    let nsError = error as NSError
                    if nsError.code == NSURLErrorCancelled { return }
                    self.reportError(.recoverable("Gemini stream error: \(error.localizedDescription)"), gen: gen)
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let raw):    data = raw
                    @unknown default:
                        self.receiveLoop(task, gen: gen); return
                    }
                    self.handleMessageOnQueue(data, task: task, gen: gen)
                    // Don't re-arm if a goAway swapped to a fresh socket, or we
                    // were stopped — `task` would be the retired one.
                    if self.task === task, self.isCurrent(gen) {
                        self.receiveLoop(task, gen: gen)
                    }
                }
            }
        }
    }

    private func handleMessageOnQueue(_ data: Data, task: URLSessionWebSocketTask, gen: UInt64) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if root["setupComplete"] != nil {
            ready = true
            // Flush buffered audio captured during the handshake.
            let buffered = pendingAudio
            pendingAudio.removeAll()
            pendingBytes = 0
            for chunk in buffered { sendRealtimeAudio(chunk, task: task) }
            if !announcedConnect {
                announcedConnect = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(gen) else { return }
                    self.onConnected?()
                }
            }
            return
        }

        if let error = root["error"] as? [String: Any] {
            reportError(classifyError(error), gen: gen)
            return
        }

        if let server = root["serverContent"] as? [String: Any] {
            var changedOriginal = false
            var changedTranslation = false

            if let input = server["inputTranscription"] as? [String: Any],
               let text = input["text"] as? String, !text.isEmpty {
                finalsOriginal += text
                changedOriginal = true
            }

            if isTranslateModel {
                if let output = server["outputTranscription"] as? [String: Any],
                   let text = output["text"] as? String, !text.isEmpty {
                    finalsTranslation += text
                    changedTranslation = true
                }
            } else {
                // Text-model path: the translation is the model's text output.
                if let modelTurn = server["modelTurn"] as? [String: Any],
                   let parts = modelTurn["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let text = part["text"] as? String, !text.isEmpty {
                            finalsTranslation += text
                            changedTranslation = true
                        }
                    }
                }
            }

            if changedOriginal {
                let snapshot = TranscriptSnapshot(finalText: finalsOriginal, interimText: "")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(gen) else { return }
                    self.onOriginal?(snapshot)
                }
            }
            if changedTranslation {
                let snapshot = TranscriptSnapshot(finalText: finalsTranslation, interimText: "")
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(gen) else { return }
                    self.onTranslation?(snapshot)
                }
            }
        }

        if let resumption = root["sessionResumptionUpdate"] as? [String: Any] {
            if (resumption["resumable"] as? Bool) == true,
               let handle = resumption["newHandle"] as? String {
                resumeHandle = handle
            }
        }

        if root["goAway"] != nil {
            // ~60 s warning before the socket closes — reconnect now on a fresh
            // socket carrying the resumption handle, then drop the old one.
            // Return immediately so we don't re-arm receive on the old task.
            Log.asr.info("Gemini goAway — reconnecting (handle: \(self.resumeHandle != nil))")
            let oldTask = self.task
            connectOnQueue(gen: gen, resuming: true)
            oldTask?.cancel(with: .normalClosure, reason: nil)
            return
        }
    }

    // MARK: - Helpers

    private func sendJSON(_ object: [String: Any], task: URLSessionWebSocketTask, gen: UInt64) {
        guard isCurrent(gen),
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let payload = String(data: data, encoding: .utf8) else { return }
        task.send(.string(payload)) { _ in }
    }

    private func reportError(_ error: LiveCaptionError, gen: UInt64) {
        guard isCurrent(gen) else { return }
        closeOnQueue()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(gen) else { return }
            self.onError?(error)
        }
    }

    /// Google API errors carry `code` (HTTP-style) and `status` (gRPC-style);
    /// auth/config problems recur identically on retry, everything else
    /// (quota, transient 5xx) is worth a reconnect.
    private func classifyError(_ error: [String: Any]) -> LiveCaptionError {
        let message = "Gemini: " + (error["message"] as? String ?? "Gemini error")
        let code = error["code"] as? Int
        let status = (error["status"] as? String ?? "").uppercased()
        let terminalStatuses: Set<String> = [
            "UNAUTHENTICATED", "PERMISSION_DENIED", "INVALID_ARGUMENT", "FAILED_PRECONDITION",
        ]
        if let code, [400, 401, 403].contains(code) { return .terminal(message) }
        if terminalStatuses.contains(status) { return .terminal(message) }
        return .recoverable(message)
    }

    private func closeOnQueue() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        ready = false
        pendingAudio.removeAll()
        pendingBytes = 0
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
