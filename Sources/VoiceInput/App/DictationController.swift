import AppKit
import Combine
import os.log

// MARK: - DictationController

/// Owns the session lifecycle: audio capture → ASR → refine → inject.
/// All AppState mutations are dispatched to the main thread.
/// AppDelegate wires KeyMonitor callbacks into beginSession/endSession/cancelSession.
final class DictationController {

    // MARK: - External callbacks (wired by AppDelegate)

    /// Called when a session ends by a path other than a user hotkey tap
    /// (hands-free silence auto-stop, overlay Stop button).
    /// AppDelegate wires this to keyMonitor.externalStop().
    var onSessionEndedExternally: (() -> Void)?

    /// Called when a session is cancelled (Esc / overlay Cancel / app-disabled).
    /// AppDelegate wires this to keyMonitor.reset().
    var onSessionCancelled: (() -> Void)?

    // MARK: - Dependencies

    private let settings: AppSettings
    private let appState: AppState
    private let refiner: Refiner
    private let textInjector: TextInjector
    private let mediaController: MediaController
    private let overlayPanel: OverlayPanel

    // MARK: - Session state

    private var session: TranscriptionSession?
    private var sessionGeneration: UInt64 = 0
    private var isActive: Bool = false
    private var bestTranscript: String = ""

    /// The pre-refine best text, set right before `refiner.refine` is called
    /// and cleared once its completion actually lands (generation-guarded) or
    /// on explicit cancel. Non-nil here means a refine is in flight for a
    /// session `beginSession` no longer owns — see the flush at its top.
    private var pendingBestTranscript: String?

    /// Text carried across mid-session engine hot-swaps (mode/provider chip).
    /// Displayed transcript = join(carriedText, current engine's snapshot).
    private var carriedText: String = ""
    /// The current engine's own (session-local) latest snapshot.
    private var engineSnapshot = TranscriptSnapshot()
    /// `session?.isStreaming` for the currently-running engine, cached so
    /// `armSilenceCountdown()` doesn't need to re-derive it from settings.
    private var currentEngineIsStreaming: Bool = false

    private var cancellables = Set<AnyCancellable>()

    // History capture (per session)
    private var sessionStartDate: Date?
    private var sessionBackend: String = ""
    /// Materialised once at session end, only when history + keep-audio are on.
    private var pendingAudioWAV: Data?

    // Hands-free silence countdown
    private var silenceTimer: Timer?
    private var lastTranscriptChangeDate: Date?
    private var utteranceEndFired: Bool = false

    // Preview overlay state
    private var previewTimer: Timer?

    // Post-dictation review state (see `beginReview`/`applyReview`/`dismissReview`)
    private var reviewTimer: Timer?
    private var reviewHistoryID: UUID?
    private var reviewRawTranscript: String = ""
    private var reviewBackend: String = ""

    // MARK: - Init

