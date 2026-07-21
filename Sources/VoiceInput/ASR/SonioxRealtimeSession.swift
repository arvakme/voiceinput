import AVFoundation
import Foundation
import os.log

/// Single source of truth for the realtime model fallback used whenever a
/// per-field default is empty — config frames here and in `SonioxListenSession`,
/// plus Settings UI placeholders/labels. `stt-rt-v4` retired 2026-06-30.
enum SonioxDefaults {
    static let realtimeModel = "stt-rt-v5"
}

/// Soniox real-time transcription over a WebSocket.
///
/// Protocol summary (from docs/research/soniox-realtime-api.md):
/// 1. Open `wss://stt-rt.soniox.com/transcribe-websocket`.
/// 2. Send a single JSON config text frame as the first message.
/// 3. Stream binary PCM frames from `AudioCapture.onChunk`.
/// 4. Accumulate `is_final == true` tokens (immutable once received).
///    Per each response, replace interim tokens with the message's non-finals.
///    Filter `<end>` (→ `onUtteranceEnd`) and `<fin>` from displayed text.
/// 5. `stop()`: send `{"type":"finalize"}`, then an empty `Data()` binary frame,
///    await `"finished": true` (3 s timeout → fall back to accumulated finals),
///    cancel the WebSocket.
/// 6. Keepalive: send `{"type":"keepalive"}` every 8 s.
/// 7. Generation counter: invalidate stale callbacks across sessions.
/// 8. On WS error mid-session: report via `onError` but **preserve** accumulated finals.
final class SonioxRealtimeSession: TranscriptionSession {
    // MARK: - TranscriptionSession callbacks

    var onTranscript: ((TranscriptSnapshot) -> Void)?
    var onUtteranceEnd: (() -> Void)?
    var onError: ((String) -> Void)?
    var audioLevelHandler: ((Float) -> Void)? {
        didSet { capture.onLevel = audioLevelHandler }
    }

    /// Captured session audio as a WAV (materialised lazily on read).
    var capturedAudioWAV: Data? { capture.capturedAudioWAV }

    var isStreaming: Bool { true }

    // MARK: - Private constants

    private static let websocketURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private static let keepaliveInterval: TimeInterval = 8
    private static let finalizeTimeoutInterval: TimeInterval = 3
    /// Soniox allows 500–3000 (default 2000); lower = snappier hands-free stop,
    /// safe for dictation since finals are append-only regardless of when it fires.
    private static let maxEndpointDelayMs = 1000

    // MARK: - Private state

    private let settings: AppSettings
    private let vocabulary: VocabularyStore
    private let capture = AudioCapture()
    private let wsQueue = DispatchQueue(label: "com.zhijie.VoiceInput.SonioxWS")

    /// Generation counter — increment on every `start()` or `cancel()` so
    /// stale async callbacks are silently dropped.
    private var generation: UInt64 = 0
    private let genLock = NSLock()

    // Protected by wsQueue:
    private var wsTask: URLSessionWebSocketTask?
    private var accumulatedFinals: [String] = []  // immutable once appended
    private var currentInterims: [String] = []    // fully replaced each message
    private var reportedError = false
    private var isFinalized = false
    private var stopCompletion: ((String) -> Void)?

    // Keepalive timer (main thread).
    private var keepaliveTimer: Timer?

    // MARK: - Init

    init(settings: AppSettings, vocabulary: VocabularyStore) {
        self.settings = settings
        self.vocabulary = vocabulary
    }

    // MARK: - TranscriptionSession

    func start() throws {
        let gen = newGeneration()

        // Wire audio capture.
        capture.onLevel = audioLevelHandler
        capture.onChunk = { [weak self] data in
            self?.sendAudioChunk(data, gen: gen)
        }

        try capture.start()
        openWebSocket(gen: gen)
        startKeepalive(gen: gen)
        Log.asr.info("SonioxRealtimeSession started, gen=\(gen)")
    }

