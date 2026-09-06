import AppKit
import SwiftUI
import Testing
@testable import VoiceInput

@Suite(.serialized)
@MainActor
struct HotkeyRegressionTests {
    private func fixture() -> (NSWindow, ShortcutRecorderButton) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = ShortcutRecorderButton(frame: NSRect(x: 20, y: 30, width: 280, height: 34))
        window.contentView?.addSubview(button)
        return (window, button)
    }

    private func key(_ window: NSWindow, code: UInt16, flags: NSEvent.ModifierFlags = [],
                     type: NSEvent.EventType = .keyDown, characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)!
    }

    @Test func swiftUIBridgeMountsAVisibleClickableNativeRecorder() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ShortcutRecorder(
            keyCode: .constant(24),
            modifierFlags: .constant(Int(HotkeyShortcut.defaultModifierFlags.rawValue)),
            keyEquivalent: .constant("="), triggerKey: .constant(.customShortcut),
            isRecording: .constant(false)
        ).frame(width: 280, height: 34))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        func recorder(in view: NSView) -> ShortcutRecorderButton? {
            if let button = view as? ShortcutRecorderButton { return button }
            return view.subviews.lazy.compactMap { recorder(in: $0) }.first
        }
        let button = try #require(recorder(in: host))
        defer { button.endRecording() }
        #expect(button.bounds.width >= 270)
        #expect(button.bounds.height >= 30)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
        #expect(host.hitTest(point) === button)
        button.performClick(nil)
        #expect(button.isRecording)
        #expect(window.firstResponder === button)
        window.sendEvent(key(window, code: 0, flags: [.command], characters: "a"))
        #expect(!button.isRecording)
        #expect(button.shortcut.keyCode == 0)
    }

    @Test func nativeButtonHasHitTargetAndCapturesThroughWindowResponder() {
        let (window, button) = fixture()
        defer { button.endRecording(); window.close() }
        #expect(window.contentView?.hitTest(NSPoint(x: 100, y: 45)) === button)
        button.performClick(nil)
        #expect(button.isRecording)
        #expect(window.firstResponder === button)
        #expect(ShortcutCaptureCoordinator.isRecording)
        var result: HotkeyShortcut?
        button.onCapture = { result = $0 }
        // This uses NSWindow event dispatch and the real first responder;
        // no synthetic event is posted to the system or another app.
        window.sendEvent(key(window, code: 37, flags: [.control], characters: "\u{000C}"))
        #expect(result?.keyCode == 37)
        #expect(result?.modifierFlags == [.control])
        #expect(result?.keyEquivalent == "L")
        #expect(!button.isRecording)
        #expect(!ShortcutCaptureCoordinator.isRecording)
    }

    @Test func escapeAndSecondClickCancelWithoutChangingShortcut() {
        let (window, button) = fixture()
        defer { button.endRecording(); window.close() }
        let original = button.shortcut
        var captures = 0
        button.onCapture = { _ in captures += 1 }
        button.performClick(nil)
        window.sendEvent(key(window, code: 53))
        #expect(!button.isRecording)
        button.performClick(nil)
        button.performClick(nil)
        #expect(!button.isRecording)
        #expect(button.shortcut == original)
        #expect(captures == 0)
    }

    @Test func bareKeyDoesNotReplaceShortcutAndTimeoutReleasesCapture() {
        let (window, button) = fixture()
        defer { button.endRecording(); window.close() }
        button.recordingTimeout = 0.02
        button.performClick(nil)
        window.sendEvent(key(window, code: 0, characters: "a"))
        #expect(button.isRecording)
        #expect(button.shortcut == .default)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        #expect(!button.isRecording)
        #expect(!ShortcutCaptureCoordinator.isRecording)
    }

    @Test func rightModifierAndFnAreAcceptedOnRelease() {
        let (window, button) = fixture()
        defer { button.endRecording(); window.close() }
        for (code, flag, expected) in [(UInt16(61), NSEvent.ModifierFlags.option, HotkeyKey.rightOption),
                                       (UInt16(63), NSEvent.ModifierFlags.function, HotkeyKey.fn)] {
            var result: HotkeyKey?
            button.onModifierCapture = { result = $0 }
            button.performClick(nil)
            window.sendEvent(key(window, code: code, flags: flag, type: .flagsChanged))
            #expect(button.isRecording)
            window.sendEvent(key(window, code: code, type: .flagsChanged))
            #expect(result == expected)
            #expect(!button.isRecording)
        }
    }

    @Test func modifierChordRecordsCombinationInsteadOfPrematureModifier() {
        let (window, button) = fixture()
        defer { button.endRecording(); window.close() }
        var modifierResult: HotkeyKey?
        var shortcutResult: HotkeyShortcut?
        button.onModifierCapture = { modifierResult = $0 }
        button.onCapture = { shortcutResult = $0 }
        button.performClick(nil)
        window.sendEvent(key(window, code: 61, flags: [.option], type: .flagsChanged))
        window.sendEvent(key(window, code: 49, flags: [.option], characters: " "))
        #expect(modifierResult == nil)
        #expect(shortcutResult?.keyCode == 49)
        #expect(shortcutResult?.modifierFlags == [.option])
    }

    @Test func captionShortcutIsExplainedInsteadOfSavingConflict() {
        let (window, button) = fixture()
        defer { button.endRecording(); window.close() }
        button.performClick(nil)
        window.sendEvent(key(window, code: 49, flags: [.function], characters: " "))
        #expect(button.isRecording)
        #expect(button.shortcut == .default)
        #expect(button.title.contains("reserved"))
        window.sendEvent(key(window, code: 49, flags: [.function, .control], characters: " "))
        #expect(!button.isRecording)
        #expect(button.shortcut.modifierFlags == [.function, .control])
    }

    @Test func detachAndCloseReleaseKeyboardLease() {
        let (window, button) = fixture()
        defer { button.endRecording(); window.close() }
        button.performClick(nil)
        button.removeFromSuperview()
        #expect(!button.isRecording)
        #expect(!ShortcutCaptureCoordinator.isRecording)
        window.contentView?.addSubview(button)
        button.performClick(nil)
        window.close()
        #expect(!button.isRecording)
        #expect(!ShortcutCaptureCoordinator.isRecording)
    }

    @Test func existingGlobalShortcutPassesThroughDuringCapture() {
        let (window, button) = fixture()
        defer { button.endRecording(); window.close() }
        let monitor = KeyMonitor()
        monitor.configure(key: .customShortcut, customShortcut: .default,
                          tapHoldThresholdMs: 1, doublePressWindowMs: 1, holdForgiveMs: 1)
        var started = false
        monitor.onStart = { _ in started = true }
        button.performClick(nil)
        let event = key(window, code: HotkeyShortcut.defaultKeyCode,
                        flags: HotkeyShortcut.defaultModifierFlags, characters: "=")
        #expect(!monitor.handleNSEvent(event))
        window.sendEvent(event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        #expect(!started)
        #expect(!button.isRecording)
    }
}
