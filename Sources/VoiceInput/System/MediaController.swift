import AppKit
import Combine
import Foundation

/// Transient diagnostics for Settings; never stores playback titles or URLs.
final class MediaControlStatus: ObservableObject {
    static let shared = MediaControlStatus()
    @Published private(set) var message = "Supports Spotify, Apple Music, and HTML5 audio/video in Chrome and Safari. Automation access is required."

    func update(_ message: String) {
        DispatchQueue.main.async { self.message = message }
    }
}

enum MediaScriptResult {
    case success(String)
    case failure(String)
    case timedOut
}

/// Controls only known, already-running players. Never sends a generic media
/// key: that can launch Apple Music when nothing is actually playing.
/// State checks and actions share one AppleScript, addressed by bundle ID.
/// All subprocess work is serialized and bounded; the main thread only queues
/// work. Resume is paired with successful pauses, even if the setting changes.
final class MediaController {
    struct Player {
        let bundleID: String
        let name: String
    }
    static let supportedPlayers = [
        Player(bundleID: "com.spotify.client", name: "Spotify"),
        Player(bundleID: "com.apple.Music", name: "Apple Music"),
    ]

    private let queue = DispatchQueue(label: "com.zhijie.VoiceInput.MediaController")
    private let enabled: () -> Bool
    private let isRunning: (String) -> Bool
    private let runScript: (String) -> MediaScriptResult
    private let report: (String) -> Void
    // Confined to queue. A repeated pause must not discard these receipts.
    private var pausedPlayers: [Player] = []
    private var browserReceipts: [(browser: BrowserMediaScripts.Browser, token: String)] = []

    init(enabled: @escaping () -> Bool = { AppSettings.shared.mediaAutoPause },
         isRunning: @escaping (String) -> Bool = { bundleID in
             NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
         },
         runScript: @escaping (String) -> MediaScriptResult = MediaController.executeScript,
         report: @escaping (String) -> Void = { MediaControlStatus.shared.update($0) }) {
        self.enabled = enabled
        self.isRunning = isRunning
        self.runScript = runScript
        self.report = report
    }

    func pauseIfPlaying() {
        // Read UI-bound settings on the caller (main) thread, not the worker.
        let shouldPause = enabled()
        queue.async { [weak self] in
            guard let self, shouldPause, self.pausedPlayers.isEmpty,
                  self.browserReceipts.isEmpty else { return }
            var foundPlayer = false
            var failures: [String] = []
            for player in Self.supportedPlayers where self.isRunning(player.bundleID) {
                foundPlayer = true
                switch self.runScript(Self.script(for: player, action: .pause)) {
                case .success("paused"):
                    self.pausedPlayers.append(player)
                case .success("idle"), .success("not-running"):
                    break
                case .success:
                    failures.append("\(player.name): unexpected response from player.")
                case .failure(let detail):
                    failures.append(Self.failureMessage(player: player, detail: detail))
                case .timedOut:
                    failures.append("\(player.name): control timed out. Check Automation access in System Settings.")
                }
            }
            var browserMediaCount = 0
            for browser in BrowserMediaScripts.Browser.allCases where self.isRunning(browser.bundleID) {
                foundPlayer = true
                let token = UUID().uuidString
                // Even a timed-out script may have paused some tabs. The token
                // can restore only those elements for which JS stored a receipt.
                self.browserReceipts.append((browser, token))
                let script = BrowserMediaScripts.appleScript(browser: browser,
                    javaScript: BrowserMediaScripts.pauseJavaScript(token: token))
                switch self.runScript(script) {
                case .success(let result):
                    let counts = result.split(separator: ":").compactMap { Int($0) }
                    if counts.count == 2 {
                        browserMediaCount += counts[0]
                        if counts[1] > 0 {
                            failures.append("\(browser.name): \(counts[1]) tabs unavailable. Enable \(browser.permissionHelp). Restricted pages and embedded cross-origin players may remain unavailable.")
                        }
                    } else {
                        failures.append("\(browser.name): could not confirm media control.")
                    }
                case .failure:
                    failures.append("\(browser.name): check Automation access and \(browser.permissionHelp).")
                case .timedOut:
                    failures.append("\(browser.name): media control timed out. Check Automation access and \(browser.permissionHelp).")
                }
            }
            if !failures.isEmpty {
                self.report(failures.joined(separator: " "))
            } else if !self.pausedPlayers.isEmpty || browserMediaCount > 0 {
                let apps = self.pausedPlayers.map(\.name)
                let summary = apps + (browserMediaCount > 0 ? ["\(browserMediaCount) browser media elements"] : [])
                self.report("Paused \(summary.joined(separator: " and ")).")
            } else {
                self.report(foundPlayer
                    ? "Automation access succeeded; supported players are not playing."
                    : "No supported player is running. Open Spotify, Apple Music, Chrome or Safari. IINA and other players are not controlled.")
            }
        }
    }

