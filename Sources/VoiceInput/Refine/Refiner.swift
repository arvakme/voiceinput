import Foundation
import os.log

// MARK: - Refiner

/// Sequential polish→translate chain with never-fail semantics.
/// Any step failure logs and continues with best text so far.
/// 30 s timeout per step. Single 429 retry honoring Retry-After ≤ 5 s.
final class Refiner {

    // MARK: - Init

    private let urlSession: URLSession
    private let settings: AppSettings
    private let vocabulary: VocabularyStore
    private let presets: PolishPresetStore
    private let connections: PolishConnectionStore

    init(settings: AppSettings, vocabulary: VocabularyStore, presets: PolishPresetStore, connections: PolishConnectionStore = .shared, urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.connections = connections
        self.settings = settings
        self.vocabulary = vocabulary
        self.presets = presets
        self.activePreset = presets.selected
    }

    /// Non-nil when the polish step in the most recent `refine()` call fell
    /// back to unpolished text — a network/API failure, not "nothing to
    /// polish" — holding whatever the endpoint said went wrong. Read this
    /// right after `refine()`'s completion fires (main thread, same as the
    /// completion itself) to show the user their text skipped polish rather
    /// than letting the never-fail fallback look silent.
    private(set) var lastPolishedText: String?
    private(set) var lastPolishFailureReason: String?
    var lastPolishFailed: Bool { lastPolishFailureReason != nil }

    /// The preset `refine()` is currently using — captured once per call
    /// (see `refine(_:preset:completion:)`) rather than read live from
    /// `presets.selected`, so switching presets from the voice-box chip
    /// mid-recording can't retroactively change how the transcript already
    /// in flight gets polished.
    private var activePreset: PolishPreset

    // MARK: - Cancellation

    private var cancelled = false
    private var runID = UUID()
    private var accountTask: PolishCancellable?
    private var activeMode: PolishConnection = .api
    private var activeAPIPreset: PolishAPIPreset = .custom
    private var activeAccountModel = ""
    private var activeAccountPath = ""
    private var activeNodePath = ""
    private var activeSDKDirectory = ""
    private var activeCursorModelParams: [CursorModelParameter] = []
    private var activePolishConfig: EndpointConfig?
    private var activeTranslateConfig: EndpointConfig?
    private var activePolishRules = ""
    private var activeTranslationRules = ""
    private var activeEffort = "off"
    private var activeSort = ""
    private var activeSummary = ""

    private func beginRun(preset: PolishPreset? = nil) {
        cancel()
        taskLock.lock()
        cancelled = false
        runID = UUID()
        taskLock.unlock()
        activePreset = preset ?? presets.selected
        lastPolishFailureReason = nil
        lastPolishedText = nil
        activeMode = connections.mode
        activeAPIPreset = connections.apiPreset
        activeAccountModel = connections.model(for: activeMode)
        activeAccountPath = connections.path(for: activeMode)
        activeNodePath = connections.cursorNodePath
        activeSDKDirectory = connections.cursorSDKDirectory
        activeCursorModelParams = connections.cursorModelParams
        activePolishConfig = nil
        activeTranslateConfig = nil
        activePolishConfig = endpointConfig(for: .polish)
        activeTranslateConfig = endpointConfig(for: .translate)
        activePolishRules = buildPolishPrompt()
        activeTranslationRules = buildTranslatePrompt()
        activeEffort = settings.polishReasoningEffort
        activeSort = settings.polishOpenRouterSort
        let provider = activeMode == .api ? (activePreset.modelOverrideEnabled ? "Preset API override" : activeAPIPreset.label) : activeMode.label
        let model = activeMode == .api ? activePolishConfig!.model : activeAccountModel
        activeSummary = "\(activePreset.name) · \(provider) · \(model.isEmpty ? "account default" : model)"
    }

    private func isCurrent(_ id: UUID) -> Bool {
        taskLock.lock(); defer { taskLock.unlock() }
        return !cancelled && runID == id
    }

    private var currentTask: URLSessionDataTask?
    private let taskLock = NSLock()

