import SwiftUI

/// General settings: master enable toggle, language hints, and media auto-pause.
struct GeneralTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                InlineRow(
                    title: "Enable voice input",
                    help: "Master switch for the global hotkey and dictation."
                ) {
                    BlueToggle(isOn: $settings.appEnabled)
                }

                Hairline()

                FieldRow(
                    title: "Language hints",
                    help: "ISO codes, e.g. zh,en — passed to Soniox as language_hints."
                ) {
                    FilledTextField(
                        placeholder: "zh,en",
                        text: $settings.languageHints,
                        monospaced: true
                    )
                }

                Hairline()

                InlineRow(
                    title: "Pause media while dictating",
                    help: "Spotify and Apple Music are paused precisely via AppleScript. All other players (browsers, IINA, NetEase, etc.) are paused via the system Play/Pause key."
                ) {
                    BlueToggle(isOn: $settings.mediaAutoPause)
                }

                Hairline()

                InlineRow(
                    title: "Post-dictation review",
                    help: "Shows the injected text for a few seconds so you can fix mishearings in place. Your edits also teach the vocabulary system."
                ) {
                    BlueToggle(isOn: $settings.reviewEnabled)
                }
            }
        }
    }
}
