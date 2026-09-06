import AppKit
import ApplicationServices
import os.log

/// Global Fn+Space hotkey toggling Live Captions.
///
/// A dedicated CGEventTap (separate from KeyMonitor's dictation state machine):
/// keyDown with the secondary-Fn flag and the Space keycode fires the callback
/// and swallows the event so a space character never reaches the focused app.
/// NSEvent global monitor is the no-Accessibility fallback (cannot swallow).
final class ListenHotkey {
    /// Fn+Space — toggle Live Captions on/off.
    var onToggle: (() -> Void)?
    /// Fn+Shift+Space — flip layout (two-column ↔ caption bar).
    var onToggleMode: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    /// True once we've fallen back to the NSEvent global monitor because the
    /// event tap couldn't be created (no Accessibility yet).
    private var usingFallback = false

    private static let spaceKeyCode: Int64 = 49

    func start() {
        stop()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ListenHotkey>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard !ShortcutCaptureCoordinator.isRecording,
                  type == .keyDown,
                  event.getIntegerValueField(.keyboardEventKeycode) == ListenHotkey.spaceKeyCode,
                  event.flags.contains(.maskSecondaryFn),
                  // Fn(+Shift)+Space only — don't hijack ⌘/⌥/⌃ combos.
                  !event.flags.contains(.maskCommand),
                  !event.flags.contains(.maskAlternate),
                  !event.flags.contains(.maskControl)
            else { return Unmanaged.passUnretained(event) }

            if event.flags.contains(.maskShift) {
                DispatchQueue.main.async {
                    guard !ShortcutCaptureCoordinator.isRecording else { return }
                    monitor.onToggleMode?()
                }
            } else {
                DispatchQueue.main.async {
                    guard !ShortcutCaptureCoordinator.isRecording else { return }
                    monitor.onToggle?()
                }
            }
            return nil   // swallow
        }

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            usingFallback = false
            Log.keys.info("ListenHotkey tap installed (Fn+Space)")
        } else {
            // Accessibility not granted (yet): observe-only fallback.
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard !ShortcutCaptureCoordinator.isRecording,
                      event.keyCode == UInt16(ListenHotkey.spaceKeyCode),
                      event.modifierFlags.contains(.function),
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                else { return }
                if event.modifierFlags.contains(.shift) {
                    self?.onToggleMode?()
                } else {
                    self?.onToggle?()
                }
            }
            usingFallback = true
            Log.keys.warning("ListenHotkey using NSEvent fallback (no event tap)")
        }

        // While on the fallback, re-attempt the event tap whenever the app
        // becomes active — covers the user granting Accessibility in System
        // Settings and switching back without having to relaunch. Installed
        // once and left in place across start()/stop() cycles.
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.retryEventTapIfNowTrusted()
            }
        }
    }

    /// Called on app activation; upgrades from the NSEvent fallback to the
    /// event tap once Accessibility has actually become trusted.
    private func retryEventTapIfNowTrusted() {
        guard usingFallback, AXIsProcessTrusted() else { return }
        Log.keys.info("ListenHotkey: Accessibility now trusted — retrying event tap")
        start()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
}