    func cancel() {
        taskLock.lock()
        cancelled = true
        currentTask?.cancel()
        currentTask = nil
        let account = accountTask
        accountTask = nil
        taskLock.unlock()
        account?.cancel()
    }

    // MARK: - Public API

    /// Runs polish (always — the preset itself decides what that means, from
    /// a light Daily cleanup to a full Coding rewrite) then translate (if
    /// enabled) sequentially. Completion always fires on main thread with
    /// the best available text. Never throws to caller; any step failure is
    /// logged and skipped.
    ///
    /// - Parameter preset: The Polish preset this dictation should use,
    ///   normally captured by the caller at session start (see
    ///   `DictationController.beginSession`). Defaults to whatever is
    ///   currently selected for call sites that don't care about the
    ///   lock-in (e.g. `testPolish`).
    func refine(_ text: String, preset: PolishPreset? = nil, completion: @escaping (String) -> Void) {
        beginRun(preset: preset)

        var steps: [Step] = [.polish]
        if settings.translateEnabled { steps.append(.translate) }

        guard !steps.isEmpty else {
            DispatchQueue.main.async { completion(text) }
            return
        }
        runSteps(steps, currentBest: text, completion: completion)
    }

    /// Test round-trip for "hello there" through the polish endpoint.
    func testPolish(completion: @escaping (Result<String, Error>) -> Void) {
        beginRun()
        runStepReturningResult(.polish, input: "嗯，明天我们我们先测试 VoiceInput，然后再发布，可以吗？", isRetry: false, completion: completion)
    }

    func testTranslate(completion: @escaping (Result<String, Error>) -> Void) {
        beginRun()
        runStepReturningResult(.translate, input: "hello there", isRetry: false, completion: completion)
    }

    // MARK: - Step Enum

    fileprivate enum Step {
        case polish
        case translate
    }

    // MARK: - Sequential Execution

    private func runSteps(_ steps: [Step], currentBest: String, completion: @escaping (String) -> Void) {
        guard let step = steps.first else {
            completion(currentBest)
            return
        }
        let remaining = Array(steps.dropFirst())

        runStepWithFallback(step, input: currentBest) { [weak self] result in
            guard let self else { return }
            self.runSteps(remaining, currentBest: result, completion: completion)
        }
    }

    /// Runs a step; on any error logs and calls back with the original input (never-fail).
    private func runStepWithFallback(_ step: Step, input: String, completion: @escaping (String) -> Void) {
        runStepReturningResult(step, input: input, isRetry: false) { [weak self] result in
            switch result {
            case .success(let text):
                completion(text)
            case .failure(let error):
                // If the failure is a genuine cancellation, halt the pipeline
                // entirely: do NOT call completion, so refine()'s caller never
                // receives a (stale, pre-refine) result after cancel().
                self?.taskLock.lock()
                let wasCancelled = self?.cancelled ?? false
                self?.taskLock.unlock()
                if case RefinerError.cancelled = error, wasCancelled { return }

                if case .polish = step {
                    self?.lastPolishFailureReason = error.localizedDescription
                }
                Log.refine.error("\(step.label) failed, continuing with best text: \(error.localizedDescription, privacy: .private)")
                completion(input)
            }
        }
    }

    // MARK: - Single Step Execution

    private func runStepReturningResult(
        _ step: Step,
        input: String,
        isRetry: Bool,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let id = runID
        runStepRequest(step, input: input, isRetry: isRetry) { [weak self] result in
            guard let self, self.isCurrent(id) else { return }
            if step == .polish {
                switch result {
                case .success(let text):
                    self.lastPolishedText = text
                    self.connections.lastRunSummary = self.activeSummary + " · completed"
                case .failure(let error):
                    self.lastPolishFailureReason = error.localizedDescription
                    self.connections.lastRunSummary = self.activeSummary + " · skipped: " + error.localizedDescription
                }
            }
            completion(result)
        }
    }

