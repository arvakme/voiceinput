import Foundation
import Darwin

/// Official CLI adapters. Credentials stay with the CLIs; VoiceInput never
/// reads, copies, or manufactures browser cookies / account access tokens.
enum AccountPolishClient {
    static func executable(for provider: PolishConnection, override: String = "") -> URL? {
        let name = provider.executableName
        let custom = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [String]
        if !custom.isEmpty {
            candidates = [(custom as NSString).expandingTildeInPath]
        } else {
            candidates = [home.appendingPathComponent(".local/bin/\(name)").path,
                          "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
                          home.appendingPathComponent(".\(name)/bin/\(name)").path]
        }
        return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    struct Invocation {
        let arguments: [String]
        let standardInput: Data?
        let outputFile: URL?
        let environment: [String: String]
    }

    static func invocation(provider: PolishConnection, model: String, directory: URL,
                           input: String) throws -> Invocation {
        guard input.utf8.count <= 1_048_576 else {
            throw AccountCommandError.message("Account input exceeded the size limit.")
        }
        switch provider {
        case .api:
            throw AccountCommandError.message("Choose an account provider.")
        case .codex:
            let output = directory.appendingPathComponent("result.txt")
            var args = ["exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
                        "--sandbox", "read-only", "--color", "never", "-C", directory.path,
                        "--output-last-message", output.path,
                        "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
                        "-c", "model_reasoning_effort=\"low\"",
                        "-c", "forced_login_method=\"chatgpt\"",
                        "-c", "base_instructions=\(tomlString(PolishPrompt.role))"]
            for feature in ["shell_tool", "plugins", "apps", "hooks", "multi_agent", "image_generation",
                            "browser_use", "computer_use", "view_image", "skill_search", "workspace_dependencies", "goals"] {
                args += ["--disable", feature]
            }
            if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--model", model] }
            args.append("-")
            return Invocation(arguments: args, standardInput: Data(input.utf8), outputFile: output, environment: [:])
        case .grok:
            let prompt = directory.appendingPathComponent("prompt.txt")
            try Data(input.utf8).write(to: prompt, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prompt.path)
            // Empty --tools means inherit ALL tools in Grok. Select one known
            // tool then explicitly remove it and the always-retained MCP tools.
            var args = ["--prompt-file", prompt.path, "--output-format", "json", "--verbatim",
                        "--system-prompt-override", PolishPrompt.role, "--tools", "read_file",
                        "--disallowed-tools", "read_file,search_tool,use_tool",
                        "--deny", "*", "--no-subagents", "--no-memory", "--no-ask-user",
                        "--no-auto-update", "--no-plan", "--disable-web-search", "--max-turns", "1",
                        "--permission-mode", "dontAsk", "--cwd", directory.path]
            if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args += ["--model", model] }
            return Invocation(arguments: args, standardInput: nil, outputFile: nil,
                              environment: try grokEnvironment(directory: directory))
        }
    }

    /// Isolate user hooks, MCP, plugins and session files without touching
    /// credentials: the official CLI still reads/refreshes its original auth path.
    static func grokEnvironment(directory: URL,
                                inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        let isolatedHome = directory.appendingPathComponent("grok-home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let originalHome = inherited["GROK_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok").path
        let authPath = inherited["GROK_AUTH_PATH"].flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: originalHome).appendingPathComponent("auth.json").path
        let config = """
        [grok_com_config]
        disable_api_key_auth = true
        [managed_mcps]
        enabled = false
        [cli]
        auto_update = false
        """
        try Data(config.utf8).write(to: isolatedHome.appendingPathComponent("config.toml"), options: .atomic)
        var environment = ["GROK_HOME": isolatedHome.path, "GROK_AUTH_PATH": authPath,
                           "GROK_CONFIG": "{}", "GROK_CONFIG_PATH": "",
                           "GROK_DISABLE_API_KEY_AUTH": "true", "GROK_MANAGED_MCPS_ENABLED": "false",
                           "GROK_MANAGED_MCP_GATEWAY_TOOLS_ENABLED": "false"]
        for provider in ["CLAUDE", "CURSOR", "CODEX"] {
            for feature in ["SKILLS", "RULES", "AGENTS", "MCPS", "HOOKS", "SESSIONS"] {
                environment["GROK_\(provider)_\(feature)_ENABLED"] = "false"
            }
        }
        return environment
    }

    static func grokText(from output: String) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              object["stopReason"] as? String == "end_turn",
              let text = object["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccountCommandError.message("Grok did not return a complete polish response.")
        }
        return text
    }

    private static func tomlString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func polish(provider: PolishConnection, model: String, executablePath: String,
                       text: String, rules: String,
                       completion: @escaping (Result<String, Error>) -> Void) -> AccountCommandTask? {
        do {
            guard text.utf8.count + rules.utf8.count <= 1_048_576 else {
                throw AccountCommandError.message("Account input exceeded the size limit.")
            }
            guard let executable = executable(for: provider, override: executablePath) else {
                throw AccountCommandError.message("\(provider.executableName) was not found. Install its official CLI, then sign in in Providers.")
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voiceinput-polish-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let invocation: Invocation
            do {
                invocation = try Self.invocation(provider: provider, model: model, directory: directory,
                                            input: PolishPrompt.input(text: text, rules: rules))
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            let task = AccountCommandTask(executable: executable, arguments: invocation.arguments,
                                          directory: directory, input: invocation.standardInput, timeout: 60,
                                          environment: invocation.environment) { result in
                defer { try? FileManager.default.removeItem(at: directory) }
                completion(result.flatMap { stdout in
                    do {
                        let output: String
                        if let file = invocation.outputFile {
                            let handle = try FileHandle(forReadingFrom: file)
                            defer { try? handle.close() }
                            let data = try handle.read(upToCount: 1_048_577) ?? Data()
                            guard data.count <= 1_048_576 else {
                                throw AccountCommandError.message("Account output exceeded the size limit.")
                            }
                            guard let decoded = String(data: data, encoding: .utf8) else {
                                throw AccountCommandError.message("Account output was not valid text.")
                            }
                            output = decoded
                        } else {
                            output = try Self.grokText(from: stdout)
                        }
                        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { throw AccountCommandError.message("The account returned no polish text.") }
                        return .success(trimmed)
                    } catch { return .failure(error) }
                })
            }
            task.start()
            return task
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return nil
        }
    }
}

enum AccountCommandError: LocalizedError {
    case message(String)
    case cancelled
    case timeout
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .cancelled: return "Account request cancelled."
        case .timeout: return "Account request timed out. Your original dictation is preserved."
        }
    }
}

