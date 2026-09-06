import AppKit
import Combine
import os.log

// MARK: - ListenState

/// Reactive state for the Live Captions window.
final class ListenState: ObservableObject {
    @Published var active = false
    @Published var connecting = false
    @Published var original = TranscriptSnapshot()
    @Published var translation = TranscriptSnapshot()
    @Published var errorMessage: String?
    /// True while auto-reconnecting after a recoverable error (network blip,
    /// provider session-length cap) — shown as a quiet note, not a red error.
    @Published var reconnecting = false
    /// NOT `@Published`: level updates arrive up to ~100 Hz, so only the tiny
    /// MiniWaveform view observes this object directly — publishing it here
    /// would re-evaluate the whole panel body on every tick.
    let audioLevel = ListenAudioLevel()
}

/// Isolated audio-level publisher observed only by `MiniWaveform`. See
/// `ListenState.audioLevel`.
final class ListenAudioLevel: ObservableObject {
    @Published var level: Float = 0
}

// MARK: - ListenController

/// Live Captions: continuous transcription (+ inline Soniox one-way
/// translation) of either the system's own audio output or the microphone,
/// rendered in a two-column glass panel. Toggled by Fn+Space or the menu bar.
///
/// Target-language changes restart the WebSocket (Soniox config is fixed per
/// session) while CARRYING the text already shown; source changes swap the
/// audio capture without touching the session.
final class ListenController {
    let state = ListenState()

    private let settings: AppSettings
    private var panel: ListenPanel?

    private var session: LiveCaptionSession?
    private var micCapture: AudioCapture?
    private var systemCapture: SystemAudioCapture?

    /// Text carried across target-language restarts.
    private var carriedOriginal = ""
    private var carriedTranslation = ""

    /// Auto-reconnect bookkeeping for recoverable session errors. Reset to 0
    /// after a stable connection or user-driven restart; exhausted after
    /// three consecutive failures, at which point the error
    /// becomes terminal (see `enterTerminalError`).
    private var reconnectPolicy = CaptionReconnectPolicy()
    private var reconnectWorkItem: DispatchWorkItem?

    /// Throttles `ListenAudioLevel.level` publishes to ≤20 Hz (see fix for
    /// the redraw storm at capture-callback rate, ~100 Hz for system audio).
    private var lastLevelUpdate: TimeInterval = 0
    private let levelUpdateInterval: TimeInterval = 0.05

    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings

