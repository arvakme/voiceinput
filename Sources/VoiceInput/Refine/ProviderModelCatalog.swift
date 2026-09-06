import Foundation
import CryptoKit

struct CursorModelParameter: Codable, Equatable, Hashable {
    let id: String
    let value: String
}

struct CatalogModel: Identifiable, Codable, Equatable {
    let modelID: String
    let displayName: String
    var detail: String = ""
    var parameters: [CursorModelParameter] = []
    var id: String {
        modelID + "|" + parameters.sorted { $0.id < $1.id }.map { "\($0.id)=\($0.value)" }.joined(separator: "&")
    }
}

enum ModelCatalog {
    enum Kind: String { case chat, sonioxRealtime, sonioxAsync, cursor, codex, grok, geminiLive }
    struct Configuration {
        var kind: Kind
        var baseURL = ""
        var apiKey = ""
        var executablePath = ""
        var nodePath = ""
        var sdkDirectory = ""
        var cacheKey: String {
            let value = [kind.rawValue, baseURL, apiKey, executablePath, nodePath, sdkDirectory].joined(separator: "\u{0}")
            return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func fetch(configuration: Configuration, refresh: Bool = false) async throws -> [CatalogModel] {
        if !refresh, let cached = await CatalogCache.shared.get(configuration.cacheKey) { return cached }
        let models: [CatalogModel]
        switch configuration.kind {
        case .cursor, .codex, .grok:
            models = try await commandModels(configuration)
        case .sonioxRealtime, .sonioxAsync:
            guard !configuration.apiKey.isEmpty else { throw CatalogError.message("Add your Soniox API key, then Refresh.") }
            let object = try await get(URL(string: "https://api.soniox.com/v1/models")!, key: configuration.apiKey)
            models = try parseSoniox(object, realtime: configuration.kind == .sonioxRealtime)
        case .geminiLive:
            guard !configuration.apiKey.isEmpty else { throw CatalogError.message("Add your Gemini API key, then Refresh.") }
            var token: String?, rows: [CatalogModel] = []
            for _ in 0..<20 {
                var parts = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
                parts.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
                if let token { parts.queryItems?.append(URLQueryItem(name: "pageToken", value: token)) }
                let object = try await get(parts.url!, key: configuration.apiKey, google: true)
                rows += try parseGemini(object)
                token = object["nextPageToken"] as? String
                if token?.isEmpty != false { break }
            }
            models = rows
        case .chat:
            let url = try modelsURL(configuration.baseURL)
            do {
                models = try parseCompatible(await get(url, key: configuration.apiKey,
                    anthropic: url.host == "api.anthropic.com"))
            } catch {
                // Ollama offers OpenAI /v1/models and native /api/tags. A
                // configured local server can support either, never send its
                // key to a different origin while trying the native dialect.
                guard url.host == "localhost" || url.host == "127.0.0.1" || url.port == 11434 else { throw error }
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                parts.path = "/api/tags"; parts.query = nil
                models = try parseOllama(await get(parts.url!, key: configuration.apiKey))
            }
        }
        var seen = Set<String>()
        let unique = models.filter { !$0.modelID.isEmpty && seen.insert($0.id).inserted }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard !unique.isEmpty else { throw CatalogError.message("No compatible models were returned for this account. Check provider access, then Refresh.") }
        await CatalogCache.shared.put(configuration.cacheKey, models: unique)
        return unique
    }

    static func modelsURL(_ base: String) throws -> URL {
        guard var parts = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil,
              parts.user == nil, parts.password == nil else { throw CatalogError.message("Enter a valid HTTP(S) base URL.") }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.path = "/" + (parts.path.isEmpty ? "models" : parts.path + "/models")
        parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { throw CatalogError.message("Invalid base URL.") }
        return url
    }

    private static func get(_ url: URL, key: String, anthropic: Bool = false, google: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        if google { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        else if anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.message(http.statusCode == 401 || http.statusCode == 403
                ? "The provider rejected access. Check the API key or sign in again, then Refresh."
                : "Model discovery returned HTTP \(http.statusCode). Check the provider URL and connection, then Refresh.")
        }
        guard data.count <= 8_388_608,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CatalogError.badResponse }
        return object
    }

