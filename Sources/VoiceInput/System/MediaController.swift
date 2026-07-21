import AppKit
import Foundation

// CoreServices / AE framework — used for TCC automation-permission probe.
// AEDeterminePermissionToAutomateTarget is declared in <AE/AppleEvents.h> which
// is part of CoreServices and re-exported through ApplicationServices. We
// import ApplicationServices to pull it in cleanly from Swift.
import ApplicationServices

/// Pauses currently-playing media when the user starts dictating and resumes
/// exactly the thing we paused when they are done.
///
/// Strategy (in priority order):
/// 1. Spotify — AppleScript "tell application "Spotify" to pause/play"
/// 2. Apple Music — AppleScript "tell application "Music" to pause/play"
///
/// There is deliberately NO generic fallback. The previous CoreAudio +
/// system-Play/Pause-media-key path was removed: the only available signal
/// (`kAudioDevicePropertyDeviceIsRunningSomewhere`) is true whenever ANY app
/// merely holds the output device open (browsers, Discord, etc., even while
/// silent), so it false-positived constantly. When it fired with nothing
/// actually playing, macOS routed the media key to its default handler and
/// LAUNCHED Apple Music. Only the two apps we can query precisely (Spotify,
/// Music) are paused; nothing can be launched.
///
/// MRMediaRemote is NOT used — `MRMediaRemoteSendCommand` has been ineffective
/// for unsigned third-party apps since macOS 15.4.
///
/// All AppleScript I/O runs as `/usr/bin/osascript` subprocesses on a private
/// serial queue — never on the caller's thread. `pauseIfPlaying`/
/// `resumeIfPaused` enqueue and return immediately (call-and-forget); the
/// queue being serial guarantees a `resumeIfPaused` enqueued right after
/// `pauseIfPlaying` runs only once the pause has actually completed and its
/// state (`didPauseMedia`/`strategy`) is settled.
///
/// TCC / automation consent: `.accessory` (no-Dock) apps do not bring
/// themselves to front when an AppleScript runs, so the TCC consent dialog can
/// be silently blocked behind other windows. Before a first Spotify/Music
/// AppleScript call we probe `AEDeterminePermissionToAutomateTarget` with
/// `askUserIfNeeded: false`; if the status indicates consent has NOT been
/// granted yet (errAEEventWouldRequireUserConsent) we call
/// `NSApp.activate(ignoringOtherApps: true)` once so the dialog is visible.
///
/// All pause/resume is guarded by `AppSettings.shared.mediaAutoPause` checked
/// INSIDE these methods so callers stay unconditional.
final class MediaController {

    // MARK: - State (confined to `queue` — see below)

    private var didPauseMedia = false

    private enum Strategy {
        case spotify
        case music
    }
    private var strategy: Strategy?

    /// Serializes all AppleScript subprocess launches. `waitUntilExit` runs
    /// here, which is fine — this is never the main thread.
    private let queue = DispatchQueue(label: "com.zhijie.VoiceInput.MediaController")

    // MARK: - Init / deinit

    init() {}

    // MARK: - Public API

    /// Pauses media if something is playing. Enqueues the work and returns
    /// immediately; does not block the caller.
    ///
    /// Guards `AppSettings.shared.mediaAutoPause` first. Only the strategy that
    /// actually succeeds sets `didPauseMedia = true`, so `resumeIfPaused()` only
    /// undoes what we did.
    func pauseIfPlaying() {
        queue.async { [weak self] in
            self?.pauseIfPlayingOnQueue()
        }
    }

    /// Resumes only the source we actually paused. Enqueues the work and
    /// returns immediately.
    ///
    /// Deliberately does NOT re-check `AppSettings.shared.mediaAutoPause`: the
    /// gate lives in `pauseIfPlaying`, and whatever we actually paused must
    /// always be resumed even if the user toggles the setting off mid-session.
    /// Otherwise their media would stay paused forever.
    func resumeIfPaused() {
        queue.async { [weak self] in
            self?.resumeIfPausedOnQueue()
        }
    }

    // MARK: - Queue-confined implementation

    private func pauseIfPlayingOnQueue() {
        didPauseMedia = false
        strategy = nil

        guard AppSettings.shared.mediaAutoPause else {
            Log.app.info("MediaController: mediaAutoPause disabled — skipping pause")
            return
        }

        // --- Spotify (precise) ---
        if isAppRunning("com.spotify.client") {
            Log.app.info("MediaController: Spotify is running — checking state")
            if playerState(app: "Spotify") == "playing" {
                // Only bring ourselves to front when an AppleScript that needs
                // consent is actually imminent, so we never steal focus when
                // nothing is playing.
                activateIfConsentNeeded(bundleID: "com.spotify.client")
                if runSimple("tell application \"Spotify\" to pause") {
                    strategy = .spotify
                    didPauseMedia = true
                    Log.app.info("MediaController: paused Spotify via AppleScript")
                    return
                } else {
                    Log.app.warning("MediaController: Spotify AppleScript pause failed (TCC denied?)")
                }
            } else {
                Log.app.info("MediaController: Spotify not playing — no pause needed")
            }
        } else {
            Log.app.info("MediaController: Spotify not running")
        }

        // --- Apple Music (precise) ---
        if isAppRunning("com.apple.Music") {
            Log.app.info("MediaController: Music is running — checking state")
            if playerState(app: "Music") == "playing" {
                // Only bring ourselves to front when an AppleScript that needs
                // consent is actually imminent, so we never steal focus when
                // nothing is playing.
                activateIfConsentNeeded(bundleID: "com.apple.Music")
                if runSimple("tell application \"Music\" to pause") {
                    strategy = .music
                    didPauseMedia = true
                    Log.app.info("MediaController: paused Music via AppleScript")
                    return
                } else {
                    Log.app.warning("MediaController: Music AppleScript pause failed (TCC denied?)")
                }
            } else {
                Log.app.info("MediaController: Music not playing — no pause needed")
            }
        } else {
            Log.app.info("MediaController: Apple Music not running")
        }

        // No generic fallback by design — see the type doc comment.
        Log.app.info("MediaController: no Spotify/Music playback to pause")
    }

