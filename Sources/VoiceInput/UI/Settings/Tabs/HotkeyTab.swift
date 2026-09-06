import AppKit
import SwiftUI

/// Hotkey configuration: which key triggers dictation, an optional custom
/// shortcut recorder, the timing thresholds, and an explainer for the three
/// interaction modes that share the single key.
struct HotkeyTab: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var timingExpanded = false
    @State private var isRecordingShortcut = false

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
                    help: "Click the button, then press a modifier + key, or press and release Fn / a right modifier."
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ShortcutRecorder(
                            keyCode: $settings.customHotkeyKeyCode,
                            modifierFlags: $settings.customHotkeyModifierFlags,
                            keyEquivalent: $settings.customHotkeyKeyEquivalent,
                            triggerKey: $settings.hotkeyKey,
                            isRecording: $isRecordingShortcut
                        )
                        .frame(width: 280, height: 34)
                        Text(isRecordingShortcut
                             ? "Press a shortcut. Esc or click again to cancel (15 s)."
                             : "Click to change. Fn or a right modifier alone also works.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Visible native shortcut recorder

/// The same native control owns layout, hit testing, focus and capture.
/// There is no hidden zero-size view or separate SwiftUI proxy to go stale.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifierFlags: Int
    @Binding var keyEquivalent: String
    @Binding var triggerKey: HotkeyKey
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
        configure(button)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        configure(button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: proposal.height ?? 34)
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.endRecording()
    }

    private func configure(_ button: ShortcutRecorderButton) {
        button.contentTintColor = NSColor(Theme.textPrimary)
        button.shortcut = HotkeyShortcut(
            keyCode: UInt16(clamping: keyCode),
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(max(0, modifierFlags))),
            keyEquivalent: keyEquivalent
        )
        button.onCapture = { shortcut in
            keyCode = Int(shortcut.keyCode)
            modifierFlags = Int(shortcut.modifierFlags.rawValue)
            keyEquivalent = shortcut.keyEquivalent
        }
        button.onModifierCapture = { triggerKey = $0 }
        button.onRecordingChange = { recording in
            if isRecording != recording { isRecording = recording }
        }
    }
}

/// Native button, intentionally internal for event-routing regression tests.
final class ShortcutRecorderButton: NSButton {
    var shortcut: HotkeyShortcut = .default {
        didSet { if !isRecording { title = shortcut.displayString } }
    }
    var onCapture: ((HotkeyShortcut) -> Void)?
    var onModifierCapture: ((HotkeyKey) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false
    var recordingTimeout: TimeInterval = 15

    private var monitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var timeoutTimer: Timer?
    private var modifierCandidate: HotkeyKey?

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
        isBordered = true
        target = self
        action = #selector(toggleRecording)
        title = shortcut.displayString
        toolTip = "Record shortcut; Escape cancels"
        setAccessibilityLabel("Custom dictation shortcut")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func toggleRecording() {
        if isRecording { endRecording() } else { beginRecording() }
    }

    func beginRecording() {
        guard !isRecording, let window, window.makeFirstResponder(self) else { return }
        isRecording = true
        modifierCandidate = nil
        ShortcutCaptureCoordinator.begin(self)
        title = "Press shortcut… (Esc cancels)"
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard event.window === self.window else { return event }
            self.capture(event)
            return nil
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in self?.endRecording() })
        }
        let timer = Timer(timeInterval: recordingTimeout, repeats: false) { [weak self] _ in
            self?.endRecording()
        }
        timeoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func keyDown(with event: NSEvent) {
        if isRecording { capture(event) } else { super.keyDown(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording { capture(event) } else { super.flagsChanged(with: event) }
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func capture(_ event: NSEvent) {
        guard isRecording else { return }
        let modifiers = HotkeyShortcut.normalized(event.modifierFlags)
        if event.type == .flagsChanged {
            if modifiers.isEmpty {
                if let candidate = modifierCandidate {
                    endRecording()
                    onModifierCapture?(candidate)
                }
                return
            }
            let candidate = HotkeyKey.allCases.first {
                ($0 == .fn ? event.keyCode == 63 : $0.rightKeyCode == event.keyCode)
                    && modifiers == $0.modifierFlag
            }
            modifierCandidate = candidate
            title = candidate == nil ? "Add a key to the modifiers…" : "Release to use \(candidate!.displayName)…"
            return
        }
        guard !event.isARepeat else { return }
        if event.keyCode == 53 {
            endRecording()
            return
        }
        modifierCandidate = nil
        guard !modifiers.isEmpty else {
            title = "Use ⌘, ⌥, ⌃, ⇧ or Fn + a key"
            return
        }
        if event.keyCode == 49, modifiers.contains(.function),
           modifiers.intersection([.command, .option, .control]).isEmpty {
            title = "Fn + Space is reserved for captions"
            return
        }
        let captured = HotkeyShortcut(
            keyCode: event.keyCode,
            modifierFlags: modifiers,
            keyEquivalent: HotkeyShortcut.keyName(for: event.keyCode, fallback: event.charactersIgnoringModifiers ?? "")
        )
        shortcut = captured
        endRecording()
        onCapture?(captured)
    }

    func endRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        modifierCandidate = nil
        isRecording = false
        ShortcutCaptureCoordinator.end(self)
        title = shortcut.displayString
        onRecordingChange?(false)
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        timeoutTimer?.invalidate()
        ShortcutCaptureCoordinator.end(self)
    }
}