    func resumeIfPaused() {
        queue.async { [weak self] in self?.resumeOnQueue() }
    }

    /// Used only during application termination, where async work may be cut off.
    func resumeIfPausedAndWait(timeout: TimeInterval) {
        let finished = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.resumeOnQueue()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + timeout)
    }

    /// Explicit Settings action: queries state/permission without pausing,
    /// resuming, activating, or launching a player. macOS may ask for consent.
    func checkAccess() {
        queue.async { [self] in
            let running = Self.supportedPlayers.filter { self.isRunning($0.bundleID) }
            let browsers = BrowserMediaScripts.Browser.allCases.filter { self.isRunning($0.bundleID) }
            guard !running.isEmpty || !browsers.isEmpty else {
                self.report("Open Spotify, Apple Music, Chrome or Safari first, then check access. IINA and other players are not supported.")
                return
            }
            var messages: [String] = []
            for player in running {
                switch self.runScript(Self.script(for: player, action: .check)) {
                case .success("not-running"):
                    messages.append("\(player.name) is no longer running.")
                case .success:
                    messages.append("\(player.name): Automation access available.")
                case .failure(let detail):
                    messages.append(Self.failureMessage(player: player, detail: detail))
                case .timedOut:
                    messages.append("\(player.name): timed out. Check for an Automation consent dialog.")
                }
            }
            for browser in browsers {
                // Probe JS capability without inspecting or mutating media.
                let result = self.runScript(BrowserMediaScripts.appleScript(browser: browser, javaScript: "0"))
                switch result {
                case .success(let counts) where counts.hasSuffix(":0"):
                    messages.append("\(browser.name): available on accessible tabs (if any).")
                default:
                    messages.append("\(browser.name): check Automation access and \(browser.permissionHelp). Some restricted pages cannot be controlled.")
                }
            }
            self.report(messages.joined(separator: " "))
        }
    }

    private func resumeOnQueue() {
        let players = pausedPlayers
        pausedPlayers.removeAll()
        var messages: [String] = []
        for player in players {
            // The user may have quit the player during dictation. Do not reopen it.
            guard isRunning(player.bundleID) else {
                messages.append("\(player.name) was closed; playback was not restarted.")
                continue
            }
            switch runScript(Self.script(for: player, action: .resume)) {
            case .success("resumed"):
                messages.append("Resumed \(player.name).")
            case .success:
                messages.append("\(player.name): playback state changed; no resume needed.")
            case .failure(let detail):
                messages.append(Self.failureMessage(player: player, detail: detail))
            case .timedOut:
                messages.append("\(player.name): resume timed out. Resume playback manually.")
            }
        }
        let receipts = browserReceipts
        browserReceipts.removeAll()
        for receipt in receipts where isRunning(receipt.browser.bundleID) {
            let script = BrowserMediaScripts.appleScript(browser: receipt.browser,
                javaScript: BrowserMediaScripts.resumeJavaScript(token: receipt.token))
            switch runScript(script) {
            case .success(let counts):
                let values = counts.split(separator: ":").compactMap { Int($0) }
                if values.count == 2, values[1] == 0 {
                    messages.append("\(receipt.browser.name): resume requested for \(values[0]) unchanged media elements.")
                } else {
                    messages.append("\(receipt.browser.name): some tabs could not resume. Resume playback manually if needed.")
                }
            default:
                messages.append("\(receipt.browser.name): could not restore browser playback. Resume manually if needed.")
            }
        }
        if !messages.isEmpty { report(messages.joined(separator: " ")) }
    }

    private enum Action { case pause, resume, check }

    private static func script(for player: Player, action: Action) -> String {
        let operation: String
        switch action {
        case .pause:
            operation = """
            if player state is playing then
                pause
                return "paused"
            end if
            return "idle"
            """
        case .resume:
            operation = """
            if player state is paused then
                play
                return "resumed"
            end if
            return "unchanged"
            """
        case .check:
            operation = "return player state as string"
        }
        // Repeat the running check inside the script to cover a player exiting
        // after NSWorkspace's snapshot. Never use `activate` or a media key.
        return """
        with timeout of 3 seconds
            if application id "\(player.bundleID)" is running then
                tell application id "\(player.bundleID)"
                    \(operation)
                end tell
            end if
            return "not-running"
        end timeout
        """
    }

    private static func failureMessage(player: Player, detail: String) -> String {
        if detail.contains("-1743") || detail.contains("-1744") {
            return "\(player.name): Automation access denied. Enable VoiceInput → \(player.name) in System Settings → Privacy & Security → Automation."
        }
        if detail.contains("-1712") {
            return "\(player.name): control timed out. Check Automation access or retry after the player responds."
        }
        // These fixed scripts contain no titles/URLs; cap diagnostic length.
        return "\(player.name): \(detail.prefix(250))"
    }

    static func executeScript(_ source: String) -> MediaScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { return .failure("Unable to run media control: \(error.localizedDescription)") }

        // Both pipes must be drained, including stderr (previously discarded).
        let output = ScriptOutput()
        let readers = DispatchGroup()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                output.store(pipe.fileHandleForReading.readDataToEndOfFile(), isError: isError)
                readers.leave()
            }
        }
        let timedOut = finished.wait(timeout: .now() + 4) == .timedOut
        if timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.2)
            }
        }
        _ = readers.wait(timeout: .now() + 0.2)
        if timedOut { return .timedOut }
        let (out, err) = output.snapshot()
        guard process.terminationStatus == 0 else {
            return .failure(err.isEmpty ? "Media control exited with code \(process.terminationStatus)." : err)
        }
        return .success(out)
    }
}