    func stop(completion: @escaping (String) -> Void) {
        let gen = currentGeneration()
        Log.asr.info("SonioxRealtimeSession stop(), gen=\(gen)")

        // Stop audio capture first so no new frames are enqueued.
        capture.stop()
        stopKeepalive()

        wsQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion("") }
                return
            }
            guard self.isCurrentGen(gen) else {
                DispatchQueue.main.async { completion("") }
                return
            }

            // Defence-in-depth: a second stop() on the same live session must not
            // clobber the first call's completion (which still awaits the real
            // final text) nor re-send finalize/empty frames. Deliver "" and bail.
            guard self.stopCompletion == nil else {
                Log.asr.debug("SonioxRealtimeSession: duplicate stop() ignored")
                DispatchQueue.main.async { completion("") }
                return
            }

            self.stopCompletion = completion
            self.isFinalized = true

            // Send finalize control frame.
            self.sendTextOnQueue("{\"type\":\"finalize\"}")
            // Send empty binary frame to signal end-of-audio.
            self.wsTask?.send(.data(Data())) { _ in }

            // 3-second timeout fallback.
            let deadline = DispatchTime.now() + SonioxRealtimeSession.finalizeTimeoutInterval
            self.wsQueue.asyncAfter(deadline: deadline) { [weak self] in
                guard let self,
                      self.isCurrentGen(gen),
                      let cb = self.stopCompletion else { return }
                // Timeout — deliver best available text.
                Log.asr.warning("SonioxRealtimeSession: finalize timeout, delivering accumulated finals")
                self.stopCompletion = nil
                let text = self.buildFinalText()
                self.tearDownWebSocketOnQueue()
                DispatchQueue.main.async { cb(text) }
            }
        }
    }

    func cancel() {
        _ = newGeneration()
        capture.stop()
        stopKeepalive()
        wsQueue.async { [weak self] in
            self?.tearDownWebSocketOnQueue()
            self?.stopCompletion = nil
        }
        Log.asr.info("SonioxRealtimeSession cancelled")
    }

    // MARK: - WebSocket setup

    private func openWebSocket(gen: UInt64) {
        wsQueue.async { [weak self] in
            guard let self, self.isCurrentGen(gen) else { return }
            self.tearDownWebSocketOnQueue()

            let task = URLSession.shared.webSocketTask(with: SonioxRealtimeSession.websocketURL)
            self.wsTask = task
            self.accumulatedFinals = []
            self.currentInterims = []
            self.reportedError = false
            self.isFinalized = false

            task.resume()
            self.sendConfigFrameOnQueue()
            self.receiveLoop(task: task, gen: gen)
            Log.asr.debug("SonioxRealtimeSession WebSocket opened")
        }
    }

    private func sendConfigFrameOnQueue() {
        let apiKey = settings.sonioxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.sonioxModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let langHints = settings.languageHintsArray  // already parsed

        var config: [String: Any] = [
            "api_key": apiKey.isEmpty ? "" : apiKey,
            "model": model.isEmpty ? SonioxDefaults.realtimeModel : model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "enable_language_identification": true,
            "enable_endpoint_detection": true,
            "max_endpoint_delay_ms": SonioxRealtimeSession.maxEndpointDelayMs,
        ]

        if !langHints.isEmpty {
            config["language_hints"] = langHints
        }

        // Vocabulary context — include only when there are terms.
        let terms = vocabulary.sonioxTerms
        if !terms.isEmpty {
            config["context"] = ["terms": terms]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else {
            Log.asr.error("SonioxRealtimeSession: failed to encode config frame")
            return
        }

        sendTextOnQueue(json)
        Log.asr.debug("SonioxRealtimeSession: sent config frame")
    }

    // MARK: - Receive loop

    private func receiveLoop(task: URLSessionWebSocketTask, gen: UInt64) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.wsQueue.async {
                guard self.isCurrentGen(gen), self.wsTask === task else { return }
                switch result {
                case .success(let message):
                    let shouldContinue = self.handleMessage(message, gen: gen)
                    if shouldContinue {
                        self.receiveLoop(task: task, gen: gen)
                    }
                case .failure(let error):
                    let nsErr = error as NSError
                    // Cancellation is not an error from our side.
                    if nsErr.code == NSURLErrorCancelled { return }
                    let msg = "WebSocket receive error: \(error.localizedDescription)"
                    Log.asr.error("SonioxRealtimeSession: \(msg)")
                    // Preserve accumulated finals; report error but don't clear state.
                    if !self.reportedError {
                        self.reportedError = true
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.isCurrentGen(gen) else { return }
                            self.onError?(msg)
                        }
                    }
                    // The socket is dead — no "finished" frame will ever arrive.
                    // If a stop() is awaiting finalization, deliver the accumulated
                    // finals now instead of waiting out the full 3 s timeout.
                    if let cb = self.stopCompletion {
                        self.stopCompletion = nil
                        let text = self.buildFinalText()
                        self.tearDownWebSocketOnQueue()
                        DispatchQueue.main.async { cb(text) }
                    }
                }
            }
        }
    }

    // MARK: - Message handling

    /// Returns false when the receive loop should stop (session finished or fatal error).
    private func handleMessage(_ message: URLSessionWebSocketTask.Message, gen: UInt64) -> Bool {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let d): data = d
        @unknown default: return true
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.asr.debug("SonioxRealtimeSession: unparseable message")
            return true
        }

        // ── Check for API error ─────────────────────────────────────────────
        if let errorCode = json["error_code"] as? Int {
            let errType = json["error_type"] as? String ?? "unknown"
            let errMsg = json["error_message"] as? String ?? "Soniox error \(errorCode)"
            let fullMsg = "Soniox \(errorCode) (\(errType)): \(errMsg)"
            Log.asr.error("SonioxRealtimeSession: \(fullMsg)")
            if !reportedError {
                reportedError = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentGen(gen) else { return }
                    self.onError?(fullMsg)
                }
            }
            // Don't return false — accumulate any tokens that might follow.
            return true
        }

        // ── Process tokens ──────────────────────────────────────────────────
        var newInterims = [String]()
        var uttEndFired = false
        var appendedFinal = false

        let tokens = json["tokens"] as? [[String: Any]]
        if let tokens {
            for token in tokens {
                guard let text = token["text"] as? String else { continue }
                let isFinal = token["is_final"] as? Bool ?? false

                if text == "<end>" {
                    // Endpoint detection marker: fire onUtteranceEnd, don't display.
                    if isFinal {
                        uttEndFired = true
                    } else {
                        // Per the Soniox spec <end> is always is_final:true. A
                        // non-final <end> would be an API regression; surface it
                        // so it's visible during integration testing rather than
                        // silently swallowed.
                        Log.asr.warning("SonioxRealtimeSession: received non-final <end> token (unexpected)")
                    }
                    continue
                }

                if text == "<fin>" {
                    // Finalize marker: ignore from display.
                    continue
                }

                if isFinal {
                    accumulatedFinals.append(text)
                    appendedFinal = true
                } else {
                    newInterims.append(text)
                }
            }
        }

        // Only touch interim state / emit a snapshot for messages that actually
        // carried a `tokens` array. Control-only frames (e.g. the `finished`
        // termination frame) must NOT wipe accumulated interims or trigger a
        // redundant onTranscript redraw before the completion callback fires.
        if tokens != nil {
            // Replacing a previously non-empty interim run with empty is itself a
            // visible change, so detect that before overwriting.
            let interimsChanged = newInterims != currentInterims
            currentInterims = newInterims

            // Skip the main-thread redraw when nothing the UI shows actually
            // moved (e.g. a frame whose only token was <end>/<fin>): no new
            // committed final and the interim run is unchanged.
            if appendedFinal || interimsChanged {
                let snapshot = buildSnapshot()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentGen(gen) else { return }
                    self.onTranscript?(snapshot)
                }
            }
        }

        // The utterance-end marker drives the hands-free silence countdown, so it
        // must fire even on a tokens frame whose only content was <end>.
        if uttEndFired {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentGen(gen) else { return }
                self.onUtteranceEnd?()
            }
        }

        // ── Check for session-finished flag ─────────────────────────────────
        if let finished = json["finished"] as? Bool, finished {
            Log.asr.info("SonioxRealtimeSession: server indicated finished")
            if let cb = stopCompletion {
                stopCompletion = nil
                let text = buildFinalText()
                tearDownWebSocketOnQueue()
                DispatchQueue.main.async { cb(text) }
            } else {
                tearDownWebSocketOnQueue()
            }
            return false
        }

        return true
    }

    // MARK: - Sending helpers

    private func sendAudioChunk(_ data: Data, gen: UInt64) {
        wsQueue.async { [weak self] in
            guard let self,
                  self.isCurrentGen(gen),
                  !self.isFinalized,
                  let task = self.wsTask else { return }
            task.send(.data(data)) { error in
                if let error = error {
                    Log.asr.error("SonioxRealtimeSession: audio send error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendTextOnQueue(_ text: String) {
        wsTask?.send(.string(text)) { error in
            if let error = error {
                Log.asr.error("SonioxRealtimeSession: text send error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Keepalive

    private func startKeepalive(gen: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keepaliveTimer?.invalidate()
            self.keepaliveTimer = Timer.scheduledTimer(
                withTimeInterval: SonioxRealtimeSession.keepaliveInterval,
                repeats: true
            ) { [weak self] _ in
                self?.sendKeepalive(gen: gen)
            }
        }
    }

    private func stopKeepalive() {
        DispatchQueue.main.async { [weak self] in
            self?.keepaliveTimer?.invalidate()
            self?.keepaliveTimer = nil
        }
    }

    private func sendKeepalive(gen: UInt64) {
        wsQueue.async { [weak self] in
            guard let self, self.isCurrentGen(gen), !self.isFinalized else { return }
            self.sendTextOnQueue("{\"type\":\"keepalive\"}")
            Log.asr.debug("SonioxRealtimeSession: keepalive sent")
        }
    }

    // MARK: - Teardown

    private func tearDownWebSocketOnQueue() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
    }

    // MARK: - Transcript helpers

    private func buildSnapshot() -> TranscriptSnapshot {
        var snap = TranscriptSnapshot()
        snap.finalText = accumulatedFinals.joined()
        snap.interimText = currentInterims.joined()
        return snap
    }

    private func buildFinalText() -> String {
        // On the normal finished:true path currentInterims is always empty (the
        // server finalizes everything before sending it), so appending here is a
        // no-op there and only rescues the last un-finalized utterance on the
        // timeout/error fallback paths — the transcript is sacred.
        let text = (accumulatedFinals.joined() + currentInterims.joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
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