    private func runStepRequest(_ step: Step, input: String, isRetry: Bool,
                               completion: @escaping (Result<String, Error>) -> Void) {
        let requestID = runID
        taskLock.lock()
        let isCancelled = cancelled
        taskLock.unlock()

        if isCancelled {
            DispatchQueue.main.async {
                completion(.failure(RefinerError.cancelled))
            }
            return
        }

        if step == .polish, activeMode != .api {
            accountTask = AccountPolishClient.polish(provider: activeMode, model: activeAccountModel,
                executablePath: activeAccountPath, text: input, rules: activePolishRules, completion: completion)
            return
        }
        let config = endpointConfig(for: step)
        if step == .polish, activeAPIPreset == .cursor, !activePreset.modelOverrideEnabled {
            accountTask = CursorPolishClient.polish(model: config.model, apiKey: config.apiKey,
                nodePath: activeNodePath, sdkDirectory: activeSDKDirectory,
                text: input, rules: activePolishRules, modelParams: activeCursorModelParams, completion: completion)
            return
        }


        guard !config.model.isEmpty else {
            DispatchQueue.main.async {
                completion(.failure(RefinerError.missingModel(step.label)))
            }
            return
        }

        let urlString = config.normalizedBaseURL + "/chat/completions"
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            DispatchQueue.main.async {
                completion(.failure(RefinerError.invalidURL(step.label)))
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://github.com/zhijie/voiceinput", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("VoiceInput", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 30

        // Scale with input size so long dictations aren't cut off mid-polish;
        // floor keeps short inputs room to expand, ceiling bounds worst case.
        let maxTokens = min(8192, max(2048, input.count * 2))

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": PolishPrompt.role],
                ["role": "user", "content": PolishPrompt.input(text: input, rules: step == .polish ? activePolishRules : activeTranslationRules)]
            ],
            "temperature": step.temperature,
            "max_tokens": maxTokens,
            "stream": false
        ]

        // Reasoning effort applies to polish only (translate never carries it).
        // Dialect differs by provider: OpenRouter takes a nested object, plain
        // OpenAI-compatible endpoints (OpenAI, Cerebras, …) take a top-level
        // "reasoning_effort" string. "off" sends neither.
        if case .polish = step {
            let effort = activeEffort
            let isOpenRouter = config.baseURL.lowercased().contains("openrouter")
            if effort != "off" {
                if isOpenRouter {
                    body["reasoning"] = ["effort": effort]
                } else {
                    body["reasoning_effort"] = effort
                }
            }

            // OpenRouter-only: which of the (possibly several) providers
            // hosting this open model to prefer. Only meaningful there — a
            // direct Cerebras/OpenAI-style endpoint has exactly one backing
            // provider (itself), nothing to route between.
            let sort = activeSort
            if isOpenRouter, !sort.isEmpty {
                body["provider"] = ["sort": sort]
            }
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            DispatchQueue.main.async {
                completion(.failure(RefinerError.requestSerializationFailed(step.label)))
            }
            return
        }

        Log.refine.debug("\(step.label) → \(urlString) model=\(config.model)")

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            self.taskLock.lock()
            let isCancelled = self.cancelled || self.runID != requestID
            self.taskLock.unlock()

            if isCancelled {
                DispatchQueue.main.async { completion(.failure(RefinerError.cancelled)) }
                return
            }

