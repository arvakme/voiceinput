import Foundation
import Combine

// MARK: - VocabularyEntry

struct VocabularyEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Canonical spelling, e.g. "Claude Code".
    var term: String
    /// Common mishearings, comma-separated. May be empty.
    var hints: String
    /// True for entries `VocabularyStore.learnFromCorrection` added on its
    /// own from a small review-box edit, rather than one you typed in by
    /// hand — surfaced in the Vocabulary tab so a bad auto-guess is easy to
    /// spot and delete.
    var autoLearned: Bool = false

    private enum CodingKeys: String, CodingKey { case id, term, hints, autoLearned }

    init(id: UUID = UUID(), term: String, hints: String, autoLearned: Bool = false) {
        self.id = id
        self.term = term
        self.hints = hints
        self.autoLearned = autoLearned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        term = try container.decode(String.self, forKey: .term)
        hints = try container.decode(String.self, forKey: .hints)
        // Missing for every entry saved before this field existed.
        autoLearned = try container.decodeIfPresent(Bool.self, forKey: .autoLearned) ?? false
    }
}

struct VocabularySuggestion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    let oldTerm: String
    let newTerm: String
    let source: VocabularyStore.LearningSource
    var observations: Int = 1
}

// MARK: - VocabularyStore

final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    enum LearningSource: String, Codable {
        case userCorrection
        case polish
    }

    private let injectedDefaults: UserDefaults?
    private var preferenceDefaults: UserDefaults { injectedDefaults ?? .standard }

    @Published var learningEnabled: Bool {
        didSet { preferenceDefaults.set(learningEnabled, forKey: "vocabularyLearningEnabled") }
    }
    @Published private(set) var pendingCandidates: [VocabularySuggestion] {
        didSet { persistSuggestions() }
    }
    private var ignoredTerms: Set<String> {
        didSet { preferenceDefaults.set(Array(ignoredTerms).sorted(), forKey: "vocabularyIgnoredTerms") }
    }


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

    /// Doubao's bidirectional-streaming hotword list is capped at 100 tokens
    /// total (vs. Soniox's much larger session budget) — keep only the
    /// highest-priority terms.
    private static let maxDoubaoTerms = 30
    private static let maxDoubaoCharBudget = 90

    private static let maxPromptLines = 60
    private static let maxPromptChars = 2000

    init(defaults: UserDefaults? = nil, loadRimeCache: Bool = true) {
        injectedDefaults = defaults
        let preferences = defaults ?? .standard
        learningEnabled = preferences.object(forKey: "vocabularyLearningEnabled") as? Bool ?? true
        if let data = preferences.data(forKey: "vocabularySuggestionsJSON"),
           let suggestions = try? JSONDecoder().decode([VocabularySuggestion].self, from: data) {
            pendingCandidates = Array(suggestions.prefix(100))
        } else {
            pendingCandidates = []
        }
        ignoredTerms = Set(preferences.stringArray(forKey: "vocabularyIgnoredTerms") ?? [])
        entries = VocabularyStore.load(defaults: defaults)
        guard loadRimeCache else { return }
        RimeLexiconImporter.loadCachedResult { [weak self] cached in
            guard let self, let cached else { return }
            self.importedTerms = cached.terms
            self.importedTermCount = cached.terms.count
            self.importedRefreshDate = cached.updatedAt
        }
    }

    // MARK: - Persistence

    private static func load(defaults: UserDefaults?) -> [VocabularyEntry] {
        let json: String
        if let defaults { json = defaults.string(forKey: "vocabularyJSON") ?? "[]" }
        else { json = AppSettings.shared.vocabularyJSON }
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
        if let injectedDefaults { injectedDefaults.set(json, forKey: "vocabularyJSON") }
        else { AppSettings.shared.vocabularyJSON = json }
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
        rankedTerms(maxCount: Self.maxSonioxTerms, maxCharBudget: Self.maxSonioxCharBudget)
    }

    /// Same manual-first, dedupe-then-cap ranking as `sonioxTerms`, but
    /// trimmed to Doubao's much tighter 100-token hotword budget.
    var doubaoHotwords: [String] {
        rankedTerms(maxCount: Self.maxDoubaoTerms, maxCharBudget: Self.maxDoubaoCharBudget)
    }

    private func rankedTerms(maxCount: Int, maxCharBudget: Int) -> [String] {
        let manual = entries
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [String] = []
        var totalChars = 0

        for term in manual + importedTerms {
            guard result.count < maxCount else { break }
            let key = Self.dedupeKey(for: term)
            guard seen.insert(key).inserted else { continue }
            guard totalChars + term.count <= maxCharBudget else { break }
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
        ignoredTerms.remove(Self.dedupeKey(for: entry.term))
        entries.append(entry)
    }

    func remove(at offsets: IndexSet) {
        for index in offsets where entries.indices.contains(index) {
            ignoredTerms.insert(Self.dedupeKey(for: entries[index].term))
        }
        entries.remove(atOffsets: offsets)
    }

    func update(_ entry: VocabularyEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
    }

    /// Called only after the user actually accepts/delivers a transcription.
    /// User spelling corrections are stronger evidence than model rewrites;
    /// model changes stay out of ASR/LLM prompts until explicitly approved.
    @discardableResult
    func observeCorrections(original: String, corrected: String, source: LearningSource) -> Int {
        guard learningEnabled else { return 0 }
        var added = 0
        for candidate in CorrectionLearner.detectSubstitutions(original: original, corrected: corrected) {
            let key = Self.dedupeKey(for: candidate.newTerm)
            guard !ignoredTerms.contains(key) else { continue }
            if source == .userCorrection, candidate.canLearnAutomatically {
                let before = entries
                learnFromCorrection(oldTerm: candidate.oldTerm, newTerm: candidate.newTerm)
                pendingCandidates.removeAll { Self.dedupeKey(for: $0.newTerm) == key }
                if before != entries { added += 1 }
            } else {
                // Repeated AI changes are observations, not confirmation.
                // Never let a self-reinforcing model guess become a hotword.
                if entries.contains(where: { Self.dedupeKey(for: $0.term) == key }) { continue }
                if let index = pendingCandidates.firstIndex(where: {
                    Self.dedupeKey(for: $0.newTerm) == key && $0.oldTerm.caseInsensitiveCompare(candidate.oldTerm) == .orderedSame
                }) {
                    pendingCandidates[index].observations = min(999, pendingCandidates[index].observations + 1)
                } else if pendingCandidates.count < 100 {
                    pendingCandidates.append(VocabularySuggestion(oldTerm: candidate.oldTerm,
                        newTerm: candidate.newTerm, source: source))
                    added += 1
                }
            }
        }
        return added
    }

    func acceptSuggestion(_ id: UUID) {
        guard let suggestion = pendingCandidates.first(where: { $0.id == id }) else { return }
        ignoredTerms.remove(Self.dedupeKey(for: suggestion.newTerm))
        learnFromCorrection(oldTerm: suggestion.oldTerm, newTerm: suggestion.newTerm)
        pendingCandidates.removeAll { $0.id == id }
    }

    func dismissSuggestion(_ id: UUID) {
        guard let suggestion = pendingCandidates.first(where: { $0.id == id }) else { return }
        let key = Self.dedupeKey(for: suggestion.newTerm)
        ignoredTerms.insert(key)
        pendingCandidates.removeAll { Self.dedupeKey(for: $0.newTerm) == key }
    }

    private func persistSuggestions() {
        guard let data = try? JSONEncoder().encode(pendingCandidates) else { return }
        preferenceDefaults.set(data, forKey: "vocabularySuggestionsJSON")
    }

    /// Called with a small, word/phrase-level review-box edit (see
    /// `CorrectionLearner`) — folds it into the vocabulary so the same
    /// mishearing is corrected automatically next time. Merges into an
    /// existing entry for `newTerm` when one exists rather than creating a
    /// duplicate row; marks brand-new entries `autoLearned` so they're
    /// visibly distinct from ones you typed in yourself.
    func learnFromCorrection(oldTerm: String, newTerm: String) {
        let old = oldTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty, !new.isEmpty, old != new else { return }

        let key = Self.dedupeKey(for: new)
        if let idx = entries.firstIndex(where: { Self.dedupeKey(for: $0.term) == key }) {
            let existingHints = entries[idx].hints
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard !existingHints.contains(where: { $0.caseInsensitiveCompare(old) == .orderedSame }) else { return }
            entries[idx].hints = existingHints.isEmpty ? old : existingHints.joined(separator: ", ") + ", " + old
        } else {
            entries.append(VocabularyEntry(term: new, hints: old, autoLearned: true))
        }
    }
}
