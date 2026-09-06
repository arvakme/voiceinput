import Foundation
import Testing
@testable import VoiceInput

@MainActor
struct VocabularyLearningTests {
    private func withStore(_ body: (VocabularyStore, UserDefaults) throws -> Void) throws {
        let name = "voiceinput-vocabulary-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(VocabularyStore(defaults: defaults, loadRimeCache: false), defaults)
    }

    @Test func preservesWholeWordsInsteadOfChangedLetterFragments() {
        let candidates = CorrectionLearner.detectSubstitutions(
            original: "use Cloude", corrected: "use Claude")
        #expect(candidates == [.init(oldTerm: "Cloude", newTerm: "Claude")])
        #expect(CorrectionLearner.detectSubstitutions(original: "use Cloude", corrected: "use Claude.")
            == [.init(oldTerm: "Cloude", newTerm: "Claude")])
    }

    @Test func extractsMultipleCorrectionsAndMultiwordNames() {
        let candidates = CorrectionLearner.detectSubstitutions(
            original: "打开cloud code，然后打开get hub。",
            corrected: "打开Claude Code，然后打开GitHub。")
        #expect(candidates == [
            .init(oldTerm: "cloud code", newTerm: "Claude Code"),
            .init(oldTerm: "get hub", newTerm: "GitHub")
        ])
    }

    @Test func ignoresInsertionsDeletionsAndOrdinaryRewrites() {
        #expect(CorrectionLearner.detectSubstitutions(original: "open", corrected: "open GitHub").isEmpty)
        #expect(CorrectionLearner.detectSubstitutions(original: "open GitHub", corrected: "open").isEmpty)
        #expect(CorrectionLearner.detectSubstitutions(original: "hello", corrected: "Hello.").isEmpty)
        #expect(CorrectionLearner.detectSubstitutions(original: "make it dark", corrected: "Change Appearance").isEmpty)
        #expect(CorrectionLearner.detectSubstitutions(original: "the cat", corrected: "the dog").isEmpty)
    }

    @Test func learnsUserTermsAndMergesMishearingsWithoutDuplicates() throws {
        try withStore { store, defaults in
            #expect(store.observeCorrections(original: "use cloude", corrected: "use Claude", source: .userCorrection) == 1)
            #expect(store.observeCorrections(original: "use cloud", corrected: "use Claude", source: .userCorrection) == 1)
            #expect(store.entries.count == 1)
            #expect(store.entries.first?.term == "Claude")
            #expect(store.entries.first?.hints == "cloude, cloud")
            #expect(store.entries.first?.autoLearned == true)
            #expect(store.sonioxTerms == ["Claude"])
            #expect(store.promptSection.contains("cloude"))
            let reloaded = VocabularyStore(defaults: defaults, loadRimeCache: false)
            #expect(reloaded.entries == store.entries)
        }
    }

    @Test func repeatedAIChangesStayPendingUntilConfirmed() throws {
        try withStore { store, defaults in
            for _ in 0..<3 {
                store.observeCorrections(original: "use cloud code", corrected: "use Claude Code", source: .polish)
            }
            #expect(store.entries.isEmpty)
            #expect(store.sonioxTerms.isEmpty)
            #expect(store.promptSection.isEmpty)
            #expect(store.pendingCandidates.count == 1)
            #expect(store.pendingCandidates.first?.observations == 3)
            let reloaded = VocabularyStore(defaults: defaults, loadRimeCache: false)
            let candidate = try #require(reloaded.pendingCandidates.first)
            reloaded.acceptSuggestion(candidate.id)
            #expect(reloaded.entries.first?.term == "Claude Code")
            #expect(reloaded.entries.first?.autoLearned == true)
            #expect(reloaded.pendingCandidates.isEmpty)
        }
    }

    @Test func chinesePhrasesRequireConfirmation() throws {
        try withStore { store, _ in
            store.observeCorrections(original: "张小民", corrected: "张晓明", source: .userCorrection)
            #expect(store.entries.isEmpty)
            #expect(store.pendingCandidates.first?.newTerm == "张晓明")
        }
    }

    @Test func realCorrectionPromotesAnAICandidate() throws {
        try withStore { store, _ in
            store.observeCorrections(original: "use cloud", corrected: "use Claude", source: .polish)
            store.observeCorrections(original: "use cloude", corrected: "use Claude", source: .userCorrection)
            #expect(store.entries.first?.term == "Claude")
            #expect(store.entries.first?.hints == "cloude")
            #expect(store.pendingCandidates.isEmpty)
        }
    }

    @Test func disabledLearningPersistsAndCollectsNothing() throws {
        try withStore { store, defaults in
            store.learningEnabled = false
            store.observeCorrections(original: "use cloud", corrected: "use Claude", source: .userCorrection)
            store.observeCorrections(original: "use cloud", corrected: "use Claude", source: .polish)
            #expect(store.entries.isEmpty)
            #expect(store.pendingCandidates.isEmpty)
            #expect(!VocabularyStore(defaults: defaults, loadRimeCache: false).learningEnabled)
        }
    }

    @Test func ignoredAndDeletedTermsDoNotImmediatelyReturn() throws {
        try withStore { store, defaults in
            store.observeCorrections(original: "use cloud", corrected: "use Claude", source: .polish)
            store.dismissSuggestion(try #require(store.pendingCandidates.first).id)
            store.observeCorrections(original: "use cloud", corrected: "use Claude", source: .polish)
            #expect(store.pendingCandidates.isEmpty)
            let reloaded = VocabularyStore(defaults: defaults, loadRimeCache: false)
            reloaded.observeCorrections(original: "use cloud", corrected: "use Claude", source: .userCorrection)
            #expect(reloaded.entries.isEmpty)
            reloaded.add(VocabularyEntry(term: "Claude", hints: "cloud"))
            reloaded.remove(at: IndexSet(integer: 0))
            reloaded.observeCorrections(original: "use cloud", corrected: "use Claude", source: .userCorrection)
            #expect(reloaded.entries.isEmpty)
        }
    }
}