    static func parseCompatible(_ object: [String: Any]) throws -> [CatalogModel] {
        guard let rows = object["data"] as? [[String: Any]] else { throw CatalogError.badResponse }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return CatalogModel(modelID: id, displayName: row["name"] as? String ?? row["display_name"] as? String ?? id,
                                detail: row["description"] as? String ?? "")
        }
    }
    static func parseOllama(_ object: [String: Any]) throws -> [CatalogModel] {
        guard let rows = object["models"] as? [[String: Any]] else { throw CatalogError.badResponse }
        return rows.compactMap { row in
            guard let id = row["name"] as? String ?? row["model"] as? String else { return nil }
            return CatalogModel(modelID: id, displayName: id, detail: "Installed in Ollama")
        }
    }
    static func parseSoniox(_ object: [String: Any], realtime: Bool) throws -> [CatalogModel] {
        guard let rows = object["models"] as? [[String: Any]] else { throw CatalogError.badResponse }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, id.hasPrefix(realtime ? "stt-rt-" : "stt-async-") else { return nil }
            return CatalogModel(modelID: id, displayName: id, detail: realtime ? "Realtime speech recognition" : "Batch speech recognition")
        }
    }
    static func parseGemini(_ object: [String: Any]) throws -> [CatalogModel] {
        guard let rows = object["models"] as? [[String: Any]] else { throw CatalogError.badResponse }
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let methods = row["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains(where: { $0.lowercased().contains("bidi") }) || name.lowercased().contains("live") else { return nil }
            let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
            return CatalogModel(modelID: id, displayName: row["displayName"] as? String ?? id,
                                detail: row["description"] as? String ?? "Live audio")
        }
    }

    private static func commandModels(_ config: Configuration) async throws -> [CatalogModel] {
        guard let node = CursorPolishClient.nodeExecutable(override: config.nodePath) else {
            throw CatalogError.message("Install Node.js 22.13+ to browse account models, or set its executable in Cursor SDK settings.")
        }
        guard let helper = Bundle.module.url(forResource: "provider-models", withExtension: "mjs") else {
            throw CatalogError.message("The model catalog helper is missing. Rebuild VoiceInput.")
        }
        var input = ["provider": config.kind.rawValue]
        if config.kind == .cursor {
            guard !config.apiKey.isEmpty else { throw CatalogError.message("Add your Cursor User API key, then Refresh.") }
            input["apiKey"] = config.apiKey
            input["sdkDirectory"] = CursorPolishClient.sdkInstallDirectory(override: config.sdkDirectory).path
        } else {
            let provider: PolishConnection = config.kind == .grok ? .grok : .codex
            guard let executable = AccountPolishClient.executable(for: provider, override: config.executablePath) else {
                throw CatalogError.message("Install \(provider.executableName), sign in, then Refresh.")
            }
            input["executable"] = executable.path
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voiceinput-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: input)
        let holder = CatalogTaskHolder()
        let output: String
        do {
            output = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = AccountCommandTask(executable: node, arguments: [helper.path], directory: directory,
                    input: data, timeout: 30, environment: ["NODE_OPTIONS": "", "NODE_PATH": "", "CURSOR_DATA_DIR": directory.appendingPathComponent("cursor-data").path]) { result in
                        try? FileManager.default.removeItem(at: directory)
                        holder.clear()
                        continuation.resume(with: result)
                    }
                holder.set(task)
                task.start()
            }
            }, onCancel: { holder.cancel() })
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw CatalogError.message("Model discovery failed. Check provider sign-in, Node/SDK installation and connectivity, then Refresh.")
        }
        guard let json = output.data(using: .utf8),
              let models = try? JSONDecoder().decode([CatalogModel].self, from: json) else { throw CatalogError.badResponse }
        return models
    }

    enum CatalogError: LocalizedError {
        case badResponse, message(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "The provider returned an unexpected model catalog. Update its CLI/SDK and try Refresh."
            case .message(let value): return value
            }
        }
    }
}

private actor CatalogCache {
    static let shared = CatalogCache()
    private var entries: [String: (Date, [CatalogModel])] = [:]
    func get(_ key: String) -> [CatalogModel]? {
        guard let value = entries[key], Date().timeIntervalSince(value.0) < 300 else { return nil }
        return value.1
    }
    func put(_ key: String, models: [CatalogModel]) {
        if entries.count > 32 { entries.removeAll() }
        entries[key] = (Date(), models)
    }
}

private final class CatalogTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: AccountCommandTask?
    private var cancelled = false
    func set(_ task: AccountCommandTask) {
        lock.lock(); self.task = task; let stop = cancelled; lock.unlock()
        if stop { task.cancel() }
    }
    func clear() { lock.lock(); task = nil; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
}
