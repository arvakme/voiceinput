import SwiftUI

/// Flat stacked cards, one per configurable backend — same shape as every
/// other Settings tab (`GeneralTab`, `AppearanceTab`, …). This used to be a
/// ChatWise-style master-detail view with its own inner sidebar, which meant
/// two different navigation idioms nested inside one Settings window for a
/// grand total of four sections. Not enough content to earn a second nav
/// layer, so it's gone.
struct ProvidersTab: View {
    let refiner: Refiner

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var presetStore: PolishPresetStore

    @State private var voiceOutcome: TestOutcome = .idle
    @State private var polishOutcome: TestOutcome = .idle
    @State private var translateOutcome: TestOutcome = .idle
    @State private var editingPreset: PolishPreset?
    @State private var showingNewPresetSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            voicePane
            polishPane
            translatePane
            liveCaptionsPane
        }
    }

    // MARK: Voice model

    private var voicePane: some View {
        Card {
            CardHeading(
                title: "Voice model",
                subtitle: voicePaneSubtitle
            )
            InlineRow(
                title: "Provider",
                help: "Soniox supports both Realtime streaming and batch transcription; Doubao is realtime-only."
            ) {
                Picker("", selection: $settings.voiceProvider) {
                    ForEach(VoiceProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            // Doubao has no batch session yet, so the Mode picker would let you
            // select a mode that silently falls back to realtime anyway — hide
            // it rather than expose a choice that doesn't do anything.
            if settings.voiceProvider.forcedBackend == nil {
                InlineRow(
                    title: "Mode",
                    help: "Switching during a session takes effect immediately — also available as a chip in the voice box."
                ) {
                    Picker("", selection: $settings.asrBackend) {
                        ForEach(ASRBackend.allCases, id: \.self) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
            Hairline()
            switch settings.voiceProvider {
            case .soniox:
                FieldRow(
                    title: "API key",
                    help: "Soniox API key. Stored in your local preferences."
                ) {
                    SecureFieldRow(placeholder: "soniox-…", text: $settings.sonioxAPIKey)
                }
                if settings.asrBackend == .sonioxRealtime {
                    FieldRow(
                        title: "Realtime model",
                        help: "Soniox streaming model (WebSocket)."
                    ) {
                        ModelPickerField(
                            placeholder: SonioxDefaults.realtimeModel,
                            model: $settings.sonioxModel,
                            kind: .sonioxRealtime
                        )
                    }
                } else {
                    FieldRow(
                        title: "Transcribe model",
                        help: "Soniox async model — upload, poll, fetch transcript."
                    ) {
                        ModelPickerField(
                            placeholder: "stt-async-v5",
                            model: $settings.sonioxAsyncModel,
                            kind: .sonioxAsync
                        )
                    }
                }
            case .doubao:
                FieldRow(
                    title: "API key",
                    help: "Volcengine console → 语音技术 → 豆包语音识别大模型 → API Key（新版控制台的 X-Api-Key）。"
                ) {
                    SecureFieldRow(placeholder: "your-api-key", text: $settings.doubaoAPIKey)
                }
                FieldRow(
                    title: "Resource ID",
                    help: "Which purchased resource pack to bill against. ASR 2.0 (Seed-ASR, recommended): volc.seedasr.sauc.duration. ASR 1.0: volc.bigasr.sauc.duration."
                ) {
                    FilledTextField(placeholder: "volc.seedasr.sauc.duration", text: $settings.doubaoResourceId, monospaced: true)
                }
            }
            Hairline()
            TestButton(title: "Test connection", outcome: voiceOutcome) {
                runVoiceTest()
            }
        }
    }

    private var voicePaneSubtitle: String {
        if settings.voiceProvider == .doubao {
            return "Realtime only: same Seed-ASR model behind 豆包输入法/抖音/剪映, streamed over Volcengine's bidirectional WebSocket."
        }
        return settings.asrBackend == .sonioxRealtime
            ? "Realtime: words stream into the voice box live while you speak."
            : "Just transcribe: records locally, sends once at stop. No live words."
    }

    // MARK: Polish model

    private var polishPane: some View {
        Card {
            CardHeading(
                title: "Polish · OpenRouter",
                subtitle: "Cleans disfluencies, fillers, and punctuation while preserving meaning and language."
            )
            presetRow
            Hairline()
            InlineRow(
                title: "Enable polish",
                help: "Run a cleanup pass on every transcript."
            ) {
                BlueToggle(isOn: $settings.polishEnabled)
            }
            Hairline()
            FieldRow(
                title: "Base URL",
                help: "OpenRouter or any OpenAI-compatible chat-completions endpoint."
            ) {
                FilledTextField(placeholder: "https://openrouter.ai/api/v1", text: $settings.polishBaseURL, monospaced: true)
            }
            FieldRow(
                title: "API key",
                help: "Bearer token for the polish endpoint."
            ) {
                SecureFieldRow(placeholder: "sk-or-v1-…", text: $settings.polishAPIKey)
            }
            FieldRow(
                title: "Model",
                help: "Chat model identifier."
            ) {
                ModelPickerField(
                    placeholder: "openai/gpt-oss-120b:free",
                    model: $settings.polishModel,
                    kind: .chat,
                    baseURL: { settings.polishBaseURL },
                    apiKey: { settings.polishAPIKey }
                )
            }
            InlineRow(
                title: "Reasoning effort",
                help: "For reasoning models (gpt-oss…). OpenRouter gets the nested reasoning object; OpenAI/Cerebras-style endpoints get reasoning_effort. Off sends neither."
            ) {
                Picker("", selection: $settings.polishReasoningEffort) {
                    Text("Off").tag("off")
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }
            Hairline()
            TestButton(title: "Test Polish", outcome: polishOutcome) {
                runPolishTest()
            }
        }
        .sheet(item: $editingPreset) { preset in
            PresetEditorView(preset: preset)
        }
        .sheet(isPresented: $showingNewPresetSheet) {
            PresetEditorView(preset: nil)
        }
    }

    /// Icon + name dropdown selecting which `PolishPreset` drives the next
    /// dictation's polish pass. Its own model/review overrides (if any) live
    /// in the edit sheet, not inline here — the fields below always show the
    /// global Polish defaults that presets fall back to.
    private var presetRow: some View {
        InlineRow(
            title: "Preset",
            help: "Which prompt (and optional model) Polish uses for the next dictation."
        ) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(presetStore.presets) { preset in
                        Button {
                            presetStore.selectedPresetID = preset.id
                        } label: {
                            Label(preset.name, systemImage: preset.icon)
                        }
                    }
                    Divider()
                    Button {
                        showingNewPresetSheet = true
                    } label: {
                        Label("New Preset…", systemImage: "plus")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: presetStore.selected.icon)
                        Text(presetStore.selected.name)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fieldFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    editingPreset = presetStore.selected
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fieldFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Edit this preset")
            }
        }
    }

    // MARK: Translate model

    private var translatePane: some View {
        Card {
            CardHeading(
                title: "Translate · Ollama",
                subtitle: "Optional final translation step into your target language."
            )
            InlineRow(
                title: "Enable translate",
                help: "Translate the (polished) transcript before injecting."
            ) {
                BlueToggle(isOn: $settings.translateEnabled)
            }
            Hairline()
            InlineRow(
                title: "Target language",
                help: "Language the transcript is translated into."
            ) {
                ThemedPicker(selection: $settings.translateTarget, width: 200) {
                    ForEach(TranslateTarget.allCases, id: \.self) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .disabled(!settings.translateEnabled)
            }
            FieldRow(
                title: "Base URL",
                help: "Ollama or any OpenAI-compatible chat-completions endpoint."
            ) {
                FilledTextField(placeholder: "http://127.0.0.1:11434/v1", text: $settings.translateBaseURL, monospaced: true)
            }
            FieldRow(
                title: "API key",
                help: "Bearer token (optional for local Ollama)."
            ) {
                SecureFieldRow(placeholder: "(optional)", text: $settings.translateAPIKey)
            }
            FieldRow(
                title: "Model",
                help: "Translation model identifier."
            ) {
                ModelPickerField(
                    placeholder: "hy-mt2-1.8b-translate:latest",
                    model: $settings.translateModel,
                    kind: .chat,
                    baseURL: { settings.translateBaseURL },
                    apiKey: { settings.translateAPIKey }
                )
            }
            Hairline()
            TestButton(title: "Test Translate", outcome: translateOutcome) {
                runTranslateTest()
            }
        }
    }

    // MARK: Live Captions

    private var liveCaptionsPane: some View {
        Card {
            CardHeading(
                title: "Live Captions",
                subtitle: "Real-time transcription + translation of system audio or the mic. Toggle with Fn+Space; Fn+Shift+Space switches layout."
            )
            InlineRow(
                title: "Engine",
                help: "Soniox streams original + one-way translation. Gemini Live uses Google's speech-translation model."
            ) {
                Picker("", selection: $settings.liveCaptionProvider) {
                    ForEach(LiveCaptionProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            Hairline()
            if settings.liveCaptionProvider == .soniox {
                FieldRow(
                    title: "API key",
                    help: "Uses your Soniox key (shared with the Voice model)."
                ) {
                    SecureFieldRow(placeholder: "soniox-…", text: $settings.sonioxAPIKey)
                }
                Text("Uses the Soniox realtime model from the Voice model page (\(settings.sonioxModel.isEmpty ? SonioxDefaults.realtimeModel : settings.sonioxModel)).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FieldRow(
                    title: "Gemini API key",
                    help: "Google AI Studio key (aistudio.google.com). Preview models may require billing enabled."
                ) {
                    SecureFieldRow(placeholder: "AIza…", text: $settings.geminiAPIKey)
                }
                FieldRow(
                    title: "Model",
                    help: "Translate model (…-live-translate-…) outputs original + translation. A general live model is cheaper for text-only captions."
                ) {
                    FilledTextField(placeholder: "gemini-3.5-live-translate-preview", text: $settings.geminiLiveModel, monospaced: true)
                }
            }
            Hairline()
            InlineRow(
                title: "Default target",
                help: "Translate into this language (also switchable from the captions window)."
            ) {
                Picker("", selection: $settings.listenTargetLanguage) {
                    ForEach(ListenLanguages.all, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
            }
            InlineRow(
                title: "Audio source",
                help: "System audio captions calls/videos (needs Screen Recording permission); microphone captions your own voice."
            ) {
                Picker("", selection: $settings.listenSource) {
                    Text("System audio").tag("system")
                    Text("Microphone").tag("mic")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    // MARK: Tests

    /// Streaming ASR has no request/response round trip the way Polish's
    /// chat-completions call does, so this only proves the WebSocket handshake
    /// and auth are accepted — see `ASRConnectionTester`.
    private func runVoiceTest() {
        voiceOutcome = .running
        let completion: (Result<String, ASRConnectionTester.ConnectionError>) -> Void = { result in
            switch result {
            case .success(let text):  voiceOutcome = .success(text)
            case .failure(let error): voiceOutcome = .failure(error.message)
            }
        }
        switch settings.voiceProvider {
        case .soniox:
            ASRConnectionTester.testSoniox(
                apiKey: settings.sonioxAPIKey,
                model: settings.sonioxModel,
                completion: completion
            )
        case .doubao:
            ASRConnectionTester.testDoubao(
                apiKey: settings.doubaoAPIKey,
                resourceId: settings.doubaoResourceId,
                completion: completion
            )
        }
    }

    private func runPolishTest() {
        polishOutcome = .running
        refiner.testPolish { result in
            switch result {
            case .success(let text):
                polishOutcome = .success(text)
            case .failure(let error):
                polishOutcome = .failure(error.localizedDescription)
            }
        }
    }

    private func runTranslateTest() {
        translateOutcome = .running
        refiner.testTranslate { result in
            switch result {
            case .success(let text):
                translateOutcome = .success(text)
            case .failure(let error):
                translateOutcome = .failure(error.localizedDescription)
            }
        }
    }
}
