import Foundation
import Combine

// MARK: - VocabularyEntry

struct VocabularyEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Canonical spelling, e.g. "Claude Code".
    var term: String
    /// Common mishearings, comma-separated. May be empty.
    var hints: String
}

// MARK: - VocabularyStore

final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    /// All entries, persisted to `AppSettings.shared.vocabularyJSON` on every change.
    @Published var entries: [VocabularyEntry] {
        didSet { save() }
    }

    // MARK: Rime import state (UI-facing)

    /// Terms pulled from the user's Rime (鼠须管) input-method dictionaries.
    /// Loaded from cache at init and replaced wholesale by `refreshFromRime`.
    /// Never persisted directly — `RimeLexiconImporter` owns its own cache file.
    private var importedTerms: [String] = []

    @Published private(set) var importedTermCount: Int = 0
    @Published private(set) var importedRefreshDate: Date?
    @Published private(set) var importedRefreshError: String?
    @Published private(set) var isRefreshingImportedTerms: Bool = false

    // MARK: Term budget (Soniox rejects the whole session past ~8,000 tokens)

    private static let maxSonioxTerms = 500
    private static let maxSonioxCharBudget = 6000

    private static let maxPromptLines = 60
    private static let maxPromptChars = 2000

    private init() {
        entries = VocabularyStore.load()

        RimeLexiconImporter.loadCachedResult { [weak self] cached in
            guard let self, let cached else { return }
            self.importedTerms = cached.terms
            self.importedTermCount = cached.terms.count
            self.importedRefreshDate = cached.updatedAt
        }
    }

    // MARK: - Persistence

    private static func load() -> [VocabularyEntry] {
        let json = AppSettings.shared.vocabularyJSON
        guard
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([VocabularyEntry].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func save() {
        guard
            let data = try? JSONEncoder().encode(entries),
            let json = String(data: data, encoding: .utf8)
        else { return }
        AppSettings.shared.vocabularyJSON = json
    }

    // MARK: - Rime import

    /// Runs the Rime lexicon importer and updates the cache + published state.
    /// Safe to call from the main thread; the importer does its own file work
    /// on a background queue and delivers its result back on main.
    func refreshFromRime(completion: (() -> Void)? = nil) {
        guard !isRefreshingImportedTerms else {
            completion?()
            return
        }
        isRefreshingImportedTerms = true

        RimeLexiconImporter.refresh { [weak self] result in
            guard let self else {
                completion?()
                return
            }
            self.isRefreshingImportedTerms = false
            switch result {
            case .success(let imported):
                self.importedTerms = imported.terms
                self.importedTermCount = imported.terms.count
                self.importedRefreshDate = imported.updatedAt
                self.importedRefreshError = nil
            case .failure(let error):
                self.importedRefreshError = String(describing: error)
            }
            completion?()
        }
    }

    // MARK: - Derived

    /// Non-empty canonical term strings, suitable for the Soniox `context.terms`
    /// array: manual entries first (they always win ties), then imported Rime
    /// terms not already present, deduped (case-insensitive for ASCII, exact
    /// for CJK) and capped so the context payload never triggers Soniox's
    /// ~8,000-token session limit.
    var sonioxTerms: [String] {
        let manual = entries
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [String] = []
        var totalChars = 0

        for term in manual + importedTerms {
            guard result.count < Self.maxSonioxTerms else { break }
            let key = Self.dedupeKey(for: term)
            guard seen.insert(key).inserted else { continue }
            guard totalChars + term.count <= Self.maxSonioxCharBudget else { break }
            result.append(term)
            totalChars += term.count
        }
        return result
    }

    /// Prompt section for the polish LLM. Empty string when there are no entries.
    /// Lines formatted as: - "cloud code" → "Claude Code"
    /// Manual-only — imported terms carry no mishearing hints, so including
    /// them here would bloat the prompt with nothing to correct.
    var promptSection: String {
        guard !entries.isEmpty else { return "" }

        var lines: [String] = []
        var totalChars = 0

        outer: for entry in entries {
            let canonical = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }

            // Each mishearing produces its own bullet line.
            let mishearings = entry.hints
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if mishearings.isEmpty {
                // No hints → there is no left-side mishearing to match against, so
                // a bare term carries zero correction signal for this "left → right"
                // prompt. Skip it here; the canonical term is still sent to Soniox
                // via sonioxTerms for recognition biasing.
                continue
            }
            for mishearing in mishearings {
                let line = "- \"\(mishearing)\" → \"\(canonical)\""
                guard lines.count < Self.maxPromptLines,
                      totalChars + line.count <= Self.maxPromptChars
                else { break outer }
                lines.append(line)
                totalChars += line.count
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Dedupe key for term comparison: case-insensitive for ASCII terms
    /// (mishearings differ only in case), exact for anything containing CJK
    /// (which has no case, and where lowercasing would be meaningless).
    private static func dedupeKey(for term: String) -> String {
        containsCJK(term) ? term : term.lowercased()
    }

    private static func containsCJK(_ term: String) -> Bool {
        term.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)   // CJK Unified Ideographs
                || (0x3400...0x4DBF).contains(scalar.value) // CJK Extension A
                || (0xF900...0xFAFF).contains(scalar.value) // CJK Compatibility Ideographs
        }
    }

    // MARK: - Mutations

    func add(_ entry: VocabularyEntry) {
        entries.append(entry)
    }

    func remove(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
    }

    func update(_ entry: VocabularyEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
    }
}