private final class ScriptOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    func store(_ data: Data, isError: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isError { stderr = data } else { stdout = data }
    }
    func snapshot() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Official installed sdefs: Chrome `execute tab javascript`, Safari
/// `do JavaScript ... in tab`. Scripts return counts only, never page data.
enum BrowserMediaScripts {
    enum Browser: CaseIterable {
        case chrome, safari
        var bundleID: String { self == .chrome ? "com.google.Chrome" : "com.apple.Safari" }
        var name: String { self == .chrome ? "Chrome" : "Safari" }
        var permissionHelp: String {
            self == .chrome
                ? "Chrome → View → Developer → Allow JavaScript from Apple Events"
                : "Safari → Develop → Allow JavaScript from Apple Events"
        }
    }

    static func pauseJavaScript(token: String) -> String {
        // token is always a locally generated UUID, never webpage/user input.
        """
        (() => {
          const key = '__voiceinput_media_\(token)';
          if (document[key]) return 0;
          const state = { document, items: [] };
          document[key] = state;
          for (const media of document.querySelectorAll('video,audio')) {
            if (media.paused || media.ended || media.readyState < 2) continue;
            const item = { media, owner: document, sourceObject: media.srcObject, valid: true };
            const invalidate = () => { item.valid = false; };
            const events = ['play', 'seeking', 'emptied', 'loadstart', 'ended'];
            const observer = new MutationObserver(invalidate);
            try {
              media.pause();
              if (!media.paused) continue;
              events.forEach(event => media.addEventListener(event, invalidate));
              observer.observe(media, { attributes: true, attributeFilter: ['src'], childList: true, subtree: true });
              item.cleanup = () => {
                events.forEach(event => media.removeEventListener(event, invalidate));
                observer.disconnect();
              };
              item.observer = observer;
              state.items.push(item);
            } catch (_) { observer.disconnect(); }
          }
          if (!state.items.length) { delete document[key]; return 0; }
          // Expire receipts without playing anything if the app goes away.
          state.timer = setTimeout(() => {
            state.items.forEach(item => item.cleanup());
            delete document[key];
          }, 3600000);
          return state.items.length;
        })()
        """
    }

    static func resumeJavaScript(token: String) -> String {
        """
        (() => {
          const key = '__voiceinput_media_\(token)';
          const state = document[key];
          if (!state || state.document !== document) return 0;
          delete document[key];
          clearTimeout(state.timer);
          let count = 0;
          for (const item of state.items) {
            const media = item.media;
            if (item.observer.takeRecords().length) item.valid = false;
            item.cleanup();
            if (!item.valid || !media.isConnected || item.owner !== document ||
                media.ownerDocument !== document || media.srcObject !== item.sourceObject ||
                !media.paused || media.ended) continue;
            try {
              const promise = media.play();
              if (promise && promise.catch) promise.catch(() => {});
              count++;
            } catch (_) {}
          }
          return count;
        })()
        """
    }

    static func appleScript(browser: Browser, javaScript: String) -> String {
        let quoted = "\"" + javaScript.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let command = browser == .chrome
            ? "execute currentTab javascript \(quoted)"
            : "do JavaScript \(quoted) in currentTab"
        return """
        with timeout of 3 seconds
            if application id "\(browser.bundleID)" is not running then return "0:0"
            tell application id "\(browser.bundleID)"
                set controlledCount to 0
                set unavailableCount to 0
                repeat with currentWindow in windows
                    repeat with currentTab in tabs of currentWindow
                        try
                            set mediaCount to (\(command))
                            set controlledCount to controlledCount + (mediaCount as integer)
                        on error errorMessage number errorNumber
                            if errorNumber is -1743 then error "Automation access denied" number -1743
                            set unavailableCount to unavailableCount + 1
                        end try
                    end repeat
                end repeat
                return (controlledCount as text) & ":" & (unavailableCount as text)
            end tell
        end timeout
        """
    }
}
