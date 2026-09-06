import Foundation

/// Cursor SDK requests use a shared app-owned worker and fresh text contexts.
/// User API keys use the user's Cursor plan; this is not an OpenAI endpoint.
enum CursorPolishClient {
    static let sdkVersion = "1.0.31"
    static let minimumNodeVersion = "22.13"

    static var defaultSDKDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceInput/CursorSDK", isDirectory: true)
    }

    static func sdkInstallDirectory(override: String) -> URL {
        let path = override.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? defaultSDKDirectory
            : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func nodeExecutable(override: String) -> URL? {
        let path = override.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = path.isEmpty
            ? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/node").path,
               "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            : [(path as NSString).expandingTildeInPath]
        return candidates.first(where: {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }).map { URL(fileURLWithPath: $0) }
    }

    struct Invocation {
        let arguments: [String]
        let standardInput: Data
        let environment: [String: String]
    }

    /// All sensitive material travels over stdin, never command-line flags.
    static func invocation(model: String, apiKey: String, sdkDirectory: URL,
                           directory: URL, helper: URL, text: String, rules: String,
                           modelParams: [CursorModelParameter] = []) throws -> Invocation {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccountCommandError.message("Add a Cursor User API key from Cursor Dashboard → API Keys in Providers.")
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AccountCommandError.message("Select a Cursor model in Providers, for example composer-2.5.")
        }
        var request: [String: Any] = [
            "apiKey": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": model,
            "sdkDirectory": sdkDirectory.path,
            "role": PolishPrompt.role,
            "input": PolishPrompt.input(text: text, rules: rules),
            "nonce": UUID().uuidString,
        ]
        if !modelParams.isEmpty { request["modelParams"] = modelParams.map { ["id": $0.id, "value": $0.value] } }
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        guard data.count <= 1_048_576 else {
            throw AccountCommandError.message("The dictation is too large for Cursor polish. Your original text is preserved.")
        }
        return Invocation(arguments: [helper.path], standardInput: data, environment: workerEnvironment(directory: directory))
    }

    static func workerEnvironment(directory: URL) -> [String: String] {
        ["NODE_OPTIONS": "", "NODE_PATH": "", "CURSOR_API_KEY": "",
         "NODE_TLS_REJECT_UNAUTHORIZED": "1",
         "XDG_CONFIG_HOME": directory.appendingPathComponent("config").path,
         "XDG_CACHE_HOME": directory.appendingPathComponent("cache").path,
         "CURSOR_DATA_DIR": directory.appendingPathComponent("cursor-data").path]
    }

    static func workerConfiguration(nodePath: String, sdkDirectory: String) throws -> CursorWorker.Configuration {
        guard let executable = nodeExecutable(override: nodePath) else {
            throw AccountCommandError.message("Node.js was not found. Install Node \(minimumNodeVersion)+ and set its executable path in Providers.")
        }
        let installation = sdkInstallDirectory(override: sdkDirectory)
        guard FileManager.default.fileExists(atPath: installation.appendingPathComponent("node_modules/@cursor/sdk/package.json").path) else {
            throw AccountCommandError.message("Cursor SDK is not installed. Use Install Cursor SDK in Providers.")
        }
        guard let helper = Bundle.module.url(forResource: "cursor-polish", withExtension: "mjs") else {
            throw AccountCommandError.message("VoiceInput's Cursor helper is missing. Reinstall VoiceInput.")
        }
        return CursorWorker.Configuration(executable: executable, helper: helper, sdkDirectory: installation)
    }

    static func prewarm(model: String, apiKey: String, nodePath: String, sdkDirectory: String,
                        modelParams: [CursorModelParameter] = []) {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let configuration = try workerConfiguration(nodePath: nodePath, sdkDirectory: sdkDirectory)
            let payload: [String: Any] = ["apiKey": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                "model": model, "modelParams": modelParams.map { ["id": $0.id, "value": $0.value] },
                "sdkDirectory": configuration.sdkDirectory.path]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            CursorWorker.shared.prewarm(configuration: configuration, payload: data)
        } catch {
            // Missing runtime is shown by Providers/Test Polish. Startup must
            // remain usable while the user is still configuring a provider.
        }
    }

    @discardableResult
    static func polish(model: String, apiKey: String, nodePath: String, sdkDirectory: String,
                       text: String, rules: String, modelParams: [CursorModelParameter] = [],
                       completion: @escaping (Result<String, Error>) -> Void) -> CursorRequestTask? {
        do {
            let configuration = try workerConfiguration(nodePath: nodePath, sdkDirectory: sdkDirectory)
            // invocation remains usable as an isolated one-shot benchmark;
            // production sends the same payload over the persistent worker.
            let invocation = try invocation(model: model, apiKey: apiKey,
                sdkDirectory: configuration.sdkDirectory, directory: FileManager.default.temporaryDirectory,
                helper: configuration.helper, text: text, rules: rules, modelParams: modelParams)
            return CursorWorker.shared.request(configuration: configuration, payload: invocation.standardInput,
                                               completion: completion)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return nil
        }
    }
}
