import Cocoa

// MARK: - HotkeyKey

enum HotkeyKey: String, CaseIterable, Identifiable {
    case fn
    case rightCommand
    case rightOption
    case rightShift
    case rightControl
    case customShortcut

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn:             return "Fn"
        case .rightCommand:   return "Right ⌘"
        case .rightOption:    return "Right ⌥"
        case .rightShift:     return "Right ⇧"
        case .rightControl:   return "Right ⌃"
        case .customShortcut: return "Custom Shortcut"
        }
    }

    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .fn:             return .function
        case .rightCommand:   return .command
        case .rightOption:    return .option
        case .rightShift:     return .shift
        case .rightControl:   return .control
        case .customShortcut: return []
        }
    }

    var rightKeyCode: UInt16? {
        switch self {
        case .fn:             return nil
        case .rightCommand:   return 54
        case .rightOption:    return 61
        case .rightShift:     return 60
        case .rightControl:   return 62
        case .customShortcut: return nil
        }
    }

    /// Device-specific bit in NSEvent.modifierFlags.rawValue — lets us tell
    /// right-modifier state apart even while the left counterpart is held.
    var rightDeviceMask: UInt? {
        switch self {
        case .fn:             return nil
        case .rightCommand:   return 0x00000010
        case .rightOption:    return 0x00000040
        case .rightShift:     return 0x00000004
        case .rightControl:   return 0x00002000
        case .customShortcut: return nil
        }
    }
}

// MARK: - HotkeyShortcut

struct HotkeyShortcut: Equatable {
    static let defaultKeyCode: UInt16 = 24 // ANSI =
    static let defaultKeyEquivalent = "="
    static let defaultModifierFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var keyCode: UInt16
    var modifierFlags: NSEvent.ModifierFlags
    var keyEquivalent: String

    static var `default`: HotkeyShortcut {
        HotkeyShortcut(
            keyCode: defaultKeyCode,
            modifierFlags: defaultModifierFlags,
            keyEquivalent: defaultKeyEquivalent
        )
    }

    var displayString: String {
        "\(Self.modifierSymbols(for: modifierFlags))\(Self.keyName(for: keyCode, fallback: keyEquivalent))"
    }

    func matches(eventFlags: NSEvent.ModifierFlags) -> Bool {
        let normalized = Self.normalized(eventFlags)
        return modifierFlags.isSubset(of: normalized)
    }

    func matches(cgFlags: CGEventFlags) -> Bool {
        if modifierFlags.contains(.command),  !cgFlags.contains(.maskCommand)    { return false }
        if modifierFlags.contains(.option),   !cgFlags.contains(.maskAlternate)  { return false }
        if modifierFlags.contains(.control),  !cgFlags.contains(.maskControl)    { return false }
        if modifierFlags.contains(.shift),    !cgFlags.contains(.maskShift)      { return false }
        if modifierFlags.contains(.function), !cgFlags.contains(.maskSecondaryFn){ return false }
        return true
    }

    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.command)  { result.insert(.command) }
        if flags.contains(.option)   { result.insert(.option) }
        if flags.contains(.control)  { result.insert(.control) }
        if flags.contains(.shift)    { result.insert(.shift) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }

    static func modifierSymbols(for flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command)  { parts.append("⌘") }
        if flags.contains(.option)   { parts.append("⌥") }
        if flags.contains(.control)  { parts.append("⌃") }
        if flags.contains(.shift)    { parts.append("⇧") }
        if flags.contains(.function) { parts.append("Fn") }
        return parts.joined()
    }

    /// Prefers the keyCode-based table over the modifier-transformed
    /// character — see the identical fix in `ShortcutRecorderButton` for why
    /// (Control/Option can turn `fallback` into a control character rather
    /// than the letter that was actually pressed).
    static func keyName(for keyCode: UInt16, fallback: String) -> String {
        if let known = knownKeyNames[keyCode] { return known }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPrintable = !trimmed.isEmpty && trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        return isPrintable ? trimmed.uppercased() : "#\(keyCode)"
    }

    private static let knownKeyNames: [UInt16: String] = [
        0: "A",   1: "S",   2: "D",   3: "F",   4: "H",   5: "G",   6: "Z",   7: "X",
        8: "C",   9: "V",  11: "B",  12: "Q",  13: "W",  14: "E",  15: "R",
       16: "Y",  17: "T",  18: "1",  19: "2",  20: "3",  21: "4",  22: "6",
       23: "5",  24: "=",  25: "9",  26: "7",  27: "-",  28: "8",  29: "0",
       30: "]",  31: "O",  32: "U",  33: "[",  34: "I",  35: "P",  37: "L",
       38: "J",  39: "'",  40: "K",  41: ";",  42: "\\", 43: ",",  44: "/",
       45: "N",  46: "M",  47: ".",  48: "Tab",49: "Space", 51: "Delete",
       53: "Esc",76: "Enter",96: "F5",97: "F6",98: "F7",99: "F3",
      100: "F8",101: "F9",103: "F11",109: "F10",111: "F12",
      118: "F4",122: "F1",120: "F2",
      123: "←",124: "→",125: "↓",126: "↑"
    ]
}

