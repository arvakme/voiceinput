import AppKit
import Carbon

/// Injects transcribed text into the focused application using clipboard +
/// synthetic Cmd-V. Handles non-ASCII IME sources (e.g. Chinese Pinyin) by
/// briefly switching to an ASCII-capable layout before pasting, then restoring
/// the original source after 300 ms — matching the old app's proven timing.
///
/// The transcribed text is intentionally left on the clipboard as a fallback:
/// if Accessibility is not granted the Cmd-V simulation is a no-op, but the
/// user can still manually paste.
final class TextInjector {

    /// The app that was frontmost the last time `inject()` ran — captured so
    /// `replaceLastInjection` knows which app to re-activate before undoing
    /// the prior paste, even if focus moved elsewhere (e.g. to our own
    /// review overlay) in the meantime.
    private(set) var lastTarget: NSRunningApplication?

    func inject(_ text: String) {
        guard !text.isEmpty else { return }

        lastTarget = NSWorkspace.shared.frontmostApplication

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // If a non-ASCII input source (e.g. Chinese IME) is active, temporarily
        // switch to an ASCII keyboard layout so Cmd-V is not intercepted by
        // the IME — but ONLY if such a layout actually exists. On layouts-free
        // setups (Squirrel-only) we deliberately don't switch: IMEs pass
        // command-modified keys through, so Cmd-V pastes fine anyway.
        let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let asciiSource = isASCIICapable(originalSource) ? nil : findASCIICapableSource()

        if let asciiSource {
            TISSelectInputSource(asciiSource)
            usleep(50_000) // 50 ms for system to settle
        }

        // Synthesise Cmd+V (requires Accessibility permission).
        postCommandKey(0x09)

        Log.keys.info("TextInjector: injected \(text.count) chars switchedLayout=\(asciiSource != nil)")

        // Restore input source after paste.
        if asciiSource != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                TISSelectInputSource(originalSource)
            }
        }
    }

    /// Replaces the previously injected text with `corrected` from the
    /// post-dictation review box: re-activates `lastTarget` if it isn't
    /// already frontmost, undoes the prior paste with a synthetic Cmd-Z, then
    /// runs the normal inject path with the corrected text.
    ///
    /// Best-effort by design: this assumes the target app treats a pasted
    /// string as one undoable step (true for most native text fields/editors).
    /// Apps that don't implement undo for a paste (some web text areas,
    /// terminals) will just get the correction pasted in after a harmless
    /// no-op Cmd-Z — there is no reliable cross-app way to detect or select
    /// the previously-injected range, so we don't attempt anything more
    /// precise than undo-then-re-paste.
    func replaceLastInjection(with corrected: String) {
        guard !corrected.isEmpty else { return }

        if let lastTarget, !lastTarget.isActive {
            _ = lastTarget.activate()
        }

        // Give the target app's focus time to settle after (re)activating
        // before we post keystrokes at it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.postCommandKey(0x06) // Cmd-Z
            Log.keys.info("TextInjector: posted undo before replacement")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                self.inject(corrected)
            }
        }
    }

    // MARK: - Key posting

    /// Posts a synthetic Cmd+`keyCode` key-down/key-up pair (requires
    /// Accessibility permission). Shared by `inject`'s Cmd-V and
    /// `replaceLastInjection`'s Cmd-Z.
    private func postCommandKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - Input-source helpers

    private func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return false
        }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    /// A real, user-selectable ASCII keyboard LAYOUT (ABC/US preferred), or
    /// nil when the user has none enabled. The type + select-capable filters
    /// are load-bearing: the plain ASCII-capable+enabled list can lead with
    /// palette pseudo-sources (com.apple.CharacterPaletteIM — the system
    /// emoji picker), and TISSelectInputSource on one of those OPENS that
    /// palette as a floating window.
    private func findASCIICapableSource() -> TISInputSource? {
        let criteria = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any,
            kTISPropertyInputSourceIsASCIICapable: true,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true
        ] as CFDictionary
        guard let sourceList = TISCreateInputSourceList(criteria, false)?
            .takeRetainedValue() as? [TISInputSource]
        else { return nil }

        for source in sourceList {
            if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                if id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" {
                    return source
                }
            }
        }
        return sourceList.first
    }
}
