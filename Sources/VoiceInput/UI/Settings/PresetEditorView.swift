import SwiftUI

/// Sheet for creating or editing a `PolishPreset`: icon, name, prompt, and
/// optional per-preset model + review-duration overrides. Presented from
/// `ProvidersTab`'s Polish card.
struct PresetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var presetStore: PolishPresetStore

    private let existingID: UUID?
    @State private var name: String
    @State private var icon: String
    @State private var systemPrompt: String
    @State private var modelOverrideEnabled: Bool
    @State private var modelBaseURL: String
    @State private var modelAPIKey: String
    @State private var modelName: String
    @State private var reviewOverrideEnabled: Bool
    @State private var reviewSeconds: Double

    private static let iconChoices = [
        "sun.max", "keyboard", "envelope", "mic", "text.bubble", "bolt", "message", "doc.text",
    ]

    init(preset: PolishPreset?) {
        existingID = preset?.id
        _name = State(initialValue: preset?.name ?? "")
        _icon = State(initialValue: preset?.icon ?? "sparkles")
        _systemPrompt = State(initialValue: preset?.systemPrompt ?? "")
        _modelOverrideEnabled = State(initialValue: preset?.modelOverrideEnabled ?? false)
        _modelBaseURL = State(initialValue: preset?.modelBaseURL ?? "")
        _modelAPIKey = State(initialValue: preset?.modelAPIKey ?? "")
        _modelName = State(initialValue: preset?.modelName ?? "")
        _reviewOverrideEnabled = State(initialValue: preset?.reviewOverrideEnabled ?? false)
        _reviewSeconds = State(initialValue: preset?.reviewSeconds ?? 6.0)
    }

    private var isDeletable: Bool { existingID != nil && existingID != PolishPresetStore.dailyID }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(existingID == nil ? "New Preset" : "Edit Preset")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                FieldRow(title: "Icon") {
                    HStack(spacing: 6) {
                        ForEach(Self.iconChoices, id: \.self) { candidate in
                            Button {
                                icon = candidate
                            } label: {
                                Image(systemName: candidate)
                                    .font(.system(size: 13))
                                    .frame(width: 28, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(icon == candidate ? Theme.pill : Theme.fieldFill)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(icon == candidate ? Theme.accent : Theme.hairline, lineWidth: 1)
                                    )
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                FieldRow(title: "Name") {
                    FilledTextField(placeholder: "Coding", text: $name)
                }

                FieldRow(
                    title: "System Prompt",
                    help: "What Polish does to the transcript while this preset is selected."
                ) {
                    TextEditor(text: $systemPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 180)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fieldFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                        )
                }

                Hairline()

                InlineRow(
                    title: "Use a different model",
                    help: "Off = use the global Polish Base URL / API key / Model."
                ) {
                    BlueToggle(isOn: $modelOverrideEnabled)
                }
                if modelOverrideEnabled {
                    FieldRow(title: "Base URL") {
                        FilledTextField(placeholder: "https://...", text: $modelBaseURL, monospaced: true)
                    }
                    FieldRow(title: "API key") {
                        SecureFieldRow(placeholder: "sk-…", text: $modelAPIKey)
                    }
                    FieldRow(title: "Model") {
                        ModelPickerField(
                            placeholder: "model-id",
                            model: $modelName,
                            kind: .chat,
                            baseURL: { modelBaseURL },
                            apiKey: { modelAPIKey }
                        )
                    }
                }

                Hairline()

                InlineRow(
                    title: "Custom review duration",
                    help: "Off = use the global review duration set in General."
                ) {
                    BlueToggle(isOn: $reviewOverrideEnabled)
                }
                if reviewOverrideEnabled {
                    FieldRow(title: "Review duration") {
                        HStack(spacing: 12) {
                            Slider(value: $reviewSeconds, in: 1...15, step: 0.5)
                                .tint(Theme.accent)
                            Text(String(format: "%.1fs", reviewSeconds))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }

                Hairline()

                HStack {
                    if isDeletable, let existingID {
                        Button("Delete") {
                            presetStore.remove(existingID)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(!canSave)
                }
            }
            .padding(20)
        }
        .frame(width: 480, height: 560)
        .background(Theme.chrome)
    }

    private func save() {
        let preset = PolishPreset(
            id: existingID ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon,
            systemPrompt: systemPrompt,
            modelOverrideEnabled: modelOverrideEnabled,
            modelBaseURL: modelBaseURL,
            modelAPIKey: modelAPIKey,
            modelName: modelName,
            reviewOverrideEnabled: reviewOverrideEnabled,
            reviewSeconds: reviewSeconds
        )
        if existingID != nil {
            presetStore.update(preset)
        } else {
            presetStore.add(preset)
            presetStore.selectedPresetID = preset.id
        }
        dismiss()
    }
}