// MARK: - KeyMonitor

/// Unified hotkey monitor. All three interaction shapes (hold / tap-toggle /
/// double-tap hands-free) live on the same physical key; the state machine
/// disambiguates based on press duration and timing.
///
/// Disambiguation:
/// - A press that exceeds `tapHoldThresholdMs` is a HOLD; release ends it
///   (with a `holdForgiveMs` tolerance for a brief slip).
/// - A press that releases before the threshold is a TAP. If no second tap
///   arrives within `doublePressWindowMs`, it's a TOGGLE (start/stop on tap).
///   A second tap within the window upgrades it to HANDS-FREE (auto-stop on
///   silence, or tap to stop early).
final class KeyMonitor {
    var onStart: ((SessionKind) -> Void)?
    var onStop:  (() -> Void)?

    private var key: HotkeyKey = .fn
    private var customShortcut: HotkeyShortcut = .default
    private var tapHoldThresholdMs: Int = 200
    private var doublePressWindowMs: Int = 350
    private var holdForgiveMs: Int = 300

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var state: State = .idle
    private var keyDown = false
    private var pressedAt: Date?

    private var tapHoldTimer: DispatchWorkItem?
    private var doubleTapTimer: DispatchWorkItem?
    private var forgiveTimer: DispatchWorkItem?

    private enum State {
        case idle
        case holdOrTapPending           // first keyDown, waiting to see hold vs tap
        case waitingSecondTap           // first tap done, waiting for a possible 2nd
        case holdOrTapPendingSecond     // 2nd keyDown arrived within double-press window
        case holdRecording
        case holdReleasePending         // release scheduled, within forgive window
        case toggleRecording
        case handsFreeRecording
    }

    // MARK: - Configuration

    /// Apply new hotkey settings. Takes effect on the next `start()` call (the
    /// running tap/monitors are not replaced until then). The state-machine
    /// parameters (thresholds) apply immediately so in-flight timers use the
    /// new values — consistent with the old app.
    func configure(
        key: HotkeyKey,
        customShortcut: HotkeyShortcut?,
        tapHoldThresholdMs: Int,
        doublePressWindowMs: Int,
        holdForgiveMs: Int
    ) {
        self.key = key
        self.customShortcut = customShortcut ?? .default
        self.tapHoldThresholdMs = tapHoldThresholdMs
        self.doublePressWindowMs = doublePressWindowMs
        self.holdForgiveMs = holdForgiveMs
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        let tapOK     = (key == .fn || key == .customShortcut) ? startEventTap() : false
        let monitorOK = startGlobalMonitor()
        Log.keys.info("KeyMonitor start key=\(self.key.rawValue) shortcut=\(self.customShortcut.displayString) tap=\(tapOK) monitor=\(monitorOK)")
    }

    func stop() {
        cancelAllTimers()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        eventTap = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        state   = .idle
        keyDown = false
        pressedAt = nil
    }

    /// Silently abort — state is torn down but `onStop` is NOT fired.
    /// Call on cancel / Enabled-off; unconditional full state reset, no callbacks.
    func reset() {
        cancelAllTimers()
        state   = .idle
        keyDown = false
        pressedAt = nil
    }

    /// Tear down internal state-machine WITHOUT firing onStop. The controller
    /// MUST call this after it ends a session by any path other than a user
    /// hotkey tap (hands-free silence auto-stop, overlay Stop button, Esc cancel)
    /// — otherwise KeyMonitor still believes a session is active and the next tap
    /// is misread as "stop" instead of "start".
    ///
    /// Safe no-op when the state machine is already idle.
    func externalStop() {
        switch state {
        case .handsFreeRecording, .toggleRecording, .holdRecording, .holdReleasePending:
            cancelAllTimers()
            state     = .idle
            keyDown   = false
            pressedAt = nil   // match stop()/reset() so no stale press timestamp lingers
        default:
            break
        }
    }

