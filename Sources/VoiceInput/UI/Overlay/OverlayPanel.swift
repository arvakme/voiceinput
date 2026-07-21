import AppKit
import Combine
import SwiftUI

/// The floating dictation HUD window.
///
/// Owns a borderless, non-activating `NSPanel` that hosts the SwiftUI
/// `GlassVoiceBox`. The panel never becomes key or main, joins all Spaces, and
/// floats above ordinary windows. Positioning, show/dismiss animation, and the
/// Esc-to-cancel monitors live here; everything visible is driven reactively by
/// `AppState`/`AppSettings` from inside the SwiftUI box.
///
/// The panel only *renders* the error phase (red flash + error text). The 2-second
/// error dwell, the `dismiss()` call, and the return to `.idle` are owned by
/// `DictationController` so media-resume and KeyMonitor reset stay sequenced.
final class OverlayPanel {
    /// Fired when the user taps the glass "Stop" capsule.
    var onStop: (() -> Void)?
    /// Fired on the glass "Cancel" capsule or on Esc.
    var onCancel: (() -> Void)?
    /// Fired the first time the user focuses the post-dictation review editor
    /// (see GlassVoiceBox's ReviewEditorView). DictationController cancels the
    /// review's auto-dismiss timer on this signal.
    var onReviewEditStart: (() -> Void)?
    /// Fired by ⌘⏎ or the review editor's Apply button with the (possibly
    /// unedited) review text.
    var onApplyReview: ((String) -> Void)?

    private let state: AppState
    private let settings: AppSettings
    private let hotkeyLabel = HotkeyLabelModel()
    private let resizeController = BoxResizeController()

    /// Drives the SwiftUI show/dismiss scale+fade transition.
    private let presentation = PresentationModel()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayRootView>?

    private var escGlobalMonitor: Any?
    private var escLocalMonitor: Any?
    private var moveObserver: Any?
    private var compactObserver: AnyCancellable?

    /// Suppresses the didMove observer while `positionPanel` places the window
    /// itself, so only user drags persist a custom origin.
    private var isProgrammaticMove = false

