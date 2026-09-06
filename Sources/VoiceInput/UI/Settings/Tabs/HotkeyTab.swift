import AppKit
import SwiftUI

/// Hotkey configuration: which key triggers dictation, an optional custom
/// shortcut recorder, the timing thresholds, and an explainer for the three
/// interaction modes that share the single key.
struct HotkeyTab: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var timingExpanded = false
    @State private var isRecordingShortcut = false
    @State private var recorderProxy = ShortcutRecorderProxy()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            keyCard
            timingCard
            explainerCard
        }
    }

    // MARK: Key selection

    private var keyCard: some View {
        Card {
            InlineRow(
                title: "Trigger key",
                help: "Hold to talk, tap to toggle, double-tap for hands-free."
            ) {
                ThemedPicker(selection: $settings.hotkeyKey, width: 200) {
                    ForEach(HotkeyKey.allCases, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
            }

            if settings.hotkeyKey == .customShortcut {
                Hairline()
                FieldRow(
                    title: "Custom shortcut",
                    help: "Click the field, then press the key combination you want (needs at least one modifier)."
                ) {
                    ZStack(alignment: .leading) {
                        // Zero-size — exists only to host the NSEvent
                        // capture (becoming first responder doesn't need a
                        // visible frame). The click target below is a plain
                        // SwiftUI Button instead of an overlaid AppKit
                        // button, so its hit area is guaranteed to match
                        // exactly what's drawn: no risk of the two
                        // disagreeing the way an invisible NSButton sized
                        // independently of its SwiftUI overlay can.
                        ShortcutRecorder(
                            keyCode: $settings.customHotkeyKeyCode,
                            modifierFlags: $settings.customHotkeyModifierFlags,
                            keyEquivalent: $settings.customHotkeyKeyEquivalent,
                            isRecording: $isRecordingShortcut,
                            proxy: recorderProxy
                        )
                        .frame(width: 0, height: 0)

                        Button {
                            recorderProxy.beginRecording()
                        } label: {
                            KeycapRowView(
                                shortcut: HotkeyShortcut(
                                    keyCode: UInt16(max(0, min(settings.customHotkeyKeyCode, Int(UInt16.max)))),
                                    modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(max(0, settings.customHotkeyModifierFlags))),
                                    keyEquivalent: settings.customHotkeyKeyEquivalent
                                ),
                                isRecording: isRecordingShortcut
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                }
            } else if settings.hotkeyKey != .fn {
                Hairline()
                Text("Non-Fn keys are not suppressed — they keep their normal behavior while held.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Timing

    private var timingCard: some View {
        Card {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { timingExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(timingExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Timing")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Fine-tune how presses are interpreted.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if timingExpanded {
                Hairline()
                timingStepper(
                    title: "Tap / hold threshold",
                    help: "Press longer than this → hold-to-talk. Shorter → tap.",
                    value: $settings.tapHoldThresholdMs,
                    range: 100...500, step: 25
                )
                timingStepper(
                    title: "Double-tap window",
                    help: "Maximum gap between the two taps of a double-tap.",
                    value: $settings.doublePressWindowMs,
                    range: 150...800, step: 25
                )
                timingStepper(
                    title: "Hold release tolerance",
                    help: "A brief release shorter than this does not end the recording.",
                    value: $settings.holdForgiveMs,
                    range: 0...1000, step: 50
                )
                timingStepper(
                    title: "Hands-free silence timeout",
                    help: "How long of a silence ends a hands-free session.",
                    value: $settings.silenceDurationMs,
                    range: 500...5000, step: 100
                )
            }
        }
    }

    private func timingStepper(
        title: String,
        help: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        InlineRow(title: title, help: help) {
            HStack(spacing: 10) {
                Text("\(value.wrappedValue) ms")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 64, alignment: .trailing)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    // MARK: Explainer

    private var explainerCard: some View {
        Card {
            CardHeading(title: "Three modes, one key")
            modeRow(symbol: "hand.tap",
                    title: "Hold",
                    detail: "Press and hold to talk; release to finish.")
            modeRow(symbol: "togglepower",
                    title: "Toggle",
                    detail: "Tap once to start, tap again to stop.")
            modeRow(symbol: "ear",
                    title: "Hands-free",
                    detail: "Double-tap to start; stops automatically on silence.")
        }
    }

    private func modeRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

// MARK: - Shortcut recorder (ported from old app's ShortcutRecorderNSButton)

/// Lets the SwiftUI `Button` that's the actual click target reach the
/// AppKit capture view without SwiftUI's `NSViewRepresentable.Coordinator`
/// (private to the representable's own lifecycle) getting in the way.
final class ShortcutRecorderProxy {
    fileprivate weak var button: ShortcutRecorderButton?
    func beginRecording() { button?.beginRecording() }
}

/// SwiftUI wrapper around an AppKit view that records a key combination.
/// Zero-sized in practice (see `HotkeyTab.keyCard`) — recording starts via
/// `proxy.beginRecording()` from a normal SwiftUI button, not a click on
/// this view itself.
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifierFlags: Int
    @Binding var keyEquivalent: String
    @Binding var isRecording: Bool
    let proxy: ShortcutRecorderProxy

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(frame: .zero)
        button.isBordered = false
        proxy.button = button
        configure(button)
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        configure(nsView)
    }

    private func configure(_ button: ShortcutRecorderButton) {
        button.shortcut = HotkeyShortcut(
            keyCode: UInt16(max(0, min(keyCode, Int(UInt16.max)))),
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(max(0, modifierFlags))),
            keyEquivalent: keyEquivalent
        )
        button.onCapture = { shortcut in
            keyCode = Int(shortcut.keyCode)
            modifierFlags = Int(shortcut.modifierFlags.rawValue)
            keyEquivalent = shortcut.keyEquivalent
        }
        button.onRecordingChange = { recording in
            if isRecording != recording { isRecording = recording }
        }
    }
}

/// AppKit button that captures a modifier+key combination. Click to arm, then
/// press the desired shortcut; Esc cancels, and at least one modifier is
/// required. Ported from the old app's `ShortcutRecorderNSButton`, adapted to
/// the SPEC `HotkeyShortcut` type (`displayString`).
private final class ShortcutRecorderButton: NSButton {
    var shortcut = HotkeyShortcut(
        keyCode: 24,
        modifierFlags: [.command, .option, .control, .shift],
        keyEquivalent: "="
    ) {
        didSet { if !isRecording { title = shortcut.displayString } }
    }
    var onCapture: ((HotkeyShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var monitor: Any?
    private var windowCloseObserver: NSObjectProtocol?
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        bezelStyle = .rounded
        controlSize = .regular
        target = self
        action = #selector(beginRecording)
        title = shortcut.displayString
    }

    override var acceptsFirstResponder: Bool { true }

    @objc func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        onRecordingChange?(true)
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.capture(event)
            return nil
        }
        // The Settings window is reused (never deallocated), so if it's closed
        // mid-recording nothing would otherwise stop this local monitor from
        // swallowing every keyDown in the app forever. End recording when it closes.
        if let window {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.endRecording()
            }
        }
    }

    // Only the local monitor started in `beginRecording` should feed keys
    // into `capture` — without this guard, this override fires for ANY
    // keyDown reaching the button as first responder (e.g. the window still
    // had it focused from an earlier click), silently overwriting the
    // stored shortcut with whatever the user typed next.
    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { endRecording() }
        return super.resignFirstResponder()
    }

    private func capture(_ event: NSEvent) {
        guard !event.isARepeat else { return }

        // Esc cancels recording without changing the stored shortcut.
        if event.keyCode == 53 {
            endRecording()
            return
        }

        let modifiers = ShortcutRecorderButton.normalized(event.modifierFlags)
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return
        }

        let fallback = event.charactersIgnoringModifiers ?? ""
        let keyName = ShortcutRecorderButton.keyName(for: event.keyCode, fallback: fallback)
        let captured = HotkeyShortcut(
            keyCode: event.keyCode,
            modifierFlags: modifiers,
            keyEquivalent: keyName
        )
        shortcut = captured
        onCapture?(captured)
        endRecording()
    }

    /// Idempotent — safe to call repeatedly (e.g. both windowWillClose and a
    /// later resignFirstResponder for the same recording session).
    private func endRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        isRecording = false
        onRecordingChange?(false)
        title = shortcut.displayString
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
    }

    // MARK: Key helpers (inlined so the recorder is self-contained)

    private static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }

    /// Prefers the keyCode-based table over the modifier-transformed
    /// character: holding Control (or Option, for some keys) turns
    /// `charactersIgnoringModifiers` into a control character or an
    /// unrelated glyph — e.g. Ctrl+L reports as a form-feed, not "L" — which
    /// used to get stored and displayed as literal mojibake. The table gives
    /// the physical key's real name regardless of what modifiers did to it.
    private static func keyName(for keyCode: UInt16, fallback: String) -> String {
        if let known = knownKeyNames[keyCode] { return known }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPrintable = !trimmed.isEmpty && trimmed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        return isPrintable ? trimmed.uppercased() : "#\(keyCode)"
    }

    private static let knownKeyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 51: "Delete",
        53: "Esc", 76: "Enter", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
        118: "F4", 122: "F1", 120: "F2"
    ]
}

// MARK: - Keycap row (Raycast-style shortcut display)

/// Purely visual: renders `shortcut` as a row of individual keycap chips
/// instead of one button with a concatenated symbol+letter string. Sits on
/// top of the (visually hidden) `ShortcutRecorder` button, which still does
/// the actual key capture.
private struct KeycapRowView: View {
    let shortcut: HotkeyShortcut
    let isRecording: Bool

    private var keys: [String] {
        guard !isRecording else { return ["press…"] }
        var parts: [String] = []
        if shortcut.modifierFlags.contains(.function) { parts.append("fn") }
        if shortcut.modifierFlags.contains(.control)  { parts.append("⌃") }
        if shortcut.modifierFlags.contains(.option)   { parts.append("⌥") }
        if shortcut.modifierFlags.contains(.shift)    { parts.append("⇧") }
        if shortcut.modifierFlags.contains(.command)  { parts.append("⌘") }
        parts.append(HotkeyShortcut.keyName(for: shortcut.keyCode, fallback: shortcut.keyEquivalent))
        return parts
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRecording ? Theme.accent : Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.contentBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isRecording ? Theme.accent : Theme.hairline, lineWidth: 1)
                    )
            }
        }
        .opacity(isRecording ? 0.55 : 1)
        .animation(
            isRecording ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
            value: isRecording
        )
    }
}