    // MARK: - Event-tap

    private func startEventTap() -> Bool {
        var mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        if key == .customShortcut {
            mask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
            mask |= CGEventMask(1 << CGEventType.keyUp.rawValue)
        } else if key == .fn {
            // Watch keyDown too so we can tell "Fn held to talk" apart from
            // "Fn held as a system modifier" (Fn+Space, Fn+arrow, ...) — see
            // handleCGEvent.
            mask |= CGEventMask(1 << CGEventType.keyDown.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleCGEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable if the system disabled our tap.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.keys.warning("CGEventTap re-enabled after tapDisabled event")
            return Unmanaged.passRetained(event)
        }

        if key == .customShortcut {
            return handleCustomCGEvent(type: type, event: event)
        }

        if key == .fn, type == .keyDown {
            // Any other key going down while we're tracking Fn as held means
            // the user is using Fn as a system modifier (Fn+Space, Fn+arrow, …),
            // not talking to us. Never swallow it — just untrack our hold.
            DispatchQueue.main.async { [weak self] in self?.onForeignKeyDownWhileFnHeld() }
            return Unmanaged.passRetained(event)
        }

        // Fn path — suppress the key so the OS doesn't show the emoji picker.
        let down = event.flags.contains(.maskSecondaryFn)
        if down && !keyDown {
            keyDown = true
            DispatchQueue.main.async { [weak self] in self?.onKeyDownEdge() }
            return nil
        }
        if !down && keyDown {
            keyDown = false
            DispatchQueue.main.async { [weak self] in self?.onKeyUpEdge() }
            return nil
        }
        return Unmanaged.passRetained(event)
    }

    private func handleCustomCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            guard eventKeyCode == customShortcut.keyCode,
                  customShortcut.matches(cgFlags: event.flags)
            else { return Unmanaged.passRetained(event) }
            if !keyDown {
                keyDown = true
                DispatchQueue.main.async { [weak self] in self?.onKeyDownEdge() }
            }
            return nil

        case .keyUp:
            guard eventKeyCode == customShortcut.keyCode else {
                return Unmanaged.passRetained(event)
            }
            if keyDown {
                keyDown = false
                DispatchQueue.main.async { [weak self] in self?.onKeyUpEdge() }
                return nil
            }
            return Unmanaged.passRetained(event)

        case .flagsChanged:
            if keyDown, !customShortcut.matches(cgFlags: event.flags) {
                keyDown = false
                DispatchQueue.main.async { [weak self] in self?.onKeyUpEdge() }
            }
            return Unmanaged.passRetained(event)

        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - NSEvent global + local monitors (fallback)

    private func startGlobalMonitor() -> Bool {
        let mask: NSEvent.EventTypeMask = key == .customShortcut
            ? [.flagsChanged, .keyDown, .keyUp]
            : .flagsChanged

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if self?.handleNSEvent(event) == true { return nil }
            return event
        }
        return globalMonitor != nil
    }

    @discardableResult
    private func handleNSEvent(_ event: NSEvent) -> Bool {
        if key == .customShortcut {
            return handleCustomNSEvent(event)
        }

        let flags    = event.modifierFlags
        let modifier = key.modifierFlag
        let down: Bool

        if let rightCode = key.rightKeyCode, let rightMask = key.rightDeviceMask {
            guard event.keyCode == rightCode else { return false }
            down = (UInt(flags.rawValue) & rightMask) != 0
        } else {
            down = flags.contains(modifier)
        }

        if down && !keyDown {
            keyDown = true
            onKeyDownEdge()
        } else if !down && keyDown {
            keyDown = false
            onKeyUpEdge()
        }
        return false
    }

    private func handleCustomNSEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            guard event.keyCode == customShortcut.keyCode,
                  customShortcut.matches(eventFlags: event.modifierFlags)
            else { return false }
            if !keyDown {
                keyDown = true
                onKeyDownEdge()
            }
            return true

        case .keyUp:
            guard event.keyCode == customShortcut.keyCode else { return false }
            if keyDown {
                keyDown = false
                onKeyUpEdge()
                return true
            }
            return false

