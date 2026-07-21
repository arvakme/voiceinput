import SwiftUI

/// ChatWise-style master-detail provider configuration. A narrow source list
/// names each backend with a configured/unconfigured status dot; the detail
/// pane shows only that provider's fields.
struct ProvidersTab: View {
    let refiner: Refiner

    @EnvironmentObject private var settings: AppSettings

    @State private var selection: ProviderItem = .voice
    @State private var polishOutcome: TestOutcome = .idle
    @State private var translateOutcome: TestOutcome = .idle

    enum ProviderItem: String, CaseIterable, Identifiable {
        case voice
        case polish
        case translate
        case liveCaptions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .voice:        return "Voice model"
            case .polish:       return "Polish model"
            case .translate:    return "Translate model"
            case .liveCaptions: return "Live Captions"
            }
        }

        var symbol: String {
            switch self {
            case .voice:        return "waveform"
            case .polish:       return "sparkles"
            case .translate:    return "globe"
            case .liveCaptions: return "captions.bubble"
            }
        }
    }

    /// User-adjustable source-list width, persisted across launches.
    @AppStorage("providersSidebarWidth") private var sidebarWidth: Double = 170

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sourceList
            SplitDragHandle(width: $sidebarWidth, range: 140...320)
            detail
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Source list

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ProviderItem.allCases) { item in
                SourceListRow(
                    symbol: item.symbol,
                    title: item.title,
                    configured: isConfigured(item),
                    isSelected: selection == item
                ) {
                    selection = item
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: max(140, sidebarWidth), alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.sidebarBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    private func isConfigured(_ item: ProviderItem) -> Bool {
        switch item {
        case .voice:
            switch settings.voiceProvider {
            case .soniox: return !settings.sonioxAPIKey.trimmed.isEmpty
            case .openai: return !settings.httpASRAPIKey.trimmed.isEmpty
            case .qwen:   return !settings.qwenAPIKey.trimmed.isEmpty
            }
        case .polish:
            return !settings.polishBaseURL.trimmed.isEmpty && !settings.polishModel.trimmed.isEmpty
        case .translate:
            return !settings.translateBaseURL.trimmed.isEmpty && !settings.translateModel.trimmed.isEmpty
        case .liveCaptions:
            switch settings.liveCaptionProvider {
            case .soniox: return !settings.sonioxAPIKey.trimmed.isEmpty
            case .gemini: return !settings.geminiAPIKey.trimmed.isEmpty
            }
        }
    }

    // MARK: Detail panes

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .voice:        voicePane
        case .polish:       polishPane
        case .translate:    translatePane
        case .liveCaptions: liveCaptionsPane
        }
    }

    private var voicePane: some View {
        Card {
            CardHeading(
                title: "Voice model",
                subtitle: voicePaneSubtitle
            )
            InlineRow(
                title: "Provider",
                help: "Soniox and OpenAI support realtime streaming and batch transcription; Qwen is batch-only (\"Just transcribe\")."
            ) {
                Picker("", selection: $settings.voiceProvider) {
                    ForEach(VoiceProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            // Qwen has no realtime session yet, so the Mode picker (and the
            // voice-box chip that mirrors it) would be misleading — hide it
            // rather than let it select a mode that silently falls back.
            if settings.voiceProvider != .qwen {
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
            case .openai:
                FieldRow(
                    title: "API key",
                    help: "OpenAI API key (used for both realtime and batch)."
                ) {
                    SecureFieldRow(placeholder: "sk-…", text: $settings.httpASRAPIKey)
                }
                if settings.asrBackend == .sonioxRealtime {
                    FieldRow(
                        title: "Realtime model",
                        help: "Streams over wss://api.openai.com/v1/realtime (intent=transcription)."
                    ) {
                        ModelPickerField(
                            placeholder: "gpt-4o-mini-transcribe",
                            model: $settings.openAIRealtimeModel,
                            kind: .openAIRealtime
                        )
                    }
                } else {
                    FieldRow(
                        title: "Base URL",
                        help: "api.openai.com or any OpenAI-compatible server."
                    ) {
                        FilledTextField(placeholder: "https://api.openai.com/v1", text: $settings.httpASRBaseURL, monospaced: true)
                    }
                    FieldRow(
                        title: "Transcribe model",
                        help: "Posted to /audio/transcriptions as one WAV."
                    ) {
                        ModelPickerField(
                            placeholder: "gpt-4o-mini-transcribe",
                            model: $settings.httpASRModel,
                            kind: .transcription,
                            baseURL: { settings.httpASRBaseURL },
                            apiKey: { settings.httpASRAPIKey }
                        )
                    }
                }
            case .qwen:
                FieldRow(
                    title: "Base URL",
                    help: "DashScope's OpenAI-compatible gateway. ASR is a chat-completions request with the audio embedded, not /audio/transcriptions."
                ) {
                    FilledTextField(placeholder: "https://dashscope.aliyuncs.com/compatible-mode/v1", text: $settings.qwenBaseURL, monospaced: true)
                }
                FieldRow(
                    title: "API key",
                    help: "DashScope API key. Stored in your local preferences."
                ) {
                    SecureFieldRow(placeholder: "sk-…", text: $settings.qwenAPIKey)
                }
                FieldRow(
                    title: "Model",
                    help: "Qwen3-ASR model identifier."
                ) {
                    ModelPickerField(
                        placeholder: "qwen3-asr-flash",
                        model: $settings.qwenModel,
                        kind: .chat,
                        baseURL: { settings.qwenBaseURL },
                        apiKey: { settings.qwenAPIKey }
                    )
                }
            }
        }
    }

    private var voicePaneSubtitle: String {
        if settings.voiceProvider == .qwen {
            return "Just transcribe only: records locally, sends once at stop as a single chat-completions request with the audio embedded."
        }
        return settings.asrBackend == .sonioxRealtime
            ? "Realtime: words stream into the voice box live while you speak."
            : "Just transcribe: records locally, sends once at stop. No live words."
    }

    private var polishPane: some View {
        Card {
            CardHeading(
                title: "Polish · OpenRouter",
                subtitle: "Cleans disfluencies, fillers, and punctuation while preserving meaning and language."
            )
            ollamaGLMPresetRow
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
    }

    // One-click preset: local Ollama serving GLM-5.2 via its cloud relay.
    // reasoning_effort is "off" — the endpoint measured 2.2s round-trip
    // without the top-level reasoning field, so there's nothing to send.
    private static let ollamaGLMBaseURL = "http://localhost:11434/v1"
    private static let ollamaGLMModel = "glm-5.2:cloud"

    private var ollamaGLMPresetActive: Bool {
        settings.polishBaseURL == Self.ollamaGLMBaseURL
            && settings.polishModel == Self.ollamaGLMModel
            && settings.polishAPIKey.isEmpty
            && settings.polishReasoningEffort == "off"
    }

    private func applyOllamaGLMPreset() {
        settings.polishBaseURL = Self.ollamaGLMBaseURL
        settings.polishModel = Self.ollamaGLMModel
        settings.polishAPIKey = ""
        settings.polishReasoningEffort = "off"
    }

    private var ollamaGLMPresetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: applyOllamaGLMPreset) {
                HStack(spacing: 5) {
                    if ollamaGLMPresetActive {
                        Image(systemName: "checkmark")
                    }
                    Text(ollamaGLMPresetActive ? "Using Ollama · GLM-5.2 Cloud" : "Use Ollama · GLM-5.2 Cloud")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(ollamaGLMPresetActive)
            Text("Local Ollama relay — no key, no rate limits.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
