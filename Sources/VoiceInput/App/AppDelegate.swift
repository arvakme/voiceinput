import AppKit
import Combine
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Core singletons

    private let settings = AppSettings.shared
    private let appState = AppState.shared

    // MARK: - Subsystems

    private let keyMonitor = KeyMonitor()
    private let textInjector = TextInjector()
    private let mediaController = MediaController()

    private lazy var overlayPanel: OverlayPanel = {
        OverlayPanel(state: appState, settings: settings)
    }()

    private lazy var refiner: Refiner = {
        Refiner(settings: settings, vocabulary: VocabularyStore.shared)
    }()

    private lazy var dictationController: DictationController = {
        let dc = DictationController(
            settings: settings,
            appState: appState,
            refiner: refiner,
            textInjector: textInjector,
            mediaController: mediaController,
            overlayPanel: overlayPanel
        )
        // Wire external-stop and cancel callbacks to KeyMonitor state machine.
        dc.onSessionEndedExternally = { [weak self] in
            self?.keyMonitor.externalStop()
        }
        dc.onSessionCancelled = { [weak self] in
            self?.keyMonitor.reset()
        }
        return dc
    }()

    // MARK: - Live Captions

    private lazy var listenController = ListenController(settings: settings)
    private let listenHotkey = ListenHotkey()

    // MARK: - Status item

    private var statusItem: NSStatusItem?
    private var enableMenuItem: NSMenuItem?
    private var correctionsMenuItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    // Debounce timer for hotkey rewire.
    private var rewireWorkItem: DispatchWorkItem?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force accessory policy (no Dock icon).
        NSApp.setActivationPolicy(.accessory)

        // An accessory app has no menu bar, but ⌘C/⌘V/⌘X/⌘A in our windows'
        // text fields are dispatched through Edit-menu key equivalents — with
        // no main menu they all go dead. Install a minimal one.
        buildMainMenu()

        // Apply the saved appearance preference before any windows exist so the
        // very first window (settings/history/overlay) inherits the right look.
        AppearanceManager.shared.start()

        buildStatusItem()
        requestPermissionsOnLaunch()
        wireKeyMonitor()
        observeSettings()

        // Live Captions hotkey (Fn+Space toggle, Fn+Shift+Space layout).
        listenHotkey.onToggle = { [weak self] in
            self?.listenController.toggle()
        }
        listenHotkey.onToggleMode = { [weak self] in
            self?.listenController.toggleMode()
        }
        listenHotkey.start()

        // Set initial hotkey label on the overlay.
        dictationController.updateHotkeyLabel(settings.hotkeyDisplayName)

        // Refresh the Rime vocabulary import a couple seconds after launch —
        // late enough that Squirrel's own sync isn't racing our own startup.
        if settings.rimeImportEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                VocabularyStore.shared.refreshFromRime()
            }
        }

        // Listen for preview-overlay notification from the Appearance settings tab.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreviewOverlayNotification(_:)),
            name: Notification.Name("VoiceInputPreviewOverlay"),
            object: nil
        )

        Log.app.info("VoiceInput launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running after settings window closes — hotkey must remain active.
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if dictationController.isSessionActive {
            dictationController.cancelSession()
        }
        dictationController.resolvePendingReviewForTermination()
        HistoryStore.shared.waitForPendingWrites(timeout: 2)
        // Blocking wrapper used ONLY here: applicationWillTerminate has no way
        // to keep the process alive for the normal async resume, so quitting
        // mid-dictation could leave Spotify/Music paused forever otherwise.
        mediaController.resumeIfPausedAndWait(timeout: 2)
    }

    // MARK: - Preview overlay notification

    @objc private func handlePreviewOverlayNotification(_ notification: Notification) {
        dictationController.showPreviewOverlay()
    }

    // MARK: - Main menu (Edit shortcuts)

    /// Minimal main menu so standard editing key equivalents reach text fields
    /// in the settings/history windows. Never visible (accessory app), but the
    /// key-equivalent dispatch requires it to exist.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit VoiceInput",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status item construction

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        updateStatusIcon(for: appState.phase)

        // The icon mirrors the dictation state: quiet template mic when idle,
        // a tinted filled mic while the voice box is live, a waveform while
        // the transcript is being refined.
        appState.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.updateStatusIcon(for: phase) }
            .store(in: &cancellables)

        buildStatusMenu(for: item)
    }

    private func updateStatusIcon(for phase: DictationPhase) {
        guard let button = statusItem?.button else { return }

        let symbol: String
        let tint: NSColor?
        switch phase {
        case .idle:
            symbol = "mic"
            tint = nil
        case .connecting:
            symbol = "mic.badge.ellipsis"
            tint = nil
        case .listening:
            symbol = "mic.fill"
            tint = .systemRed
        case .finalizing:
            symbol = "mic.fill"
            tint = .systemYellow
        case .refining, .injecting:
            symbol = "waveform"
            tint = .controlAccentColor
        case .reviewing:
            symbol = "pencil.circle"
            tint = .controlAccentColor
        case .error:
            symbol = "mic.slash"
            tint = .systemRed
        }

        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceInput")
        if let tint {
            // Tinted = full-colour image; template = adapts to menu bar.
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
    }

    private func buildStatusMenu(for item: NSStatusItem) {

        let menu = NSMenu()
        menu.delegate = self

        // Status line (disabled, just informational).
        let statusLine = NSMenuItem(title: "VoiceInput", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        // This-week correction-rate line (disabled; refreshed in
        // menuNeedsUpdate every time the menu opens).
        let correctionsItem = NSMenuItem(title: Self.weekStatsLabel(), action: nil, keyEquivalent: "")
        correctionsItem.isEnabled = false
        menu.addItem(correctionsItem)
        correctionsMenuItem = correctionsItem

        menu.addItem(NSMenuItem.separator())

        // Enable / Disable toggle.
        let enableItem = NSMenuItem(
            title: settings.appEnabled ? "Disable VoiceInput" : "Enable VoiceInput",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enableItem.target = self
        menu.addItem(enableItem)
        enableMenuItem = enableItem

        menu.addItem(NSMenuItem.separator())

        // Settings…
        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        // History…
        let historyItem = NSMenuItem(
            title: "History\u{2026}",
            action: #selector(openHistory),
            keyEquivalent: "y"
        )
        historyItem.target = self
        menu.addItem(historyItem)

        // Live Captions (Fn+Space toggle, Fn+Shift+Space switches layout)
        let listenItem = NSMenuItem(
            title: "Live Captions (Fn Space)",
            action: #selector(toggleLiveCaptions),
            keyEquivalent: ""
        )
        listenItem.target = self
        menu.addItem(listenItem)

        let listenModeItem = NSMenuItem(
            title: "Switch Captions Layout (Fn ⇧ Space)",
            action: #selector(toggleLiveCaptionsMode),
            keyEquivalent: ""
        )
        listenModeItem.target = self
        menu.addItem(listenModeItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit VoiceInput",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        item.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        correctionsMenuItem?.title = Self.weekStatsLabel()
    }

    /// "This week: 3/25 corrected (12%)" — `injected` (sessions whose text
    /// actually reached the target app) is the denominator; a "before"-mode
    /// review the user declined to insert never counts toward either side.
    /// "This week: no dictations" when nothing resolved in the trailing 7 days.
    private static func weekStatsLabel() -> String {
        let stats = SessionStatsStore.shared.weekStats()
        guard stats.injected > 0 else { return "This week: no dictations" }
        let percent = Int((Double(stats.corrected) / Double(stats.injected) * 100).rounded())
        return "This week: \(stats.corrected)/\(stats.injected) corrected (\(percent)%)"
    }

    @objc private func toggleEnabled() {
        settings.appEnabled.toggle()
    }

    @objc private func toggleLiveCaptions() {
        listenController.toggle()
    }

    @objc private func toggleLiveCaptionsMode() {
        listenController.toggleMode()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openHistory() {
        HistoryWindowController.shared.show()
    }

    // MARK: - Permissions on launch

    private func requestPermissionsOnLaunch() {
        // Microphone: request access so macOS shows the permission dialog.
        PermissionStatus.shared.grantMicrophone()

        // Accessibility: prompt user if not already trusted.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        PermissionStatus.shared.refresh()
    }

    // MARK: - KeyMonitor wiring

    private func wireKeyMonitor() {
        keyMonitor.stop()

        guard settings.appEnabled else { return }

        let customShortcut = (settings.hotkeyKey == .customShortcut)
            ? settings.hotkeyShortcut
            : nil

        keyMonitor.configure(
            key: settings.hotkeyKey,
            customShortcut: customShortcut,
            tapHoldThresholdMs: settings.tapHoldThresholdMs,
            doublePressWindowMs: settings.doublePressWindowMs,
            holdForgiveMs: settings.holdForgiveMs
        )

        keyMonitor.onStart = { [weak self] kind in
            self?.dictationController.beginSession(kind: kind)
        }
        keyMonitor.onStop = { [weak self] in
            self?.dictationController.endSession()
        }

        keyMonitor.start()
    }

    // MARK: - Settings observation

    private func observeSettings() {
        // Enable/disable toggle — rewire or tear down KeyMonitor.
        settings.$appEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.enableMenuItem?.title = enabled ? "Disable VoiceInput" : "Enable VoiceInput"
                if enabled {
                    self.wireKeyMonitor()
                } else {
                    self.keyMonitor.stop()
                    self.dictationController.cancelSession()
                }
            }
            .store(in: &cancellables)

        // Hotkey-related settings — debounce rewire at 300 ms.
        let hotkeyPublisher = settings.$hotkeyKey
            .combineLatest(
                settings.$customHotkeyKeyCode,
                settings.$customHotkeyModifierFlags,
                settings.$customHotkeyKeyEquivalent
            )
            .map { _ in () }

        let timingPublisher = settings.$tapHoldThresholdMs
            .combineLatest(
                settings.$doublePressWindowMs,
                settings.$holdForgiveMs
            )
            .map { _ in () }

        hotkeyPublisher
            .merge(with: timingPublisher)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.scheduleHotkeyRewire()
            }
            .store(in: &cancellables)
    }

    private func scheduleHotkeyRewire() {
        rewireWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wireKeyMonitor()
            self.dictationController.updateHotkeyLabel(self.settings.hotkeyDisplayName)
        }
        rewireWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
