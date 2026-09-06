import Foundation
import JavaScriptCore
import Testing
@testable import VoiceInput

struct MediaControllerTests {
    @Test func deniedAutomationIsVisibleAndDoesNotResume() {
        let fixture = MediaFixture(result: .failure("Not authorized to send Apple events (-1743)"))
        fixture.controller.pauseIfPlaying()
        fixture.controller.resumeIfPausedAndWait(timeout: 1)
        #expect(fixture.scripts.count == 1)
        #expect(fixture.messages.contains { $0.contains("Automation access denied") })
    }

    @Test func duplicatePausePreservesReceipt() {
        let fixture = MediaFixture(result: .success("paused"))
        fixture.controller.pauseIfPlaying()
        fixture.controller.pauseIfPlaying()
        fixture.controller.resumeIfPausedAndWait(timeout: 1)
        #expect(fixture.scripts.count == 2)
        #expect(fixture.scripts.last?.contains("if player state is paused then") == true)
    }

    @Test func disablingSettingAfterPauseStillResumes() {
        let fixture = MediaFixture(result: .success("paused"))
        fixture.controller.pauseIfPlaying()
        fixture.enabled = false
        fixture.controller.resumeIfPausedAndWait(timeout: 1)
        #expect(fixture.scripts.count == 2)
    }

    @Test func stoppedPlayerIsNeverStarted() {
        let fixture = MediaFixture(result: .success("idle"))
        fixture.controller.pauseIfPlaying()
        fixture.controller.resumeIfPausedAndWait(timeout: 1)
        #expect(fixture.scripts.count == 1)
        #expect(fixture.scripts[0].contains("if player state is playing then"))
    }

    @Test func playerQuitDuringDictationIsNotRelaunched() {
        let fixture = MediaFixture(result: .success("paused"), runningChecks: [true, false, false])
        fixture.controller.pauseIfPlaying()
        fixture.controller.resumeIfPausedAndWait(timeout: 1)
        #expect(fixture.scripts.count == 1)
    }

    @Test func timeoutIsVisibleAndQueueStillCompletes() {
        let fixture = MediaFixture(result: .timedOut)
        fixture.controller.pauseIfPlaying()
        fixture.controller.resumeIfPausedAndWait(timeout: 1)
        #expect(fixture.messages.contains { $0.contains("timed out") })
        #expect(fixture.scripts.count == 1)
    }

    @Test func partiallyTimedOutBrowserStillGetsTokenScopedResume() {
        let fixture = MediaFixture(result: .timedOut, runningBundleID: "com.google.Chrome")
        fixture.controller.pauseIfPlaying()
        fixture.controller.resumeIfPausedAndWait(timeout: 1)
        #expect(fixture.scripts.count == 2)
        #expect(fixture.scripts.last?.contains("state.document !== document") == true)
    }

    @Test func browserAccessFailureIsActionableWithoutLeakingPageDetails() {
        let fixture = MediaFixture(result: .failure("private-page-detail"), runningBundleID: "com.apple.Safari")
        fixture.controller.pauseIfPlaying()
        fixture.controller.resumeIfPausedAndWait(timeout: 1)
        #expect(fixture.messages.contains { $0.contains("Allow JavaScript from Apple Events") })
        #expect(!fixture.messages.contains { $0.contains("private-page-detail") })
    }

    @Test func noSupportedPlayerRunsNoCommands() {
        let fixture = MediaFixture(result: .success("paused"), runningChecks: [false, false])
        fixture.controller.pauseIfPlaying()
        fixture.controller.resumeIfPausedAndWait(timeout: 1)
        #expect(fixture.scripts.isEmpty)
        #expect(fixture.messages.contains { $0.contains("No supported player") })
    }
}

/// Each fixture's callbacks run only on its controller's serial queue. Reads
/// happen after resumeIfPausedAndWait establishes completion synchronization.
private final class MediaFixture {
    var enabled = true
    var scripts: [String] = []
    var messages: [String] = []
    private var runningChecks: [Bool]?
    private let result: MediaScriptResult
    private let runningBundleID: String
    lazy var controller = MediaController(
        enabled: { [unowned self] in self.enabled },
        isRunning: { [unowned self] bundleID in
            if bundleID == self.runningBundleID, var checks = self.runningChecks, !checks.isEmpty {
                let value = checks.removeFirst()
                self.runningChecks = checks
                return value
            }
            return bundleID == self.runningBundleID
        },
        runScript: { [unowned self] source in
            self.scripts.append(source)
            return self.result
        },
        report: { [unowned self] message in self.messages.append(message) }
    )

