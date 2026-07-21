import Foundation

/// One-way, read-only importer for the user's Rime (鼠须管 / Squirrel) input
/// method: the learned userdb (per-word usage memory), the custom phrase
/// table, and the melt custom dictionary. Never writes to any Rime file or
/// the live LevelDB — it only reads the text snapshots/exports Rime itself
/// maintains alongside them.
///
/// All file work runs on a private background queue; every completion
/// handler fires on the main thread.
enum RimeLexiconImporter {

    // MARK: - Types

    struct ImportResult {
        let terms: [String]
        let updatedAt: Date
    }

    enum ImportError: Error, CustomStringConvertible {
        case notInstalled

        var description: String {
            switch self {
            case .notInstalled: return "Rime (鼠须管) not found at ~/Library/Rime"
            }
        }
    }

    private struct CachedLexicon: Codable {
        let updatedAt: Date
        let terms: [String]
    }

    private struct UserDBEntry {
        let word: String
        let c: Int
        let d: Double
    }

    // MARK: - Public

    /// Re-parses every source from disk and refreshes the cache file.
    static func refresh(completion: @escaping (Result<ImportResult, ImportError>) -> Void) {
        ioQueue.async {
            let result = performImport()
            if case .success(let imported) = result {
                persistCache(imported)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Loads the last-persisted cache without touching any Rime source file —
    /// used at launch so cold start never depends on Squirrel being reachable.
    static func loadCachedResult(completion: @escaping (ImportResult?) -> Void) {
        ioQueue.async {
            let cached = readCache()
            DispatchQueue.main.async { completion(cached) }
        }
    }

    private static let ioQueue = DispatchQueue(label: "com.zhijie.VoiceInput.rimeImport", qos: .utility)
    private static let fm = FileManager.default

    // MARK: - Stopwords

    /// Common Chinese function/filler words the ASR already gets right —
    /// importing these as "vocabulary" would just spend Soniox's context
    /// budget on words that carry zero mishearing risk.
    private static let stopwords: Set<String> = [
        "的", "了", "是", "我", "你", "他", "她", "它", "我们", "你们", "他们", "她们", "它们",
        "这", "那", "这个", "那个", "这些", "那些", "这里", "那里", "这样", "那样",
        "在", "有", "和", "与", "或", "但是", "可是", "不过", "然而", "因为", "所以",
        "如果", "虽然", "但", "就是", "也是", "还是", "而且", "并且", "或者",
        "就", "都", "也", "又", "还", "再", "才", "只", "只是", "仅仅",
        "一直", "一样", "已经", "曾经", "正在", "将要", "会", "能", "可以",
        "应该", "必须", "需要", "想要", "觉得", "认为", "知道", "明白", "了解", "感觉",
        "好像", "似乎", "大概", "可能", "也许", "一定", "肯定", "当然",
        "其实", "实际上", "事实上", "总之", "总的来说", "也就是说", "换句话说",
        "比如", "例如", "比如说", "然后", "接着", "之后", "后来", "最后",
        "首先", "其次", "再次", "另外", "此外", "而", "却", "那么",
        "怎么", "为什么", "什么", "哪里", "哪个", "谁", "怎样", "多少", "几个",
        "一些", "一点", "一下", "一点点", "什么的", "之类", "等等",
        "嗯", "呃", "啊", "哦", "哈哈", "哈哈哈", "呵呵", "嘿嘿", "哎呀", "唉",
        "好的", "好吧", "对", "对的", "对了", "是的", "不是", "没有", "没",
        "不", "别", "请", "谢谢", "不客气", "抱歉", "对不起", "没关系",
    ]

    // MARK: - Import pipeline

    private static func performImport() -> Result<ImportResult, ImportError> {
        let rimeDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Rime", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: rimeDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.notInstalled)
        }

        let (syncDirRaw, installationID) = parseInstallationYAML(
            at: rimeDir.appendingPathComponent("installation.yaml")
        )
        let syncDir: URL
        if let syncDirRaw, !syncDirRaw.isEmpty {
            syncDir = URL(fileURLWithPath: (syncDirRaw as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            syncDir = rimeDir.appendingPathComponent("sync", isDirectory: true)
        }

        let userdbWords = importUserDBWords(syncDir: syncDir, installationID: installationID)
        let customPhraseWords = parseCustomPhrase(at: rimeDir.appendingPathComponent("custom_phrase.txt"))
        let meltCustomWords = parseMeltCustomDict(at: rimeDir.appendingPathComponent("melt_custom.dict.yaml"))

        let combined = uniquePreservingOrder(customPhraseWords + meltCustomWords + userdbWords)
        return .success(ImportResult(terms: combined, updatedAt: Date()))
    }

    /// Ranked, top-300 words learned from the user's typing history.
    private static func importUserDBWords(syncDir: URL, installationID: String?) -> [String] {
        guard let installationID, !installationID.isEmpty else {
            Log.app.info("Rime import: installation_id missing, skipping userdb source")
            return []
        }

        let snapshotDir = syncDir.appendingPathComponent(installationID, isDirectory: true)
        waitForFreshSnapshot(in: snapshotDir)

        guard let files = try? fm.contentsOfDirectory(at: snapshotDir, includingPropertiesForKeys: nil) else {
            Log.app.info("Rime import: no snapshot directory at \(snapshotDir.path, privacy: .public)")
            return []
        }

        var entries: [UserDBEntry] = []
        for file in files where file.lastPathComponent.hasSuffix(".userdb.txt") {
            entries.append(contentsOf: parseUserDBSnapshot(at: file))
        }

        let ranked = entries
            .sorted { lhs, rhs in lhs.c != rhs.c ? lhs.c > rhs.c : lhs.d > rhs.d }
            .map { $0.word }
        return Array(uniquePreservingOrder(ranked).prefix(300))
    }

    // MARK: - Freshness (best-effort Squirrel sync)

    private static let squirrelPath = "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"

    /// Pings the running Squirrel process to flush its in-memory userdb to the
    /// snapshot file, then polls that snapshot's mtime for up to 5 s. Squirrel
    /// syncs asynchronously in its own process — this can only wait for
    /// evidence of a fresh write; on timeout it falls through and parses
    /// whatever is on disk, which still beats parsing nothing.
    private static func waitForFreshSnapshot(in directory: URL) {
        guard fm.fileExists(atPath: squirrelPath) else { return }

        let before = latestSnapshotModificationDate(in: directory)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: squirrelPath)
        process.arguments = ["--sync"]
        do {
            try process.run()
        } catch {
            Log.app.error("Rime import: failed to spawn Squirrel --sync: \(error.localizedDescription, privacy: .public)")
            return
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            if latestSnapshotModificationDate(in: directory) != before { return }
        }
    }

    private static func latestSnapshotModificationDate(in directory: URL) -> Date? {
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        return files
            .filter { $0.lastPathComponent.hasSuffix(".userdb.txt") }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    // MARK: - Source parsers

    /// `sync_dir:` and `installation_id:` out of installation.yaml. Simple
    /// line-based parsing — the file is flat `key: "value"` pairs, no nesting.
    private static func parseInstallationYAML(at url: URL) -> (syncDir: String?, installationID: String?) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }

        var syncDir: String?
        var installationID: String?
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let value = quotedValue(in: line, afterPrefix: "sync_dir:") {
                syncDir = value
            } else if let value = quotedValue(in: line, afterPrefix: "installation_id:") {
                installationID = value
            }
        }
        return (syncDir, installationID)
    }

    private static func quotedValue(in line: String, afterPrefix prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// Snapshot rows: `pinyin syllables \tword\tc=N d=F t=T`. Keep entries
    /// with enough commit count, a plausible word length, and not a stopword.
    private static func parseUserDBSnapshot(at url: URL) -> [UserDBEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var entries: [UserDBEntry] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if rawLine.hasPrefix("#") { continue }
            let columns = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }

            let word = columns[1].trimmingCharacters(in: .whitespaces)
            guard word.count >= 2, word.count <= 20, !stopwords.contains(word) else { continue }

            var c = 0
            var d = 0.0
            for token in columns[2].split(separator: " ") {
                if token.hasPrefix("c=") { c = Int(token.dropFirst(2)) ?? 0 }
                else if token.hasPrefix("d=") { d = Double(token.dropFirst(2)) ?? 0 }
            }
            guard c >= 2 else { continue }

            entries.append(UserDBEntry(word: word, c: c, d: d))
        }
        return entries
    }