/// Bounded subprocess I/O, timeout and cancellation. Arguments are passed
/// directly to Process, never interpolated into a shell command.
// Mutable lifecycle state is lock-protected; completion is dispatched to main.
final class AccountCommandTask: @unchecked Sendable {
    private let executable: URL
    private let arguments: [String]
    private let directory: URL
    private let input: Data?
    private let timeout: TimeInterval
    private let environment: [String: String]
    private let completion: (Result<String, Error>) -> Void
    private let lock = NSLock()
    private var process: Process?
    private var cancelReason: AccountCommandError?
    private var started = false
    private var finished = false

    init(executable: URL, arguments: [String], directory: URL, input: Data? = nil,
         timeout: TimeInterval, environment: [String: String] = [:], completion: @escaping (Result<String, Error>) -> Void) {
        self.executable = executable; self.arguments = arguments; self.directory = directory
        self.input = input; self.timeout = timeout; self.environment = environment; self.completion = completion
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { self.run() }
    }

    func cancel() { stop(reason: .cancelled) }

    private func stop(reason: AccountCommandError) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if cancelReason == nil { cancelReason = reason }
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func run() {
        let process = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // A GUI app has a sparse PATH; official CLIs still need their helpers.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        // Account mode must not silently charge a configured API key instead.
        env.removeValue(forKey: "OPENAI_API_KEY")
        env.removeValue(forKey: "XAI_API_KEY")
        env.removeValue(forKey: "GROK_CODE_XAI_API_KEY")
        env.removeValue(forKey: "OPENAI_BASE_URL")
        env.merge(environment) { _, new in new }
        process.environment = env
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
        do {
            lock.lock()
            if let reason = cancelReason { lock.unlock(); finish(.failure(reason)); return }
            self.process = process
            do { try process.run() } catch { lock.unlock(); throw error }
            lock.unlock()
            let group = DispatchGroup()
            let out = CommandOutputBuffer(), err = CommandOutputBuffer()
            for (pipe, buffer) in [(stdout, out), (stderr, err)] {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { group.leave() }
                    let fd = pipe.fileHandleForReading.fileDescriptor
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    while true {
                        let count = Darwin.read(fd, &bytes, bytes.count)
                        if count > 0 {
                            buffer.append(Data(bytes.prefix(count)))
                            if buffer.overflow { break }
                            continue
                        }
                        if count == 0 { break }
                        if errno != EAGAIN && errno != EINTR { break }
                        // Descendants may inherit pipe handles. Once our CLI
                        // exits, never wait forever for their EOF.
                        if !process.isRunning { break }
                        usleep(10_000)
                    }
                    try? pipe.fileHandleForReading.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop(reason: .timeout) }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { try? stdin.fileHandleForWriting.close(); group.leave() }
                guard let input = self.input else { return }
                let fd = stdin.fileHandleForWriting.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                input.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count, process.isRunning {
                        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(8192, bytes.count - offset))
                        if count > 0 { offset += count }
                        else if errno == EAGAIN || errno == EINTR { usleep(10_000) }
                        else { break }
                    }
                }
            }
            process.waitUntilExit()
            group.wait()
            lock.lock(); let reason = cancelReason; lock.unlock()
            if let reason { finish(.failure(reason)); return }
            guard !out.overflow else { finish(.failure(AccountCommandError.message("Account output exceeded the size limit."))); return }
            guard process.terminationStatus == 0 else {
                // Do not display arbitrary stderr: CLI errors may contain
                // credentials, prompts, or account details. Keep it generic.
                let raw = err.text.lowercased()
                let hint = raw.contains("login") || raw.contains("auth") || raw.contains("401")
                    ? "Sign in again in Providers."
                    : "Check the selected model and account quota, then try Test polish."
                finish(.failure(AccountCommandError.message("\(executable.lastPathComponent) exited with code \(process.terminationStatus). \(hint)")))
                return
            }
            finish(.success(out.text))
        } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; process = nil
        lock.unlock()
        DispatchQueue.main.async { self.completion(result) }
    }
}

private final class CommandOutputBuffer {
    private var data = Data()
    private(set) var overflow = false
    func append(_ chunk: Data) {
        let remaining = max(0, 1_048_576 - data.count)
        if chunk.count > remaining { overflow = true }
        data.append(chunk.prefix(remaining))
    }
    var text: String { String(decoding: data, as: UTF8.self) }
}