    /// Guards against a dismiss animation completion ordering out a panel that
    /// was re-shown in the meantime.
    private var showToken = 0

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
    }

    deinit {
        // Monitors must be torn down off the panel's lifetime. deinit runs on
        // whatever thread releases us; the removals are cheap and thread-safe
        // for NSEvent monitors created on the main thread, but guard anyway.
        if let m = escGlobalMonitor { NSEvent.removeMonitor(m) }
        if let m = escLocalMonitor { NSEvent.removeMonitor(m) }
        if let o = moveObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Public API

    /// Shows the box on the screen containing the mouse pointer, non-activating.
    func show() {
        let panel = ensurePanel()
        positionPanel(panel)

        showToken += 1
        // Start hidden, then animate in via SwiftUI once on screen.
        presentation.isPresented = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Next runloop tick so the hosting view has laid out at the start state
        // before we flip the flag and let the spring run.
        DispatchQueue.main.async { [weak self] in
            self?.presentation.isPresented = true
        }

        startEscMonitors()
    }

    /// Animates the box out and orders the panel off screen.
    func dismiss() {
        guard let panel else { return }
        stopEscMonitors()

        // A resize drag or an edge hover may be live when the session ends —
        // SwiftUI fires neither onEnded nor a mouseExited for a hidden window,
        // so the frame-resize cursor would stick in every app. Reset both.
        resizeController.cancel()
        NSCursor.arrow.set()

        let token = showToken
        presentation.isPresented = false

        // Order out after the SwiftUI dismiss transition (0.25 s) finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self, self.showToken == token else { return }
            panel.orderOut(nil)
        }
    }

    /// Updates the "Stop" badge with the user's current hotkey display name.
    func updateHotkeyLabel(_ display: String) {
        hotkeyLabel.label = display
    }

    /// Whether the panel is allowed to become key. `false` (the default) for
    /// the entire dictation lifecycle — the whole point of `NonActivatingPanel`
    /// is that showing the HUD never steals focus. `DictationController` sets
    /// this `true` only while `AppState.phase == .reviewing`, so a click into
    /// the review editor can make the panel (and only the panel — the
    /// styleMask keeps it `.nonactivatingPanel`, so our app itself never
    /// activates) key, and sets it back to `false` on every exit path.
    var allowsKeyFocus: Bool {
        get { (panel as? NonActivatingPanel)?.allowsKeyFocus ?? false }
        set { (panel as? NonActivatingPanel)?.allowsKeyFocus = newValue }
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let root = OverlayRootView(
            state: state,
            settings: settings,
            hotkeyLabel: hotkeyLabel,
            presentation: presentation,
            resizeController: resizeController,
            onStop: { [weak self] in self?.onStop?() },
            onCancel: { [weak self] in self?.onCancel?() },
            onReviewEditStart: { [weak self] in self?.onReviewEditStart?() },
            onApplyReview: { [weak self] text in self?.onApplyReview?(text) }
        )

        let hosting = FirstMouseHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]

        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        hosting.frame = NSRect(origin: .zero, size: contentSize)
        panel.contentView = hosting

        // Persist the origin whenever the user drags the box so it reappears
        // where they left it (WindowDragGesture in GlassVoiceBox does the move).
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, let frame = self.panel?.frame,
                  !self.isProgrammaticMove,
                  // Left/bottom-edge resizes also move the origin at gesture
                  // rate; BoxResizeController.end() persists the final state.
                  !self.resizeController.isResizing else { return }
            self.settings.voiceBoxOriginX = frame.origin.x
            self.settings.voiceBoxOriginY = frame.origin.y
            self.settings.voiceBoxOriginSaved = true
        }

        self.panel = panel
        self.hostingView = hosting
        resizeController.panel = panel
        resizeController.settings = settings

        // Box ↔ capsule toggles swap the panel to the other form's size,
        // keeping the visual center where the user had it.
        compactObserver = settings.$voiceBoxCompact
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.adoptContentSizeKeepingCenter() }

        return panel
    }

    /// Re-frames the visible panel to the current form's size around the same
    /// center point (used when toggling compact mode mid-session).
    private func adoptContentSizeKeepingCenter() {
        guard let panel, panel.isVisible else { return }
        resizeController.cancel()
        let size = contentSize
        let old = panel.frame
        let frame = NSRect(x: old.midX - size.width / 2,
                           y: old.midY - size.height / 2,
                           width: size.width, height: size.height)
        isProgrammaticMove = true
        // AppKit animates the frame; SwiftUI relayouts each intermediate size,
        // so the glass morphs smoothly without a competing SwiftUI animation.
        let duration = panel.animationResizeTime(frame)
        panel.setFrame(frame, display: true, animate: true)
        // The animation posts didMove on every step — keep the observer
        // suppressed until it settles, then persist the final origin once.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.isProgrammaticMove = false
            self.settings.voiceBoxOriginX = panel.frame.origin.x
            self.settings.voiceBoxOriginY = panel.frame.origin.y
            self.settings.voiceBoxOriginSaved = true
        }
    }

    /// The hosting size: the current form's size plus 40 pt of shadow margin
    /// on every side. The box/capsule fills the canvas minus that margin, so
    /// dragging the panel edges (via BoxResizeController) resizes it like a
    /// window.
    private var contentSize: NSSize {
        if settings.voiceBoxCompact {
            return NSSize(width: settings.capsuleWidth + 80, height: settings.capsuleHeight + 80)
        }
        return NSSize(width: settings.voiceBoxWidth + 80, height: settings.voiceBoxHeight + 80)
    }

    // MARK: - Positioning

    private func positionPanel(_ panel: NSPanel) {
        let size = contentSize
        isProgrammaticMove = true
        defer { isProgrammaticMove = false }

        // A dragged-to origin wins, as long as a meaningful part of the box
        // (not a 1-pt sliver) is still on a connected screen.
        if settings.voiceBoxOriginSaved {
            let saved = NSRect(x: settings.voiceBoxOriginX, y: settings.voiceBoxOriginY,
                               width: size.width, height: size.height)
            let sufficientlyVisible = NSScreen.screens.contains {
                let visible = $0.visibleFrame.intersection(saved)
                return visible.width >= 100 && visible.height >= 50
            }
            if sufficientlyVisible {
                panel.setFrame(saved, display: true)
                return
            }
        }

        let screen = screenContainingMouse()
        let area = screen.visibleFrame

        let x = area.midX - size.width / 2
        // voiceBoxVerticalPosition is a fraction from the bottom; center the box
        // vertically on that line. AppKit screen coords originate bottom-left.
        let fraction = max(0.0, min(1.0, settings.voiceBoxVerticalPosition))
        let centerY = area.minY + area.height * CGFloat(fraction)
        let y = centerY - size.height / 2

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                       display: true)
    }

    private func screenContainingMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    // MARK: - Esc monitors

    private func startEscMonitors() {
        stopEscMonitors()
        // Global: Esc pressed in any other app while the box is up.
        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.onCancel?()
            }
        }
        // Local: Esc pressed while one of our own (non-key) elements has focus.
        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.onCancel?()
                return nil
            }
            return event
        }
    }

    private func stopEscMonitors() {
        if let m = escGlobalMonitor {
            NSEvent.removeMonitor(m)
            escGlobalMonitor = nil
        }
        if let m = escLocalMonitor {
            NSEvent.removeMonitor(m)
            escLocalMonitor = nil
        }
    }
}

// MARK: - Box resizing

/// Which window edges a resize handle drives.
struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left   = ResizeEdges(rawValue: 1 << 0)
    static let right  = ResizeEdges(rawValue: 1 << 1)
    static let top    = ResizeEdges(rawValue: 1 << 2)
    static let bottom = ResizeEdges(rawValue: 1 << 3)
}