    init(result: MediaScriptResult, runningChecks: [Bool]? = nil, runningBundleID: String = "com.spotify.client") {
        self.result = result
        self.runningChecks = runningChecks
        self.runningBundleID = runningBundleID
    }
}


struct BrowserMediaScriptTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var document = {querySelectorAll: () => mediaItems};
        var mediaItems = [];
        var setTimeout = () => 1;
        var clearTimeout = () => {};
        class MutationObserver {
          constructor(callback) { this.callback = callback; this.records = []; }
          observe(media) { media.observer = this; }
          disconnect() {}
          takeRecords() { const result = this.records; this.records = []; return result; }
        }
        function makeMedia(paused) {
          return {
            paused, ended: false, readyState: 4, srcObject: null,
            ownerDocument: document, isConnected: true, events: {}, playCount: 0,
            pause() { this.paused = true; },
            play() { this.paused = false; this.playCount++; return {catch() {}}; },
            addEventListener(name, callback) { this.events[name] = callback; },
            removeEventListener(name) { delete this.events[name]; }
          };
        }
        """)
        return context
    }

    @Test func pausesOnlyPlayingElementsAndRestoresOnce() throws {
        let js = try context()
        js.evaluateScript("mediaItems = [makeMedia(false), makeMedia(true)];")
        #expect(js.evaluateScript(BrowserMediaScripts.pauseJavaScript(token: "test"))?.toInt32() == 1)
        #expect(js.evaluateScript(BrowserMediaScripts.resumeJavaScript(token: "test"))?.toInt32() == 1)
        #expect(js.evaluateScript(BrowserMediaScripts.resumeJavaScript(token: "test"))?.toInt32() == 0)
        #expect(js.evaluateScript("mediaItems[0].playCount")?.toInt32() == 1)
        #expect(js.evaluateScript("mediaItems[1].playCount")?.toInt32() == 0)
        #expect(js.exception == nil)
    }

    @Test func navigatingDocumentDoesNotResumeNewPage() throws {
        let js = try context()
        js.evaluateScript("mediaItems = [makeMedia(false)];")
        js.evaluateScript(BrowserMediaScripts.pauseJavaScript(token: "test"))
        js.evaluateScript("document = {querySelectorAll: () => mediaItems};")
        #expect(js.evaluateScript(BrowserMediaScripts.resumeJavaScript(token: "test"))?.toInt32() == 0)
    }

    @Test func removedMediaIsNeverResumed() throws {
        let js = try context()
        js.evaluateScript("mediaItems = [makeMedia(false)];")
        js.evaluateScript(BrowserMediaScripts.pauseJavaScript(token: "test"))
        js.evaluateScript("mediaItems[0].isConnected = false;")
        #expect(js.evaluateScript(BrowserMediaScripts.resumeJavaScript(token: "test"))?.toInt32() == 0)
    }

    @Test func sourceMutationDiscardsReceipt() throws {
        let js = try context()
        js.evaluateScript("mediaItems = [makeMedia(false)];")
        js.evaluateScript(BrowserMediaScripts.pauseJavaScript(token: "test"))
        js.evaluateScript("mediaItems[0].observer.records.push({type: 'attributes'});")
        #expect(js.evaluateScript(BrowserMediaScripts.resumeJavaScript(token: "test"))?.toInt32() == 0)
    }

    @Test func userPlaybackChangeDiscardsReceipt() throws {
        let js = try context()
        js.evaluateScript("mediaItems = [makeMedia(false)];")
        js.evaluateScript(BrowserMediaScripts.pauseJavaScript(token: "test"))
        js.evaluateScript("mediaItems[0].events.play();")
        #expect(js.evaluateScript(BrowserMediaScripts.resumeJavaScript(token: "test"))?.toInt32() == 0)
    }

    @Test func appleScriptUsesOfficialCommandsAndNoPageContent() {
        let js = BrowserMediaScripts.pauseJavaScript(token: "test")
        let chrome = BrowserMediaScripts.appleScript(browser: .chrome, javaScript: js)
        let safari = BrowserMediaScripts.appleScript(browser: .safari, javaScript: js)
        #expect(chrome.contains("execute currentTab javascript"))
        #expect(safari.contains("do JavaScript"))
        #expect(chrome.contains("is not running then return"))
        for source in [chrome, safari] {
            #expect(!source.contains("innerText"))
            #expect(!source.contains("currentSrc"))
            #expect(!source.contains("URL of"))
            #expect(!source.contains("activate"))
        }
    }
}
