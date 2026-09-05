import Foundation
import os.log

// MARK: - Refiner

/// Sequential polish→translate chain with never-fail semantics.
/// Any step failure logs and continues with best text so far.
/// 30 s timeout per step. Single 429 retry honoring Retry-After ≤ 5 s.
final class Refiner {

    // MARK: - Init

    private let settings: AppSettings
    private let vocabulary: VocabularyStore
    private let presets: PolishPresetStore

    init(settings: AppSettings, vocabulary: VocabularyStore, presets: PolishPresetStore) {
        self.settings = settings
        self.vocabulary = vocabulary
        self.presets = presets
    }

    /// Whether the polish step in the most recent `refine()` call fell back
    /// to unpolished text — a network/API failure, not "nothing to polish".
    /// Read this right after `refine()`'s completion fires (main thread,
    /// same as the completion itself) to show the user their text skipped
    /// polish rather than letting the never-fail fallback look silent.
    private(set) var lastPolishFailed = false

    // MARK: - Cancellation

    private var cancelled = false
    private var currentTask: URLSessionDataTask?
    private let taskLock = NSLock()

    func cancel() {
        taskLock.lock()
        cancelled = true
        currentTask?.cancel()
        currentTask = nil
        taskLock.unlock()
    }

    // MARK: - Public API

    /// Runs polish (if enabled) then translate (if enabled) sequentially.
    /// Completion always fires on main thread with the best available text.
    /// Never throws to caller; any step failure is logged and skipped.
    func refine(_ text: String, completion: @escaping (String) -> Void) {
        taskLock.lock()
        cancelled = false
        taskLock.unlock()
        lastPolishFailed = false

        var steps: [Step] = []
        if settings.polishEnabled    { steps.append(.polish) }
        if settings.translateEnabled { steps.append(.translate) }

        guard !steps.isEmpty else {
            DispatchQueue.main.async { completion(text) }
            return
        }
        runSteps(steps, currentBest: text, completion: completion)
    }

    /// Test round-trip for "hello there" through the polish endpoint.
    func testPolish(completion: @escaping (Result<String, Error>) -> Void) {
        taskLock.lock()
        cancelled = false
        taskLock.unlock()
        runStepReturningResult(.polish, input: "hello there", isRetry: false, completion: completion)
    }

    /// Test round-trip for "hello there" through the translate endpoint.
    func testTranslate(completion: @escaping (Result<String, Error>) -> Void) {
        taskLock.lock()
        cancelled = false
        taskLock.unlock()
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
            DispatchQueue.main.async { completion(currentBest) }
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

                if case .polish = step { self?.lastPolishFailed = true }
                Log.refine.error("\(step.label) failed, continuing with best text: \(error.localizedDescription)")
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
        taskLock.lock()
        let isCancelled = cancelled
        taskLock.unlock()

        if isCancelled {
            DispatchQueue.main.async {
                completion(.failure(RefinerError.cancelled))
            }
            return
        }

        let config = endpointConfig(for: step)

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
                ["role": "system", "content": buildSystemPrompt(for: step)],
                ["role": "user",   "content": input]
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
            let effort = settings.polishReasoningEffort
            if effort != "off" {
                if config.baseURL.lowercased().contains("openrouter") {
                    body["reasoning"] = ["effort": effort]
                } else {
                    body["reasoning_effort"] = effort
                }
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

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            self.taskLock.lock()
            let isCancelled = self.cancelled
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
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        self.taskLock.lock()
                        let stillCancelled = self.cancelled
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

            if let raw = String(data: data, encoding: .utf8) {
                Log.refine.debug("\(step.label) raw response: \(raw)")
            }

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let choice = choices.first,
                let message = choice["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                Log.refine.error("\(step.label) failed to parse choices[0].message.content")
                DispatchQueue.main.async {
                    completion(.failure(RefinerError.invalidResponse(step.label)))
                }
                return
            }

            // A length-truncated response is worse than no response: injecting
            // half a sentence silently is a correctness bug, not just an ugly one.
            if choice["finish_reason"] as? String == "length" {
                Log.refine.error("\(step.label) response truncated at max_tokens=\(maxTokens)")
                DispatchQueue.main.async {
                    completion(.failure(RefinerError.truncated(step.label)))
                }
                return
            }

            let refined = Self.stripWrappingQuotes(content.trimmingCharacters(in: .whitespacesAndNewlines))
            Log.refine.info("\(step.label): '\(input)' → '\(refined)'")
            DispatchQueue.main.async { completion(.success(refined)) }
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
            let preset = presets.selected
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
        guard !vocabSection.isEmpty else { return presets.selected.systemPrompt }

        return presets.selected.systemPrompt + """


            VOCABULARY:
            If the transcript contains something like the left side, the speaker almost certainly meant the right side:
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
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidURL(let step):                   return "\(step): invalid API base URL"
            case .missingModel(let step):                 return "\(step): model name is empty"
            case .invalidResponse(let step):              return "\(step): invalid response from LLM API"
            case .requestSerializationFailed(let step):   return "\(step): failed to serialize request"
            case .rateLimited(let step):                  return "\(step): rate limited (429)"
            case .truncated(let step):                    return "\(step): response truncated (finish_reason=length)"
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