    init(settings: AppSettings,
         appState: AppState,
         refiner: Refiner,
         textInjector: TextInjector,
         mediaController: MediaController,
         overlayPanel: OverlayPanel) {
        self.settings = settings
        self.appState = appState
        self.refiner = refiner
        self.textInjector = textInjector
        self.mediaController = mediaController
        self.overlayPanel = overlayPanel

        overlayPanel.onStop = { [weak self] in
            self?.endSession()
        }
        overlayPanel.onCancel = { [weak self] in
            guard let self else { return }
            // Esc/Cancel means different things depending on phase: mid-session
            // it aborts the dictation (never injected); during review the
            // session already ended and injected — Esc there just dismisses
            // the review UI without touching what's already in the target app.
            if case .reviewing = self.appState.phase {
                self.dismissReview()
            } else {
                self.cancelSession()
            }
        }
        overlayPanel.onReviewEditStart = { [weak self] in
            self?.cancelReviewAutoDismiss()
        }
        overlayPanel.onApplyReview = { [weak self] corrected in
            self?.applyReview(corrected: corrected)
        }

        // Mode/provider changes apply IMMEDIATELY to a live session: the
        // running engine is retired (keeping its text) and the new one takes
        // over the microphone.
        settings.$asrBackend
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hotSwapEngine() }
            .store(in: &cancellables)
        settings.$voiceProvider
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hotSwapEngine() }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Forward the hotkey display label to the overlay panel.
    func updateHotkeyLabel(_ display: String) {
        overlayPanel.updateHotkeyLabel(display)
    }

    /// Whether a dictation session is currently in flight. A post-dictation
    /// review does NOT count — that session already ended (inject + history
    /// already happened); exposed so AppDelegate's applicationWillTerminate
    /// knows whether cancelSession() has anything real left to cancel.
    var isSessionActive: Bool { isActive }

    /// Begin a dictation session. Re-entrancy guard: ignored if a session is already active.
    func beginSession(kind: SessionKind) {
        guard !isActive else {
            Log.app.debug("beginSession ignored — session already active")
            return
        }

        // A post-dictation review may still be showing (it reuses this same
        // overlay/panel). Its transcript was already recorded when that
        // session ended, so — unlike the pendingBestTranscript flush right
        // below — there's nothing to flush, just UI state to tear down before
        // this new session claims the panel.
        if case .reviewing = appState.phase {
            dismissReview()
        }

        // A refine pipeline from the PREVIOUS session may still be in flight
        // (slow :free polish models take 10-30 s) — its completion would be
        // dropped by the generation guard the moment we bump sessionGeneration
        // below, silently losing the transcript. Flush it now: inject + record
        // to history using what we have, then let this new session own its
        // own overlay/media/KeyMonitor sequencing from scratch.
        if let flushText = pendingBestTranscript {
            pendingBestTranscript = nil
            refiner.cancel()
            textInjector.inject(flushText)
            let duration = sessionStartDate.map { Date().timeIntervalSince($0) } ?? 0
            HistoryStore.shared.record(
                raw: flushText,
                refined: nil,
                durationSeconds: max(0, duration),
                backend: sessionBackend,
                injected: true,
                audioWAV: pendingAudioWAV
            )
            pendingAudioWAV = nil
        }

        isActive = true
        // A preview overlay may still be counting down; cancel it so its 4 s
        // callback can't tear down the overlay/AppState mid-session.
        previewTimer?.invalidate()
        previewTimer = nil
        bestTranscript = ""
        carriedText = ""
        engineSnapshot = TranscriptSnapshot()
        sessionGeneration &+= 1
        let generation = sessionGeneration

        // Capture session metadata for history.
        sessionStartDate = Date()
        sessionBackend = "\(settings.voiceProvider.rawValue)/\(settings.asrBackend.rawValue)"
        pendingAudioWAV = nil

        Log.app.info("beginSession kind=\(String(describing: kind))")

        // Update state to connecting immediately.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.phase = .connecting
            self.appState.transcript = TranscriptSnapshot()
            self.appState.audioLevel = 0
            self.appState.silenceCountdown = nil
            self.appState.sessionKind = kind
        }

        overlayPanel.show()

        startEngine(kind: kind, generation: generation)

        // Pause media after the mic is already starting: pauseIfPlaying only
        // enqueues onto MediaController's background queue now, so it no
        // longer blocks and doesn't need to go first.
        mediaController.pauseIfPlaying()
    }

    /// Creates the ASR engine from the CURRENT settings, wires its callbacks
    /// (merging `carriedText` from earlier engines of this session), and
    /// starts it. Used by `beginSession` and by mid-session hot-swaps.
    private func startEngine(kind: SessionKind, generation: UInt64) {
        let vocabulary = VocabularyStore.shared
        let asrSession = TranscriptionFactory.make(settings: settings, vocabulary: vocabulary)
        session = asrSession

        // Whether THIS engine streams incrementally — provider-agnostic
        // replacement for reading `settings.asrBackend` as a mode proxy,
        // which can disagree with the actual engine (e.g. Qwen forces batch
        // regardless of the Mode picker's stored value).
        let isStreaming = asrSession.isStreaming
        currentEngineIsStreaming = isStreaming

        // Wire callbacks.
        asrSession.audioLevelHandler = { [weak self] level in
            // Already on main (per contract).
            self?.appState.audioLevel = level
        }

        asrSession.onTranscript = { [weak self] snapshot in
            guard let self else { return }
            guard self.sessionGeneration == generation else { return }
            // Already on main (per contract).
            let wasEmpty = self.appState.transcript.isEmpty
            self.engineSnapshot = snapshot
            let merged = TranscriptSnapshot(
                finalText: Self.joinTranscripts(self.carriedText, snapshot.finalText),
                interimText: snapshot.interimText
            )
            self.appState.transcript = merged
            self.bestTranscript = merged.combined

            // Track last change timestamp for silence countdown.
            if !snapshot.combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.lastTranscriptChangeDate = Date()
            }

            // Arm silence countdown only for hands-free + streaming engines
            // (batch backends produce no incremental tokens).
            if kind == .handsFree &&
               isStreaming &&
               (wasEmpty || self.silenceTimer == nil) {
                self.armSilenceCountdown()
            }
        }

        asrSession.onUtteranceEnd = { [weak self] in
            guard let self else { return }
            guard self.sessionGeneration == generation else { return }
            // Already on main (per contract).
            if kind == .handsFree && isStreaming {
                self.utteranceEndFired = true
                self.lastTranscriptChangeDate = Date()
                self.armSilenceCountdown()
            }
        }

        asrSession.onError = { [weak self] errorMessage in
            guard let self else { return }
            guard self.sessionGeneration == generation else { return }
            // Already on main (per contract).
            Log.asr.error("ASR error: \(errorMessage)")
            self.appState.phase = .error(errorMessage)
            // After 2 s dismiss and recover.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                guard self.sessionGeneration == generation else { return }
                self.overlayPanel.dismiss()
                self.mediaController.resumeIfPaused()
                self.appState.phase = .idle
                self.appState.silenceCountdown = nil
                self.appState.sessionKind = nil
                self.isActive = false
                self.session = nil
                self.teardownSilenceTimer()
                self.onSessionEndedExternally?()
            }
        }

        // Transition to listening.
        DispatchQueue.main.async { [weak self] in
            self?.appState.phase = .listening
        }

        do {
            try asrSession.start()
        } catch {
            Log.asr.error("ASR start error: \(error)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.appState.phase = .error(error.localizedDescription)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self else { return }
                    guard self.sessionGeneration == generation else { return }
                    self.overlayPanel.dismiss()
                    self.mediaController.resumeIfPaused()
                    self.appState.phase = .idle
                    self.appState.sessionKind = nil
                    self.isActive = false
                    self.session = nil
                    self.onSessionEndedExternally?()
                }
            }
        }
    }

    /// Graceful stop: finalize ASR → refine → inject.
    /// Idempotent if called multiple times.
    func endSession() {
        guard isActive else {
            Log.app.debug("endSession ignored — no active session")
            return
        }
        // Mark inactive immediately so any re-entrant endSession()/cancelSession()
        // (e.g. overlay Stop racing the hands-free silence auto-stop) hits the
        // guard above and returns, rather than calling asrSession.stop() twice.
        isActive = false
        Log.app.info("endSession")
        teardownSilenceTimer()
        let generation = sessionGeneration

        DispatchQueue.main.async { [weak self] in
            self?.appState.phase = .finalizing
            self?.appState.silenceCountdown = nil
        }

        guard let asrSession = session else {
            // No ASR session — just clean up.
            finishAfterTranscript(text: bestTranscript, generation: generation, externallyEnded: true)
            return
        }

        asrSession.stop { [weak self] finalText in
            guard let self else { return }
            guard self.sessionGeneration == generation else { return }
            // stop(completion:) delivers on main thread per contract.
            // Engines report session-local text; prepend anything carried
            // across mid-session hot-swaps.
            let merged = Self.joinTranscripts(self.carriedText, finalText)
            let text = merged.isEmpty ? self.bestTranscript : merged
            self.finishAfterTranscript(text: text, generation: generation, externallyEnded: true)
        }
    }

    // MARK: - Mid-session engine hot-swap

    /// Applies a mode/provider change to the LIVE session: the current engine
    /// is retired, its text is carried forward, and a fresh engine (built from
    /// the new settings) takes over the microphone immediately.
    private func hotSwapEngine() {
        guard isActive, let old = session else { return }
        switch appState.phase {
        case .connecting, .listening: break
        default: return                      // already finalizing/refining
        }
        let generation = sessionGeneration
        guard let kind = appState.sessionKind else { return }

        Log.app.info("hotSwapEngine → \(self.settings.voiceProvider.rawValue)/\(self.settings.asrBackend.rawValue)")

        // Freeze the current engine's contribution.
        carriedText = Self.joinTranscripts(carriedText, engineSnapshot.combined)
        engineSnapshot = TranscriptSnapshot()
        sessionBackend = "\(settings.voiceProvider.rawValue)/\(settings.asrBackend.rawValue)"
        teardownSilenceTimer()

        let oldIsBatch = !old.isStreaming
        if oldIsBatch {
            // A batch engine has recorded audio but shown nothing — transcribe
            // it in the background and splice the result in when it lands.
            old.stop { [weak self] text in
                guard let self, self.sessionGeneration == generation else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.carriedText = Self.joinTranscripts(trimmed, self.carriedText)
                let merged = TranscriptSnapshot(
                    finalText: Self.joinTranscripts(self.carriedText, self.engineSnapshot.finalText),
                    interimText: self.engineSnapshot.interimText
                )
                self.appState.transcript = merged
                self.bestTranscript = merged.combined
            }
        } else {
            old.cancel()
        }

        startEngine(kind: kind, generation: generation)
    }

    /// Joins two transcript fragments, inserting a space only when the
    /// boundary isn't CJK (Chinese text reads wrong with injected spaces).
    private static func joinTranscripts(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        func isCJK(_ c: Character) -> Bool {
            guard let scalar = c.unicodeScalars.first else { return false }
            switch scalar.value {
            case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xF900...0xFAFF, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
        let separator = (isCJK(left.last!) || isCJK(right.first!)) ? "" : " "
        return left + separator + right
    }

    /// Cancel: discard transcript, do not inject.
    /// Idempotent.
    func cancelSession() {
        // A review has no live session to cancel (it already injected) — just
        // tear down its UI. Handled here (rather than left as a silent no-op
        // below) so e.g. disabling the app mid-review still cleans up the
        // panel's temporary key-focus grant.
        if case .reviewing = appState.phase {
            dismissReview()
            return
        }
        guard isActive else {
            Log.app.debug("cancelSession ignored — no active session")
            return
        }
        Log.app.info("cancelSession")
        teardownSilenceTimer()
        let capturedSession = session
        isActive = false
        session = nil
        sessionGeneration &+= 1   // Invalidate any in-flight callbacks.

        // Cancelled sessions are never recorded to history.
        pendingAudioWAV = nil
        sessionStartDate = nil
        pendingBestTranscript = nil

        capturedSession?.cancel()
        refiner.cancel()
        overlayPanel.dismiss()
        mediaController.resumeIfPaused()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.phase = .idle
            self.appState.transcript = TranscriptSnapshot()
            self.appState.silenceCountdown = nil
            self.appState.sessionKind = nil
        }
        onSessionCancelled?()
    }

    // MARK: - Preview overlay

    /// Show a sample transcript in the overlay for 4 seconds.
    /// Ignored while a real session is active.
    func showPreviewOverlay() {
        guard !isActive else {
            Log.app.debug("showPreviewOverlay ignored — session active")
            return
        }

        // Cancel any existing preview.
        previewTimer?.invalidate()
        previewTimer = nil

        let sampleFinal = "Voice input makes coding faster. "
        let sampleInterim = "It streams text in real time."
        let snapshot = TranscriptSnapshot(finalText: sampleFinal, interimText: sampleInterim)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.phase = .listening
            self.appState.transcript = snapshot
            self.appState.audioLevel = 0.4
            self.appState.sessionKind = .toggle
            self.overlayPanel.show()
        }

        previewTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            // A real session may have started since this timer was scheduled; if
            // so, leave its overlay/AppState untouched.
            guard !self.isActive else { self.previewTimer = nil; return }
            DispatchQueue.main.async {
                self.overlayPanel.dismiss()
                self.appState.phase = .idle
                self.appState.transcript = TranscriptSnapshot()
                self.appState.audioLevel = 0
                self.appState.sessionKind = nil
            }
            self.previewTimer = nil
        }
    }

    // MARK: - Hands-free silence countdown

    private func armSilenceCountdown() {
        // Only relevant for hands-free + a streaming engine.
        guard appState.sessionKind == .handsFree,
              currentEngineIsStreaming else { return }

        // If a timer is already running, let it keep ticking.
        if silenceTimer != nil { return }

        lastTranscriptChangeDate = Date()

        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tickSilenceCountdown()
        }
    }

    private func tickSilenceCountdown() {
        guard isActive, appState.sessionKind == .handsFree else {
            teardownSilenceTimer()
            return
        }

        let silenceDuration = Double(settings.silenceDurationMs) / 1000.0

        // Only count down after utterance end has fired or some transcript arrived.
        guard utteranceEndFired || lastTranscriptChangeDate != nil else { return }

        let reference = lastTranscriptChangeDate ?? Date()
        let elapsed = Date().timeIntervalSince(reference)
        let remaining = max(0.0, silenceDuration - elapsed)

        // tickSilenceCountdown() is the body of a main-thread RunLoop Timer, so
        // this mutation is already on the main thread — assign directly so the
        // countdown display stays in lockstep with the remaining <= 0 check below.
        appState.silenceCountdown = remaining

        if remaining <= 0 {
            Log.app.info("Hands-free silence elapsed — auto-ending session")
            teardownSilenceTimer()
            // endSession() runs with externallyEnded: true, so it already fires
            // onSessionEndedExternally?() (→ keyMonitor.externalStop()) once the
            // pipeline completes. Calling it here too would reset KeyMonitor early
            // (before the controller is done) and fire it twice.
            endSession()
        }
    }

    private func teardownSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        utteranceEndFired = false
        lastTranscriptChangeDate = nil
    }

    // MARK: - Post-ASR pipeline

    /// Called on main thread after ASR finalization.
    private func finishAfterTranscript(text: String, generation: UInt64, externallyEnded: Bool) {
        // Materialise the captured audio for history BEFORE clearing `session`.
        // Only copy the WAV when history + keep-audio are both enabled so the
        // bytes are never assembled for users who don't keep audio.
        if AppSettings.shared.historyEnabled && AppSettings.shared.historyKeepAudio {
            pendingAudioWAV = session?.capturedAudioWAV
        } else {
            pendingAudioWAV = nil
        }

        // Mark session as no longer active so endSession/cancelSession are no-ops.
        isActive = false
        session = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            // Nothing to inject — and per spec, empty transcripts are never
            // recorded to history.
            Log.app.info("Empty transcript — dismissing without inject")
            pendingAudioWAV = nil
            overlayPanel.dismiss()
            mediaController.resumeIfPaused()
            appState.phase = .idle
            appState.transcript = TranscriptSnapshot()
            appState.silenceCountdown = nil
            appState.sessionKind = nil
            if externallyEnded { onSessionEndedExternally?() }
            return
        }

        let needsRefine = settings.polishEnabled || settings.translateEnabled

        if needsRefine {
            appState.phase = .refining
            pendingBestTranscript = trimmed

            refiner.refine(trimmed) { [weak self] refined in
                guard let self else { return }
                guard self.sessionGeneration == generation else { return }
                self.pendingBestTranscript = nil
                // refiner completion is on main thread.
                let refinedTrimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalText = refinedTrimmed.isEmpty ? trimmed : refined
                // `refined` for history: the post-refiner text only when
                // refinement actually changed the raw transcript, else nil.
                let recordedRefined: String? = (finalText != trimmed) ? finalText : nil
                self.injectAndFinish(text: finalText,
                                     raw: trimmed,
                                     refined: recordedRefined,
                                     generation: generation,
                                     externallyEnded: externallyEnded)
            }
        } else {
            injectAndFinish(text: trimmed,
                            raw: trimmed,
                            refined: nil,
                            generation: generation,
                            externallyEnded: externallyEnded)
        }
    }

    private func injectAndFinish(text: String,
                                 raw: String,
                                 refined: String?,
                                 generation: UInt64,
                                 externallyEnded: Bool) {
        appState.phase = .injecting

        // Snapshot history inputs now so they survive the deferred closure.
        let startDate = sessionStartDate
        let backend = sessionBackend
        let audioWAV = pendingAudioWAV
        pendingAudioWAV = nil

        // Brief injecting state for visual feedback, then inject.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            guard self.sessionGeneration == generation else { return }

            self.textInjector.inject(text)

            // Record the completed session to history (after the inject step).
            // The store gates itself on historyEnabled / historyKeepAudio.
            let duration = startDate.map { Date().timeIntervalSince($0) } ?? 0
            let recordID = HistoryStore.shared.record(
                raw: raw,
                refined: refined,
                durationSeconds: max(0, duration),
                backend: backend,
                injected: true,
                audioWAV: audioWAV
            )

            // The session is over here regardless of whether a review
            // follows — resume media and reset KeyMonitor now rather than
            // after the review dwell, so a slow reviewer never leaves media
            // paused or the hotkey state machine mid-session.
            self.mediaController.resumeIfPaused()
            self.sessionStartDate = nil
            if externallyEnded {
                self.onSessionEndedExternally?()
            }

            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.settings.reviewEnabled && !trimmedText.isEmpty {
                self.beginReview(injectedText: text, raw: raw, backend: backend, historyID: recordID, generation: generation)
            } else {
                self.overlayPanel.dismiss()
                self.appState.phase = .idle
                self.appState.transcript = TranscriptSnapshot()
                self.appState.silenceCountdown = nil
                self.appState.sessionKind = nil
            }
        }
    }

    // MARK: - Post-dictation review

    /// Keeps the overlay up showing the just-injected `injectedText` so the
    /// user can fix a mishearing in place. Arms a generation-guarded
    /// auto-dismiss timer and grants the panel temporary key focus (see
    /// `OverlayPanel.allowsKeyFocus`) so a click into the review editor works.
    private func beginReview(injectedText: String,
                             raw: String,
                             backend: String,
                             historyID: UUID?,
                             generation: UInt64) {
        reviewRawTranscript = raw
        reviewBackend = backend
        reviewHistoryID = historyID

        appState.reviewText = injectedText
        appState.phase = .reviewing
        appState.transcript = TranscriptSnapshot()
        appState.silenceCountdown = nil
        appState.sessionKind = nil

        overlayPanel.allowsKeyFocus = true

        reviewTimer?.invalidate()
        let seconds = max(0.5, settings.reviewSeconds)
        reviewTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.sessionGeneration == generation else { return }
            self.dismissReview()
        }
    }

    /// Cancels the review's auto-dismiss timer. Fired once the user actually
    /// focuses the review editor — per spec, once they touch it, it waits.
    private func cancelReviewAutoDismiss() {
        reviewTimer?.invalidate()
        reviewTimer = nil
    }

    /// Ends a review without applying any edit: dismisses the overlay, drops
    /// back to idle, clears the review text, and revokes the panel's
    /// temporary key-focus grant. Safe to call even if no review is live.
    private func dismissReview() {
        reviewTimer?.invalidate()
        reviewTimer = nil
        reviewHistoryID = nil
        overlayPanel.allowsKeyFocus = false
        overlayPanel.dismiss()
        appState.phase = .idle
        appState.reviewText = ""
    }

    /// Applies the user's edit from the review editor. If it matches the
    /// original injected text, this is just a dismiss; otherwise the injected
    /// text is replaced in the target app and the correction is recorded as
    /// gold-standard data.
    func applyReview(corrected: String) {
        guard case .reviewing = appState.phase else { return }
        let original = appState.reviewText

        guard corrected != original else {
            dismissReview()
            return
        }

        CorrectionStore.shared.append(
            raw: reviewRawTranscript,
            injected: original,
            corrected: corrected,
            backend: reviewBackend
        )

        if let id = reviewHistoryID {
            HistoryStore.shared.updateCorrection(id: id, corrected: corrected)
        }

        textInjector.replaceLastInjection(with: corrected)

        dismissReview()
    }
}