/// Window-style resizing for the voice box. The SwiftUI handles in
/// `GlassVoiceBox` report drag begin/move/end; deltas are computed from
/// `NSEvent.mouseLocation` (global screen coordinates) so the math is immune
/// to the view's own frame changing mid-drag. All calls arrive on the main
/// thread (SwiftUI gestures + OverlayPanel wiring).
final class BoxResizeController {
    weak var panel: NSPanel?
    weak var settings: AppSettings?

    private(set) var isResizing = false
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    // Panel-space limits = content limits + the 80 pt shadow canvas,
    // depending on which form is showing.
    private var minSize: NSSize {
        settings?.voiceBoxCompact == true
            ? NSSize(width: 220 + 80, height: 40 + 80)
            : NSSize(width: 480 + 80, height: 170 + 80)
    }
    private var maxSize: NSSize {
        settings?.voiceBoxCompact == true
            ? NSSize(width: 800 + 80, height: 96 + 80)
            : NSSize(width: 1400 + 80, height: 640 + 80)
    }

    func begin() {
        guard let panel else { return }
        startFrame = panel.frame
        startMouse = NSEvent.mouseLocation
        isResizing = true
    }

    func update(edges: ResizeEdges) {
        guard isResizing, let panel else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y

        var f = startFrame
        if edges.contains(.right)  { f.size.width  = startFrame.width + dx }
        if edges.contains(.left)   { f.size.width  = startFrame.width - dx
                                     f.origin.x    = startFrame.origin.x + dx }
        if edges.contains(.top)    { f.size.height = startFrame.height + dy }
        if edges.contains(.bottom) { f.size.height = startFrame.height - dy
                                     f.origin.y    = startFrame.origin.y + dy }

        // Clamp while keeping the anchored (non-dragged) edge stationary.
        let w = min(max(f.size.width, minSize.width), maxSize.width)
        let h = min(max(f.size.height, minSize.height), maxSize.height)
        if edges.contains(.left)   { f.origin.x += f.size.width - w }
        if edges.contains(.bottom) { f.origin.y += f.size.height - h }
        f.size.width = w
        f.size.height = h

        panel.setFrame(f, display: true)
    }

    func end() {
        guard isResizing else { return }
        isResizing = false
        guard let panel, let settings else { return }
        // Persist the current form's dimensions (minus shadow canvas) and the
        // new origin so it reappears exactly as left.
        if settings.voiceBoxCompact {
            settings.capsuleWidth = panel.frame.width - 80
            settings.capsuleHeight = panel.frame.height - 80
        } else {
            settings.voiceBoxWidth = panel.frame.width - 80
            settings.voiceBoxHeight = panel.frame.height - 80
        }
        settings.voiceBoxOriginX = panel.frame.origin.x
        settings.voiceBoxOriginY = panel.frame.origin.y
        settings.voiceBoxOriginSaved = true
    }

    /// Aborts a live resize without persisting (compact toggle or dismiss
    /// mid-drag) and restores the cursor.
    func cancel() {
        guard isResizing else { return }
        isResizing = false
        NSCursor.arrow.set()
    }
}

// MARK: - Non-activating panel subclass

/// An `NSPanel` that refuses key status by default so showing the HUD never
/// steals focus from the app the user is dictating into. `allowsKeyFocus` is
/// the sole, narrow exception: `OverlayPanel.allowsKeyFocus` flips it on only
/// for the post-dictation review editor's lifetime. Even then the panel never
/// becomes MAIN and its styleMask stays `.nonactivatingPanel`, so our app
/// itself is never activated — only the panel takes key status, letting the
/// review `TextEditor` accept keyboard input while focus snaps straight back
/// to the target app the moment the panel orders out.
private final class NonActivatingPanel: NSPanel {
    var allowsKeyFocus = false
    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }
}

/// The panel can never become key, so without this the FIRST click on any
/// control is consumed trying (and failing) to key the window — buttons appear
/// dead. Accepting first mouse delivers that initial mouseDown to SwiftUI.
private final class FirstMouseHostingView: NSHostingView<OverlayRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Presentation model

/// Drives the SwiftUI show/dismiss transition (scale 0.97→1 + fade).
fileprivate final class PresentationModel: ObservableObject {
    @Published var isPresented = false
}

// MARK: - SwiftUI root

/// Wraps `GlassVoiceBox` and applies the panel's appear/disappear animation.
/// Not part of the public contract — internal to the overlay.
fileprivate struct OverlayRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotkeyLabel: HotkeyLabelModel
    @ObservedObject var presentation: PresentationModel
    let resizeController: BoxResizeController

    var onStop: () -> Void
    var onCancel: () -> Void
    var onReviewEditStart: () -> Void
    var onApplyReview: (String) -> Void

    var body: some View {
        GlassVoiceBox(
            state: state,
            settings: settings,
            hotkeyLabel: hotkeyLabel,
            resizeController: resizeController,
            onStop: onStop,
            onCancel: onCancel,
            onReviewEditStart: onReviewEditStart,
            onApplyReview: onApplyReview
        )
        .scaleEffect(presentation.isPresented ? 1 : 0.97)
        .opacity(presentation.isPresented ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: presentation.isPresented)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