        settings.$listenTargetLanguage
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartSessionCarryingText() }
            .store(in: &cancellables)

        settings.$listenSource
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartCapture() }
            .store(in: &cancellables)

        // Switching engine (Soniox ↔ Gemini) rebuilds the session, keeping text.
        settings.$liveCaptionProvider
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartSessionCarryingText() }
            .store(in: &cancellables)
    }

    // MARK: - Public

    func toggle() {
        state.active ? stop() : start()
    }

    /// Flip the display between two-column and caption-bar (Fn+Shift+Space).
    /// Only meaningful while captions are showing.
    func toggleMode() {
        guard state.active else { return }
        settings.listenMode = (settings.listenMode == "bar") ? "dual" : "bar"
    }

    func start() {
        guard !state.active else { return }
        Log.app.info("Live Captions start (source=\(self.settings.listenSource))")
        state.active = true
        state.connecting = true
        state.errorMessage = nil
        state.original = TranscriptSnapshot()
        state.translation = TranscriptSnapshot()
        carriedOriginal = ""
        carriedTranslation = ""
        cancelPendingReconnect()

        if panel == nil { panel = ListenPanel(state: state, settings: settings, controller: self) }
        panel?.show()

        startSession()
        startCapture()
    }

    func stop() {
        guard state.active else { return }
        Log.app.info("Live Captions stop")
        state.active = false
        cancelPendingReconnect()
        stopCapture()
        session?.stop()
        session = nil
        panel?.dismiss()
    }

    func clearTranscripts() {
        carriedOriginal = ""
        carriedTranslation = ""
        state.original = TranscriptSnapshot()
        state.translation = TranscriptSnapshot()
        restartSessionCarryingText(carry: false)
    }

    // MARK: - Session

    private func startSession() {
        let newSession = LiveCaptionFactory.make(settings: settings)
        session = newSession

        newSession.onConnected = { [weak self, weak newSession] in
            guard let self, let newSession, self.state.active,
                  self.session === newSession else { return }
            self.state.connecting = false
            self.state.reconnecting = false
            self.reconnectPolicy.connected(at: ProcessInfo.processInfo.systemUptime)
        }
        newSession.onOriginal = { [weak self, weak newSession] snapshot in
            guard let self, let newSession, self.state.active,
                  self.session === newSession else { return }
            self.state.original = TranscriptSnapshot(
                finalText: self.carriedOriginal + snapshot.finalText,
                interimText: snapshot.interimText
            )
        }
        newSession.onTranslation = { [weak self, weak newSession] snapshot in
            guard let self, let newSession, self.state.active,
                  self.session === newSession else { return }
            self.state.translation = TranscriptSnapshot(
                finalText: self.carriedTranslation + snapshot.finalText,
                interimText: snapshot.interimText
            )
        }
        newSession.onError = { [weak self, weak newSession] error in
            guard let self, let newSession, self.state.active,
                  self.session === newSession else { return }
            switch error {
            case .terminal(let message):
                self.enterTerminalError(message)
            case .recoverable(let message):
                self.scheduleReconnect(afterError: message)
            }
        }

        newSession.start(settings: settings)
    }

    /// Restarts the session carrying the text shown so far. Used both for
    /// user-driven restarts (target-language/provider change, clear) and —
    /// with `resetReconnect: false` — by the auto-reconnect backoff below.
    private func restartSessionCarryingText(carry: Bool = true, resetReconnect: Bool = true) {
        guard state.active else { return }
        if resetReconnect { cancelPendingReconnect() }
        if carry {
            carriedOriginal = state.original.combined
            carriedTranslation = state.translation.combined
        }
        state.connecting = true
        state.errorMessage = nil
        session?.stop()
        startSession()
    }

    /// A recoverable error (network blip, Soniox's 300-minute session cap):
    /// retry with exponential backoff, carrying the transcript so far. After
    /// three consecutive short-lived failures, give up and go terminal —
    /// endless silent retries would just burn CPU against a dead network.
    private func scheduleReconnect(afterError message: String) {
        guard state.active else { return }
        session?.stop()
        session = nil
        guard let delay = reconnectPolicy.nextDelay(at: ProcessInfo.processInfo.systemUptime) else {
            enterTerminalError(message)
            return
        }
        state.reconnecting = true
        state.connecting = true
        state.errorMessage = nil

        let attempt = reconnectPolicy.attempt
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.state.active, self.reconnectPolicy.attempt == attempt else { return }
            self.restartSessionCarryingText(resetReconnect: false)
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Auth/config errors (bad key, bad request) recur identically on retry —
    /// show the error and release the mic/system capture instead of leaving
    /// them running (privacy light on, CPU burning) against a session that
    /// can never succeed. The panel stays up so the transcript and error
    /// remain visible; only an explicit stop dismisses it.
    private func enterTerminalError(_ message: String) {
        cancelPendingReconnect()
        state.connecting = false
        state.errorMessage = message
        session?.stop()
        session = nil
        stopCapture()
    }

    private func cancelPendingReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectPolicy.reset()
        state.reconnecting = false
    }

    // MARK: - Capture

    private func startCapture() {
        if settings.listenSource == "mic" {
            let capture = AudioCapture()
            micCapture = capture
            capture.onChunk = { [weak self] chunk in self?.session?.sendAudio(chunk) }
            capture.onLevel = { [weak self] level in self?.handleAudioLevel(level) }
            do {
                try capture.start()
            } catch {
                enterTerminalError("Microphone capture failed: \(error.localizedDescription)")
            }
        } else {
            let capture = SystemAudioCapture()
            systemCapture = capture
            capture.onChunk = { [weak self] chunk in self?.session?.sendAudio(chunk) }
            capture.onLevel = { [weak self] level in self?.handleAudioLevel(level) }
            capture.onError = { [weak self] message in
                guard let self, self.state.active else { return }
                self.enterTerminalError(message)
            }
            capture.start()
        }
    }

    private func stopCapture() {
        micCapture?.stop()
        micCapture = nil
        systemCapture?.stop()
        systemCapture = nil
        state.audioLevel.level = 0
    }

    /// Throttled to ≤20 Hz and dropped entirely in bar layout, where
    /// MiniWaveform isn't shown — no point publishing at capture rate (up to
    /// ~100 Hz for system audio) into a view nobody's looking at.
    private func handleAudioLevel(_ level: Float) {
        guard settings.listenMode != "bar" else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastLevelUpdate >= levelUpdateInterval else { return }
        lastLevelUpdate = now
        state.audioLevel.level = level
    }

    private func restartCapture() {
        guard state.active else { return }
        stopCapture()
        startCapture()
    }
}

// MARK: - Target language catalog

enum ListenLanguages {
    static let all: [(code: String, name: String, english: String)] = [
        ("zh", "中文", "Chinese (Simplified)"),
        ("en", "English", "English"),
        ("ja", "日本語", "Japanese"),
        ("ko", "한국어", "Korean"),
        ("es", "Español", "Spanish"),
        ("fr", "Français", "French"),
        ("de", "Deutsch", "German"),
        ("pt", "Português", "Portuguese"),
    ]

    static func name(for code: String) -> String {
        all.first(where: { $0.code == code })?.name ?? code.uppercased()
    }

    static func englishName(for code: String) -> String {
        all.first(where: { $0.code == code })?.english ?? code
    }

    /// BCP-47 code Gemini expects (Simplified Chinese needs the region).
    static func bcp47(for code: String) -> String {
        code == "zh" ? "zh-CN" : code
    }
}