            if let error = error {
                let nsError = error as NSError
                if nsError.code == NSURLErrorCancelled {
                    DispatchQueue.main.async { completion(.failure(RefinerError.cancelled)) }
                    return
                }
                Log.refine.error("\(step.label) network error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            // Handle 429 with single retry
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
                if isRetry {
                    Log.refine.error("\(step.label) 429 after retry, skipping step")
                    DispatchQueue.main.async {
                        completion(.failure(RefinerError.rateLimited(step.label)))
                    }
                    return
                }

                let retryAfter = self.retryAfterDelay(from: response)
                if let delay = retryAfter, delay <= 5.0 {
                    Log.refine.info("\(step.label) 429, retrying after \(delay)s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        self.taskLock.lock()
                        let stillCancelled = self.cancelled || self.runID != requestID
                        self.taskLock.unlock()
                        if stillCancelled {
                            DispatchQueue.main.async { completion(.failure(RefinerError.cancelled)) }
                            return
                        }
                        self.runStepReturningResult(step, input: input, isRetry: true, completion: completion)
                    }
                } else {
                    Log.refine.error("\(step.label) 429 Retry-After > 5s or missing, skipping step")
                    DispatchQueue.main.async {
                        completion(.failure(RefinerError.rateLimited(step.label)))
                    }
                }
                return
            }

            guard let data = data else {
                Log.refine.error("\(step.label) no data in response")
                DispatchQueue.main.async {
                    completion(.failure(RefinerError.invalidResponse(step.label)))
                }
                return
            }

            // Responses contain the user's rewritten/translated dictation;
            // error bodies can echo the request too. Never log whole bodies.
            Log.refine.debug("\(step.label) response: \(data.count) bytes")

            // A non-2xx status with a body shaped like {"error": {...}} would
            // otherwise fall straight into the `choices` guard below and log
            // as an opaque "failed to parse" — surface the endpoint's own
            // error message instead, so a bad model name, an over-limit
            // max_tokens, or an expired key says so plainly.
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                let apiMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                    .flatMap { $0["error"] as? [String: Any] }
                    .flatMap { $0["message"] as? String }
                let message = apiMessage ?? String(data: data, encoding: .utf8) ?? "no body"
                Log.refine.error("\(step.label) HTTP \(httpResponse.statusCode, privacy: .public): \(message, privacy: .private)")
                DispatchQueue.main.async {
                    completion(.failure(RefinerError.apiError(step.label, httpResponse.statusCode, message)))
                }
                return
            }

            do {
                let refined = try Self.parseCompletion(data, stepLabel: step.label)
                Log.refine.info("\(step.label) completed: \(input.count) → \(refined.count) characters")
                DispatchQueue.main.async { completion(.success(refined)) }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }

        taskLock.lock()
        currentTask = task
        taskLock.unlock()