        case .flagsChanged:
            if keyDown, !customShortcut.matches(eventFlags: event.modifierFlags) {
                keyDown = false
                onKeyUpEdge()
            }
            return false

        default:
            return false
        }
    }

    // MARK: - State machine

    private func onKeyDownEdge() {
        switch state {
        case .idle:
            pressedAt = Date()
            state = .holdOrTapPending
            scheduleTapHoldTimer()

        case .waitingSecondTap:
            // Second press within the double-press window — wait to see if it's a
            // quick tap (double-tap → hands-free) or the user is holding.
            cancelDoubleTapTimer()
            pressedAt = Date()
            state = .holdOrTapPendingSecond
            scheduleTapHoldTimer()

        case .holdReleasePending:
            // Brief release — user is still holding.
            cancelForgiveTimer()
            state = .holdRecording

        case .toggleRecording:
            // Tap during an active toggle session → stop.
            state = .idle
            onStop?()

        case .handsFreeRecording:
            // Tap during hands-free → early stop.
            state = .idle
            onStop?()

        case .holdOrTapPending, .holdOrTapPendingSecond, .holdRecording:
            // Already tracking a press — shouldn't happen since we only
            // flip keyDown on actual edges. Ignore defensively.
            break
        }
    }

    private func onKeyUpEdge() {
        switch state {
        case .holdOrTapPending:
            // Released before tap/hold threshold → it's a TAP. Wait for a
            // possible second tap to upgrade to hands-free.
            cancelTapHoldTimer()
            state = .waitingSecondTap
            scheduleDoubleTapTimer()

        case .holdOrTapPendingSecond:
            // Second press released within the threshold → confirmed double-tap.
            cancelTapHoldTimer()
            state = .handsFreeRecording
            onStart?(.handsFree)

        case .holdRecording:
            // Release in hold mode — schedule the end-of-hold inside the
            // forgiveness window.
            state = .holdReleasePending
            scheduleForgiveTimer()

        case .idle, .waitingSecondTap, .holdReleasePending,
             .toggleRecording, .handsFreeRecording:
            break
        }
    }

    /// Fn-only: a keyDown for some other key arrived while we were still
    /// deciding hold-vs-tap, waiting on a possible second tap, or already in a
    /// hold recording. That combination (Fn + another key) means the physical
    /// Fn press was never meant as our hotkey — reset so the eventual Fn keyUp
    /// isn't misread, cancelling the hold session if one already started.
    /// Toggle/hands-free sessions are left alone: by then the interaction has
    /// already committed and the user may legitimately type while dictating.
    private func onForeignKeyDownWhileFnHeld() {
        switch state {
        case .holdOrTapPending, .waitingSecondTap:
            cancelAllTimers()
            state = .idle
            pressedAt = nil
        case .holdRecording:
            cancelAllTimers()
            state = .idle
            pressedAt = nil
            onStop?()
        default:
            break
        }
    }

    // MARK: - Timers

    private func scheduleTapHoldTimer() {
        cancelTapHoldTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.state {
            case .holdOrTapPending, .holdOrTapPendingSecond:
                // Held past the threshold → hold session.
                self.state = .holdRecording
                self.onStart?(.hold)
            default:
                break
            }
        }
        tapHoldTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(tapHoldThresholdMs), execute: work)
    }

    private func cancelTapHoldTimer() {
        tapHoldTimer?.cancel()
        tapHoldTimer = nil
    }

    private func scheduleDoubleTapTimer() {
        cancelDoubleTapTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Window elapsed without a second tap — commit to TOGGLE.
            if case .waitingSecondTap = self.state {
                self.state = .toggleRecording
                self.onStart?(.toggle)
            }
        }
        doubleTapTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(doublePressWindowMs), execute: work)
    }

    private func cancelDoubleTapTimer() {
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
    }

    private func scheduleForgiveTimer() {
        cancelForgiveTimer()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .holdReleasePending = self.state {
                self.state = .idle
                self.onStop?()
            }
        }
        forgiveTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(holdForgiveMs), execute: work)
    }

    private func cancelForgiveTimer() {
        forgiveTimer?.cancel()
        forgiveTimer = nil
    }

    private func cancelAllTimers() {
        cancelTapHoldTimer()
        cancelDoubleTapTimer()
        cancelForgiveTimer()
    }
}