    private func resumeIfPausedOnQueue() {
        guard didPauseMedia, let strategy else {
            Log.app.info("MediaController: resumeIfPaused called but nothing was paused — no-op")
            return
        }
        didPauseMedia = false
        self.strategy = nil

        switch strategy {
        case .spotify:
            _ = runSimple("tell application \"Spotify\" to play")
            Log.app.info("MediaController: resumed Spotify via AppleScript")
        case .music:
            _ = runSimple("tell application \"Music\" to play")
            Log.app.info("MediaController: resumed Music via AppleScript")
        }
    }

    // MARK: - TCC consent probe

    /// Probes automation permission for `bundleID` WITHOUT prompting the user.
    /// If the status indicates consent is not yet granted
    /// (`errAEEventWouldRequireUserConsent` == -1744) we activate the app once
    /// so that the TCC dialog (which fires on the next actual AppleScript call)
    /// is visible in front of other windows.
    private func activateIfConsentNeeded(bundleID: String) {
        // Build an AEAddressDesc targeting the app by bundle ID.
        // typeApplicationBundleID lets us address the app without a pid.
        guard let cfID = bundleID as CFString?,
              let data = CFStringCreateExternalRepresentation(
                  nil, cfID, CFStringBuiltInEncodings.UTF8.rawValue, 0)
        else { return }

        var target = AEDesc()
        let cfDataPtr = CFDataGetBytePtr(data)
        let cfDataLen = CFDataGetLength(data)

        // typeApplicationBundleID = 'bund' = 0x62756E64
        let typeApplicationBundleID: OSType = 0x62756E64
        let createErr = AECreateDesc(typeApplicationBundleID, cfDataPtr, cfDataLen, &target)
        guard createErr == noErr else {
            Log.app.warning("MediaController: AECreateDesc failed \(createErr) for \(bundleID)")
            return
        }
        defer { AEDisposeDesc(&target) }

        // typeWildCard for both class and ID means "any Apple event".
        let typeWildCard: OSType = 0x2A2A2A2A // '****'
        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            false   // askUserIfNeeded: false — probe only, do NOT prompt here
        )

        // errAEEventWouldRequireUserConsent == -1744: permission not yet decided.
        // errAEEventNotPermitted == -1743: user already denied (nothing we can do).
        // procNotFound == -600: target not running (shouldn't happen — we checked).
        // noErr == 0: already permitted.
        switch status {
        case noErr:
            Log.app.info("MediaController: automation consent already granted for \(bundleID)")
        case OSStatus(-1744): // errAEEventWouldRequireUserConsent
            Log.app.info("MediaController: consent not yet determined for \(bundleID) — activating app so TCC dialog is visible")
            // NSApp.activate touches AppKit — hop back to main rather than
            // calling it from this background queue.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        case OSStatus(-1743): // errAEEventNotPermitted
            Log.app.warning("MediaController: automation denied for \(bundleID) — AppleScript will fail")
        case OSStatus(-600): // procNotFound
            Log.app.info("MediaController: \(bundleID) not running (procNotFound) — consent probe skipped")
        default:
            Log.app.warning("MediaController: AEDeterminePermissionToAutomateTarget returned \(status) for \(bundleID)")
        }
    }

    // MARK: - AppleScript helpers (queue-confined)

    private func isAppRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Returns "playing", "paused", "stopped", or nil on script error.
    private func playerState(app: String) -> String? {
        let source = "tell application \"\(app)\" to return player state as string"
        guard let state = runOSAScript(source), !state.isEmpty else { return nil }
        Log.app.info("MediaController: \(app) player state = \(state)")
        return state
    }

    /// Runs a one-liner AppleScript. Returns true on success.
    @discardableResult
    private func runSimple(_ source: String) -> Bool {
        runOSAScript(source) != nil
    }

    /// Runs `source` via `/usr/bin/osascript -e` and returns trimmed stdout,
    /// or nil if the process failed to launch or exited non-zero.
    private func runOSAScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            Log.app.warning("MediaController: osascript launch failed: \(error.localizedDescription)")
            return nil
        }

        // Drain stdout to EOF before waitUntilExit: osascript's output here is
        // a few bytes, but reading first avoids ever blocking on a full pipe
        // while the child blocks on write.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            Log.app.warning("MediaController: osascript exited \(process.terminationStatus)")
            return nil
        }
        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