        task.resume()
    }

    // MARK: - Endpoint Configuration

    private struct EndpointConfig {
        let baseURL: String
        let apiKey: String
        let model: String

        var normalizedBaseURL: String {
            let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
    }

    private func endpointConfig(for step: Step) -> EndpointConfig {
        switch step {
        case .polish:
            if let config = activePolishConfig { return config }
            let preset = activePreset
            guard preset.modelOverrideEnabled else {
                return EndpointConfig(
                    baseURL: settings.polishBaseURL,
                    apiKey: settings.polishAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: settings.polishModel.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return EndpointConfig(
                baseURL: preset.modelBaseURL,
                apiKey: preset.modelAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                model: preset.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .translate:
            if let config = activeTranslateConfig { return config }
            return EndpointConfig(
                baseURL: settings.translateBaseURL,
                apiKey: settings.translateAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                model: settings.translateModel.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // MARK: - Prompt Building

    private func buildSystemPrompt(for step: Step) -> String {
        switch step {
        case .polish:
            return buildPolishPrompt()
        case .translate:
            return buildTranslatePrompt()
        }
    }

    /// The active preset's prompt, plus the vocabulary hint block every
    /// preset gets appended (mishearing corrections matter in Coding
    /// dictation as much as Daily).
    private func buildPolishPrompt() -> String {
        let vocabSection = vocabulary.promptSection
        guard !vocabSection.isEmpty else { return activePreset.systemPrompt }

        return activePreset.systemPrompt + """


            VOCABULARY:
            Use these confirmed spellings only when the surrounding sentence supports the match. Do not force a replacement:
            \(vocabSection)
            """
    }

    private func buildTranslatePrompt() -> String {
        let target = settings.translateTarget
        let targetPhrase: String
        switch target {
        case .english:           targetPhrase = "natural, fluent English"
        case .chineseSimplified: targetPhrase = "natural, fluent Simplified Chinese (简体中文)"
        case .chineseTraditional:targetPhrase = "natural, fluent Traditional Chinese (繁體中文)"
        case .korean:            targetPhrase = "natural, fluent Korean (한국어)"
        }

        return """
            You are a translation engine for a voice-dictation tool.

            TASK:
            - Translate the user's text into \(targetPhrase).
            - The output MUST be written in \(targetPhrase), except for preserved names and technical identifiers.
            - Do not answer, summarize, or explain the user's content.

            PRESERVE VERBATIM:
            - Brand, product, and company names.
            - Technical identifiers: code snippets, API names, file paths, URLs, CLI commands, variables, functions, and flags.
            - Acronyms such as API, URL, LLM, GPU, CPU, HTTP, JSON.

            OUTPUT: Return ONLY the translated text. No explanations, notes, prefaces, framing, or surrounding quotation marks.
            """
    }

    // MARK: - Helpers

    /// Accept only usable, complete text. Throwing here makes the pipeline
    /// retain this step's input, including a successful polish if translation
    /// fails. Passing an empty string onward would lose that best-known text.
    static func parseCompletion(_ data: Data, stepLabel: String) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let choice = choices.first,
            let message = choice["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw RefinerError.invalidResponse(stepLabel) }

        // Some compatible endpoints omit finish_reason. If supplied, only
        // normal completion is safe to insert; filtered/error/tool output
        // may contain just a fragment of the user's transcript.
        if let reason = choice["finish_reason"] as? String, reason != "stop" {
            if reason == "length" { throw RefinerError.truncated(stepLabel) }
            throw RefinerError.incomplete(stepLabel, reason)
        }

        let text = stripWrappingQuotes(content.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { throw RefinerError.emptyResponse(stepLabel) }
        return text
    }

    /// Strips a single layer of wrapping straight or curly quotes plus whitespace.
    private static func stripWrappingQuotes(_ text: String) -> String {
        var s = text
        let quoteChars: [(Character, Character)] = [
            ("\"", "\""),
            ("\u{201C}", "\u{201D}"),  // " "
            ("\u{2018}", "\u{2019}"),  // ' '
            ("'", "'")
        ]
        for (open, close) in quoteChars {
            if s.first == open && s.last == close && s.count >= 2 {
                s = String(s.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return s
    }

    /// Parses the Retry-After header. RFC 7231 allows either a delay in seconds
    /// or an HTTP-date; we honor both, returning the delay in seconds.
    private func retryAfterDelay(from response: URLResponse?) -> Double? {
        guard let http = response as? HTTPURLResponse else { return nil }
        guard let value = (http.value(forHTTPHeaderField: "Retry-After"))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }

        // Form 1: a non-negative number of seconds.
        if let seconds = Double(value) {
            return seconds
        }

        // Form 2: an HTTP-date (e.g. "Wed, 11 Jun 2026 12:00:05 GMT").
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            let delay = date.timeIntervalSinceNow
            return delay > 0 ? delay : nil
        }

        return nil
    }

    // MARK: - Errors

    enum RefinerError: LocalizedError {
        case invalidURL(String)
        case missingModel(String)
        case invalidResponse(String)
        case requestSerializationFailed(String)
        case rateLimited(String)
        case truncated(String)
        case incomplete(String, String)
        case emptyResponse(String)
        /// A non-2xx HTTP response the endpoint itself explained — a bad
        /// model name, an over-limit `max_tokens`, an expired key, etc.
        /// Distinct from `.invalidResponse`, which means the response
        /// couldn't even be understood well enough to say why it failed.
        case apiError(String, Int, String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidURL(let step):                   return "\(step): invalid API base URL"
            case .missingModel(let step):                 return "\(step): model name is empty"
            case .invalidResponse(let step):              return "\(step): invalid response from LLM API"
            case .requestSerializationFailed(let step):   return "\(step): failed to serialize request"
            case .rateLimited(let step):                  return "\(step): rate limited (429)"
            case .truncated(let step):                    return "\(step): response truncated (finish_reason=length)"
            case .incomplete(let step, let reason):       return "\(step): incomplete response (finish_reason=\(reason))"
            case .emptyResponse(let step):               return "\(step): API returned empty text"
            case .apiError(let step, let status, let message): return "\(step): HTTP \(status) — \(message)"
            case .cancelled:                              return "Refiner cancelled"
            }
        }
    }
}

// MARK: - Step helpers

private extension Refiner.Step {
    var label: String {
        switch self {
        case .polish:    return "Polish"
        case .translate: return "Translate"
        }
    }

    var temperature: Double {
        switch self {
        case .polish:    return 0.3
        case .translate: return 0.1
        }
    }
}
