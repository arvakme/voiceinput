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
    private let presets: PolishPresetStore
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

    // Post-dictation review state (see `beginReviewAfterInsert`/
    // `beginReviewBeforeInsert`/`applyReview`/`dismissReview`/`abandonReview`)
    private var reviewTimer: Timer?
    private var reviewHistoryID: UUID?
    private var reviewRawTranscript: String = ""
    private var reviewBackend: String = ""

    /// "before" mode only: the review hasn't injected (or recorded to
    /// history) yet, so these snapshot what the normal inject step would have
    /// recorded, deferred until the review actually resolves.
    private var reviewRefinedTranscript: String?
    private var reviewDurationSeconds: Double = 0
    private var reviewAudioWAV: Data?

    /// Which mode produced the CURRENT `.reviewing` phase — captured once at
    /// entry (not re-read from settings) so a settings change mid-review
    /// can't retroactively alter how it resolves. `.off` when no review is
    /// live; used to route `applyReview`/Esc/interruption to the right
    /// resolution instead of branching on `settings.reviewMode` everywhere.
    private var activeReviewMode: ReviewMode = .off

    /// Ticks `AppState.reviewCountdown` for a "before"-mode review at a 0.5 s
    /// cadence. `nil` whenever no countdown is running.
    private var reviewCountdownTimer: Timer?
    private var reviewCountdownDeadline: Date?

    // MARK: - Init

    init(settings: AppSettings,
         appState: AppState,
         refiner: Refiner,
         presets: PolishPresetStore,
         textInjector: TextInjector,
         mediaController: MediaController,
         overlayPanel: OverlayPanel) {
        self.settings = settings
        self.appState = appState
        self.refiner = refiner
        self.presets = presets
        self.textInjector = textInjector
        self.mediaController = mediaController
        self.overlayPanel = overlayPanel

        overlayPanel.onStop = { [weak self] in
            self?.endSession()
        }
        overlayPanel.onCancel = { [weak self] in
            guard let self else { return }
            // Esc/Cancel means different things depending on phase: mid-session
            // it aborts the dictation (never injected). During review the
            // session already ended — "after" mode already injected, so Esc
            // there just dismisses the UI without touching the target app;
            // "before" mode never injected, so Esc there resolves as
            // abandoned (recorded to history, never inserted) — see
            // `abandonReview`.
            if case .reviewing = self.appState.phase {
                self.abandonReview()
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
    /// review does NOT count — that session already ended (its ASR/refine
    /// pipeline is done; "after" mode has already injected + recorded, and
    /// "before" mode resolves its own deferred recording on the review's own
    /// exit paths); exposed so AppDelegate's applicationWillTerminate knows
    /// whether cancelSession() has anything real left to cancel.
    var isSessionActive: Bool { isActive }

    /// Begin a dictation session. Re-entrancy guard: ignored if a session is already active.
    func beginSession(kind: SessionKind) {
        guard !isActive else {
            Log.app.debug("beginSession ignored — session already active")
            return
        }

        // A post-dictation review may still be showing (it reuses this same
        // overlay/panel). "after" mode already recorded its transcript when
        // that session ended, so there's just UI state to tear down; "before"
        // mode never injected, so per spec this resolves as ABANDONED — record
        // history (injected: false) rather than silently losing it or
        // injecting stale text into whatever the user is now doing.
        if case .reviewing = appState.phase {
            abandonReview()
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
            // The previous session's final resolution — flushed straight to
            // injection with no review shown, so no correction is possible.
            SessionStatsStore.shared.append(injected: true, corrected: false)
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
        // A review has no live session to cancel — "after" mode already
        // injected, so this is just UI teardown; "before" mode resolves as
        // abandoned (see beginSession's identical handling). Handled here
        // (rather than left as a silent no-op below) so e.g. disabling the
        // app mid-review still cleans up the panel's temporary key-focus grant.
        if case .reviewing = appState.phase {
            abandonReview()
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
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // "before" mode never injects sight-unseen — hand off to the
        // pre-insert review path instead of the inject-then-maybe-review flow
        // below. (finishAfterTranscript already filtered empty transcripts;
        // the emptiness check here is just defensive.)
        if settings.reviewMode == .before && !trimmedText.isEmpty {
            beginReviewBeforeInsert(text: text,
                                    raw: raw,
                                    refined: refined,
                                    generation: generation,
                                    externallyEnded: externallyEnded)
            return
        }

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

            if self.settings.reviewMode == .after && !trimmedText.isEmpty {
                self.beginReviewAfterInsert(injectedText: text, raw: raw, backend: backend, historyID: recordID, generation: generation)
            } else {
                // "off" mode (or the defensive empty-text fallback above):
                // the session is fully resolved right here — one stat line.
                SessionStatsStore.shared.append(injected: true, corrected: false)
                self.overlayPanel.dismiss()
                self.appState.phase = .idle
                self.appState.transcript = TranscriptSnapshot()
                self.appState.silenceCountdown = nil
                self.appState.sessionKind = nil
            }
        }
    }

    // MARK: - Post-dictation review

    /// "after" mode — EXACTLY today's (pre-existing) behavior: the overlay
    /// stays up showing the just-injected `injectedText` so the user can fix
    /// a mishearing in place. Arms a generation-guarded auto-dismiss timer and
    /// grants the panel temporary key focus (see `OverlayPanel.allowsKeyFocus`)
    /// so a click into the review editor works.
    private func beginReviewAfterInsert(injectedText: String,
                                        raw: String,
                                        backend: String,
                                        historyID: UUID?,
                                        generation: UInt64) {
        activeReviewMode = .after
        reviewRawTranscript = raw
        reviewBackend = backend
        reviewHistoryID = historyID

        appState.reviewText = injectedText
        appState.reviewAwaitingInsert = false
        appState.reviewPolishFailed = refiner.lastPolishFailed
        appState.phase = .reviewing
        appState.transcript = TranscriptSnapshot()
        appState.silenceCountdown = nil
        appState.sessionKind = nil

        overlayPanel.allowsKeyFocus = true

        reviewTimer?.invalidate()
        let seconds = activeReviewSeconds
        reviewTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.sessionGeneration == generation else { return }
            // Auto-dismiss with no edit made — already injected at review
            // start, so this session resolves as "delivered, uncorrected".
            SessionStatsStore.shared.append(injected: true, corrected: false)
            self.dismissReview()
        }
    }

    /// "before" mode — the just-refined `text` has NOT been injected yet.
    /// Snapshots everything the normal inject step would have recorded to
    /// history (so it survives however long the review dwell runs), finishes
    /// the session's sequencing (media resume, KeyMonitor reset) at exactly
    /// the same point the inject path does, then shows the review editor with
    /// a live auto-insert countdown.
    private func beginReviewBeforeInsert(text: String,
                                         raw: String,
                                         refined: String?,
                                         generation: UInt64,
                                         externallyEnded: Bool) {
        let startDate = sessionStartDate
        let backend = sessionBackend
        let audioWAV = pendingAudioWAV
        pendingAudioWAV = nil
        let duration = startDate.map { Date().timeIntervalSince($0) } ?? 0
        sessionStartDate = nil

        // The session is over here — same sequencing point as the inject
        // path above, just without having injected anything yet.
        mediaController.resumeIfPaused()
        if externallyEnded {
            onSessionEndedExternally?()
        }

        activeReviewMode = .before
        reviewRawTranscript = raw
        reviewRefinedTranscript = refined
        reviewBackend = backend
        reviewDurationSeconds = duration
        reviewAudioWAV = audioWAV
        reviewHistoryID = nil

        appState.reviewText = text
        appState.reviewAwaitingInsert = true
        appState.reviewPolishFailed = refiner.lastPolishFailed
        appState.phase = .reviewing
        appState.transcript = TranscriptSnapshot()
        appState.silenceCountdown = nil
        appState.sessionKind = nil

        overlayPanel.allowsKeyFocus = true

        armReviewCountdown(generation: generation)
    }

    /// The active Polish preset's own review duration when it opts in,
    /// otherwise the global setting — read fresh each time a review starts
    /// or its countdown (re)arms, so a preset switch mid-flight can't leave
    /// a stale duration behind.
    private var activeReviewSeconds: TimeInterval {
        let preset = presets.selected
        let seconds = preset.reviewOverrideEnabled ? preset.reviewSeconds : settings.reviewSeconds
        return max(0.5, seconds)
    }

    /// Cancels the review's auto-dismiss/auto-insert timers. Fired once the
    /// user actually focuses the review editor — per spec, once they touch
    /// it, it waits (no more ticking, no more surprise auto-resolution).
    private func cancelReviewAutoDismiss() {
        reviewTimer?.invalidate()
        reviewTimer = nil
        cancelReviewCountdown()
    }

    /// Ticks `AppState.reviewCountdown` down from `settings.reviewSeconds` at
    /// a gentle 0.5 s cadence (a smooth ring would need a per-frame
    /// `TimelineView`, which `.reviewing` deliberately stays excluded from —
    /// see WaveformView's `isLive`). Auto-inserts the untouched text once it
    /// reaches zero.
    private func armReviewCountdown(generation: UInt64) {
        reviewCountdownTimer?.invalidate()
        let seconds = activeReviewSeconds
        reviewCountdownDeadline = Date().addingTimeInterval(seconds)
        appState.reviewCountdown = seconds
        reviewCountdownTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.sessionGeneration == generation else { return }
            self.tickReviewCountdown()
        }
    }

    private func tickReviewCountdown() {
        guard case .reviewing = appState.phase,
              activeReviewMode == .before,
              let deadline = reviewCountdownDeadline else {
            cancelReviewCountdown()
            return
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            cancelReviewCountdown()
            // Untouched dwell: insert the text exactly as shown.
            applyReviewBefore(corrected: appState.reviewText)
            return
        }
        appState.reviewCountdown = remaining
    }

    private func cancelReviewCountdown() {
        reviewCountdownTimer?.invalidate()
        reviewCountdownTimer = nil
        reviewCountdownDeadline = nil
        appState.reviewCountdown = nil
    }

    /// Ends a review with no further recording of its own — any recording
    /// that resolving it requires (insert-now/apply-edited/timeout via
    /// `applyReviewBefore`, or abandonment via `abandonReview`) must happen
    /// BEFORE calling this. Dismisses the overlay, drops back to idle, clears
    /// all review state, and revokes the panel's temporary key-focus grant.
    /// Safe to call even if no review is live. Every review exit path funnels
    /// through here so the countdown timer and key-focus grant are never left
    /// dangling.
    private func dismissReview() {
        reviewTimer?.invalidate()
        reviewTimer = nil
        cancelReviewCountdown()
        reviewHistoryID = nil
        reviewRefinedTranscript = nil
        reviewAudioWAV = nil
        activeReviewMode = .off
        overlayPanel.allowsKeyFocus = false
        overlayPanel.dismiss()
        appState.phase = .idle
        appState.reviewText = ""
        appState.reviewAwaitingInsert = false
    }

    /// Resolves a `.reviewing` phase that's being interrupted rather than
    /// explicitly resolved — Esc, a new `beginSession` reclaiming the panel,
    /// or an explicit `cancelSession`. "after" mode already injected and
    /// recorded to history when the review began, so this is pure UI
    /// teardown; "before" mode never injected, so — per "the transcript is
    /// sacred" — this still records the session to history with
    /// `injected: false` before tearing down, so an abandoned "before" review
    /// is never silently lost.
    /// applicationWillTerminate hook: a pending "before" review has been
    /// recorded NOWHERE yet (inject and history are both deferred to its
    /// resolution), so quitting mid-review would lose the transcript
    /// entirely. Resolve it as abandoned; pair with
    /// `HistoryStore.waitForPendingWrites` so the async write lands.
    func resolvePendingReviewForTermination() {
        if case .reviewing = appState.phase {
            abandonReview()
        }
    }

    private func abandonReview() {
        if activeReviewMode == .before {
            HistoryStore.shared.record(
                raw: reviewRawTranscript,
                refined: reviewRefinedTranscript,
                durationSeconds: max(0, reviewDurationSeconds),
                backend: reviewBackend,
                injected: false,
                audioWAV: reviewAudioWAV
            )
            // "before" mode never injected — this session never delivered text.
            SessionStatsStore.shared.append(injected: false, corrected: false)
        } else if activeReviewMode == .after {
            // "after" mode already injected + recorded to history when the
            // review began; interrupting it here (Esc, a new session
            // reclaiming the panel, app termination) is an uncorrected exit.
            SessionStatsStore.shared.append(injected: true, corrected: false)
        }
        dismissReview()
    }

    /// Folds a review-box edit into the vocabulary when it looks like a
    /// single mishearing correction rather than a larger rewrite — see
    /// `CorrectionLearner`. Shared by both review modes' correction paths.
    private func learnFromCorrectionIfSmall(original: String, corrected: String) {
        guard let candidate = CorrectionLearner.detectSubstitution(original: original, corrected: corrected) else { return }
        VocabularyStore.shared.learnFromCorrection(oldTerm: candidate.oldTerm, newTerm: candidate.newTerm)
    }

    /// Applies the user's action from the review editor — semantics differ by
    /// which mode produced the current review (see `activeReviewMode`).
    func applyReview(corrected: String) {
        guard case .reviewing = appState.phase else { return }
        switch activeReviewMode {
        case .before:
            applyReviewBefore(corrected: corrected)
        case .after:
            applyReviewAfterInsert(corrected: corrected)
        case .off:
            break // Unreachable: no review is ever shown while off.
        }
    }

    /// "after" mode — EXACTLY today's (pre-existing) behavior: if the edit
    /// matches the original injected text this is just a dismiss; otherwise
    /// the injected text is replaced in the target app (undo + re-paste) and
    /// the correction is recorded as gold-standard data.
    private func applyReviewAfterInsert(corrected: String) {
        let original = appState.reviewText

        guard corrected != original else {
            SessionStatsStore.shared.append(injected: true, corrected: false)
            dismissReview()
            return
        }

        CorrectionStore.shared.append(
            raw: reviewRawTranscript,
            injected: original,
            corrected: corrected,
            backend: reviewBackend
        )
        learnFromCorrectionIfSmall(original: original, corrected: corrected)

        if let id = reviewHistoryID {
            HistoryStore.shared.updateCorrection(id: id, corrected: corrected)
        }

        textInjector.replaceLastInjection(with: corrected)

        SessionStatsStore.shared.append(injected: true, corrected: true)
        dismissReview()
    }

    /// "before" mode — nothing has been injected yet, whether this fires from
    /// the countdown elapsing untouched, the "Insert now" affordance, or
    /// ⌘⏎/Apply after an edit. Injects `corrected` directly (plain
    /// `TextInjector.inject` — no undo dance needed, there is nothing prior to
    /// undo) and records the deferred history entry now that the outcome is
    /// known. When the text differs from what was shown (the user actually
    /// edited it), also appends the CorrectionStore gold-standard triple and
    /// sets `correctedTranscript` on the freshly-written record — the same
    /// recording shape as `applyReviewAfterInsert`, just against a record that
    /// didn't exist until this moment.
    private func applyReviewBefore(corrected: String) {
        let original = appState.reviewText

        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing to insert — treat like an abandoned review rather than
            // recording a phantom injection of empty text.
            abandonReview()
            return
        }

        // Snapshot everything BEFORE dismissReview() clears the review state.
        let raw = reviewRawTranscript
        let refined = reviewRefinedTranscript
        let duration = reviewDurationSeconds
        let backend = reviewBackend
        let audioWAV = reviewAudioWAV

        // Order matters: the panel may hold key focus right now (the user
        // clicked the editor or the Insert button). Injecting synthesizes
        // Cmd-V within ~50ms — posted mid focus-transition it can land in our
        // own dying editor or reach the target IME with the Command flag
        // dropped (a bare 'v' opens Squirrel's symbol/emoji candidates).
        // Resign key first, then give the target app ~150ms to take focus
        // back before any keystroke is posted — same discipline as
        // `replaceLastInjection` on the after-insert path.
        dismissReview()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.textInjector.inject(corrected)

            let recordID = HistoryStore.shared.record(
                raw: raw,
                refined: refined,
                durationSeconds: max(0, duration),
                backend: backend,
                injected: true,
                audioWAV: audioWAV
            )

            if corrected != original {
                CorrectionStore.shared.append(
                    raw: raw,
                    injected: original,
                    corrected: corrected,
                    backend: backend
                )
                self.learnFromCorrectionIfSmall(original: original, corrected: corrected)
                HistoryStore.shared.updateCorrection(id: recordID, corrected: corrected)
            }

            SessionStatsStore.shared.append(injected: true, corrected: corrected != original)
        }
    }
}
