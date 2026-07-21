import Foundation
import Combine

// MARK: - DictationPhase

enum DictationPhase: Equatable {
    case idle
    case connecting
    case listening
    case finalizing
    case refining
    case injecting
    /// The overlay stays up showing the just-injected text for a few seconds
    /// so the user can fix a mishearing in place. Not audio-active — see
    /// WaveformView.isLive and DictationController's review flow.
    case reviewing
    case error(String)
}

// MARK: - TranscriptSnapshot

struct TranscriptSnapshot: Equatable {
    /// Accumulated confirmed speech text.
    var finalText: String = ""
    /// Latest not-yet-confirmed speech fragment.
    var interimText: String = ""

    /// Full transcript as a single string (final + interim concatenated).
    var combined: String { finalText + interimText }

    /// True when `combined` is empty or contains only whitespace.
    var isEmpty: Bool { combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - SessionKind

enum SessionKind {
    case hold
    case toggle
    case handsFree
}

// MARK: - AppState

/// Central observable state written exclusively by DictationController (main thread).
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Current phase of the dictation pipeline.
    @Published var phase: DictationPhase = .idle

    /// Live transcript streamed from the ASR backend.
    @Published var transcript = TranscriptSnapshot()

    /// Normalised audio energy level in 0...1 for the waveform visualisation.
    @Published var audioLevel: Float = 0

    /// Countdown to hands-free auto-stop, in seconds. `nil` when not applicable.
    @Published var silenceCountdown: Double? = nil

    /// The kind of the currently active session. `nil` when no session is active.
    @Published var sessionKind: SessionKind? = nil

    /// The text shown for editing during `.reviewing`. In "after" mode this is
    /// already sitting in the target app; in "before" mode it has NOT been
    /// injected yet. Kept separate from `phase` (rather than an associated
    /// value) so the phase enum stays a simple switch target everywhere else.
    /// Only meaningful while `phase == .reviewing`.
    @Published var reviewText: String = ""

    /// True while the current `.reviewing` phase is "before"-mode: `reviewText`
    /// has NOT been inserted into the target app yet, so the editor renders
    /// as an insert decision rather than a correct-what's-already-there box
    /// (see `AppSettings.ReviewMode` and DictationController's review flow).
    /// Only meaningful while `phase == .reviewing`.
    @Published var reviewAwaitingInsert: Bool = false

    /// Seconds remaining before a "before"-mode review auto-inserts.
    /// `nil` whenever no countdown is running — "after"/"off" review, or once
    /// the user has touched the editor (touching cancels it; see
    /// DictationController.cancelReviewAutoDismiss). Ticked at a 0.5 s
    /// cadence, not a per-frame clock — see WaveformView's phase-gating note
    /// on why `.reviewing` must never need a `TimelineView`.
    @Published var reviewCountdown: Double? = nil

    private init() {}
}
