import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted every time the History window is brought forward (both fresh
    /// creation and reopen). `HistoryView`'s stats header refreshes from this
    /// instead of `.onAppear` — the hosting view is never re-created (see
    /// `isReleasedWhenClosed` below), so SwiftUI's `.onAppear` only fires once.
    static let historyWindowDidShow = Notification.Name("com.zhijie.VoiceInput.historyWindowDidShow")
}

/// Owns the single History window. Mirrors the Settings window idiom: hidden
/// title (a "History" header is drawn in-content), transparent titlebar,
/// full-size content, `Theme.chrome` background. Created lazily and reused.
final class HistoryWindowController {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    private init() {}

    /// Creates (or reuses) the History window and brings it forward, activating
    /// the app — works even with an `.accessory` activation policy.
    func show() {
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // The hosting view is never re-created (isReleasedWhenClosed = false),
        // so SwiftUI's `.onAppear` won't fire again on reopen — refresh here
        // instead, one of `audioDiskUsageBytes`'s two update triggers.
        HistoryStore.shared.refreshAudioDiskUsage()
        NotificationCenter.default.post(name: .historyWindowDidShow, object: nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.setFrameAutosaveName("VoiceInputHistoryWindow")
        window.backgroundColor = .clear

        let root = HistoryView()
            .environmentObject(HistoryStore.shared)
            .environmentObject(AppSettings.shared)

        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hosting

        if window.frame.size.width < 760 || window.frame.size.height < 520 {
            window.setContentSize(NSSize(width: 880, height: 600))
        }
        window.center()

        // The hosting view never disappears (isReleasedWhenClosed = false
        // above), so SwiftUI's `.onDisappear` inside HistoryView never fires
        // on close — stop playback from the window's own lifecycle instead.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            AudioPlayer.shared.stop()
        }

        return window
    }
}
