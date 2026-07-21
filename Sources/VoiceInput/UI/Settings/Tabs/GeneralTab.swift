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
                    help: "Before insert: see the text and let it auto-insert, or fix it first. After insert: fix a mishearing in place once it's already landed. Edits also teach the vocabulary system."
                ) {
                    ThemedPicker(selection: $settings.reviewMode, width: 190) {
                        ForEach(ReviewMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                if settings.reviewMode != .off {
                    Hairline()

                    FieldRow(
                        title: "Review duration",
                        help: "\"Before insert\": auto-insert countdown. \"After insert\": how long the box stays up."
                    ) {
                        HStack(spacing: 12) {
                            Slider(value: $settings.reviewSeconds, in: 1...15, step: 0.5)
                                .tint(Theme.accent)
                            Text(String(format: "%.1fs", settings.reviewSeconds))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}