    /// custom_phrase.txt rows: `word\tcode\t[weight]` — word is column 1.
    private static func parseCustomPhrase(at url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var words: [String] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let word = line.split(separator: "\t").first else { continue }
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            words.append(trimmed)
        }
        return words
    }

    /// melt_custom.dict.yaml rows: `word\tpinyin\tweight` — word is column 1.
    /// The file opens with a `---` … `...` YAML header of dictionary metadata
    /// that must be skipped before the tab-separated data rows begin.
    private static func parseMeltCustomDict(at url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var pastHeader = false
        var words: [String] = []
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { continue }
            if trimmed == "..." { pastHeader = true; continue }
            guard pastHeader else { continue }
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let word = rawLine.split(separator: "\t").first else { continue }
            let w = word.trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty else { continue }
            words.append(w)
        }
        return words
    }

    private static func uniquePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    // MARK: - Cache

    private static var appSupportDirectory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("VoiceInput", isDirectory: true)
    }

    private static var cacheFileURL: URL {
        appSupportDirectory.appendingPathComponent("rime-lexicon.json", isDirectory: false)
    }

    private static func persistCache(_ result: ImportResult) {
        do {
            if !fm.fileExists(atPath: appSupportDirectory.path) {
                try fm.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(CachedLexicon(updatedAt: result.updatedAt, terms: result.terms))
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            Log.app.error("Rime import: failed to write cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func readCache() -> ImportResult? {
        guard let data = try? Data(contentsOf: cacheFileURL), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(CachedLexicon.self, from: data) else { return nil }
        return ImportResult(terms: cache.terms, updatedAt: cache.updatedAt)
    }
}
