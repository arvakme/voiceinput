import Foundation

/// Extracts bounded term substitutions, preserving whole Latin identifiers.
/// Unchanged words separate edits, so several fixes in one sentence can learn
/// independently. Pure insertions, deletions and prose rewrites are not terms.
enum CorrectionLearner {
    struct Candidate: Equatable {
        let oldTerm: String
        let newTerm: String

        /// CJK substitutions are offered for confirmation: spelling alone
        /// cannot tell a proper name from an ordinary Chinese phrase.
        var canLearnAutomatically: Bool {
            newTerm.unicodeScalars.allSatisfy { $0.isASCII }
        }
    }

    static func detectSubstitution(original: String, corrected: String) -> Candidate? {
        let candidates = detectSubstitutions(original: original, corrected: corrected)
        return candidates.count == 1 ? candidates.first : nil
    }

    static func detectSubstitutions(original: String, corrected: String) -> [Candidate] {
        guard original != corrected, original.count <= 4000, corrected.count <= 4000 else { return [] }
        let a = tokens(original)
        let b = tokens(corrected)
        guard a.count <= 512, b.count <= 512 else { return [] }
        // LCS over words/punctuation, not characters: Claude never becomes a
        // stray "au"/"ou" fragment after a common-prefix/suffix diff.
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                lengths[i][j] = a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var i = 0, j = 0
        var old = "", new = ""
        var result: [Candidate] = []
        func flush() {
            if let candidate = candidate(old: old, new: new), !result.contains(candidate) {
                result.append(candidate)
            }
            old = ""
            new = ""
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                if a[i].allSatisfy({ $0.isWhitespace }), !old.isEmpty || !new.isEmpty {
                    old += a[i]
                    new += b[j]
                } else {
                    flush()
                }
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lengths[i][j + 1] >= lengths[i + 1][j] {
                new += b[j]
                j += 1
            } else {
                old += a[i]
                i += 1
            }
        }
        flush()
        return Array(result.prefix(12))
    }

    private static func tokens(_ text: String) -> [String] {
        // Keep CJK runs intact rather than learning a lone changed character.
        let pattern = #"[A-Za-z0-9_+#]+(?:[.-][A-Za-z0-9_+#]+)*|[\p{Han}]+|\s+|[^\s]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func candidate(old: String, new: String) -> Candidate? {
        let boundaries = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",.!?;:，。！？；：“”\"'()"))
        let old = old.trimmingCharacters(in: boundaries)
        let new = new.trimmingCharacters(in: boundaries)
        guard old.count >= 2, new.count >= 2, old.count <= 48, new.count <= 48,
              old != new, !old.contains("\n"), !new.contains("\n") else { return nil }
        let words = new.split(whereSeparator: \.isWhitespace)
        guard words.count <= 4 else { return nil }
        if new.unicodeScalars.allSatisfy({ $0.isASCII }) {
            guard new.range(of: #"^[A-Za-z][A-Za-z0-9_+#. -]*$"#, options: .regularExpression) != nil,
                  new.range(of: #"[A-Z_+#]|[a-z][0-9]|[a-z][A-Z]"#, options: .regularExpression) != nil else { return nil }
            let common: Set<String> = ["i", "a", "an", "the", "this", "that", "these", "those", "it", "we", "you", "he", "she", "they", "please", "thanks", "thank", "hello", "hi", "yes", "no", "new", "old", "good", "bad", "and", "or", "but", "use", "using", "make", "fix", "add", "remove", "delete", "update", "change", "create", "open", "close", "start", "stop", "today", "tomorrow", "now", "later"]
            guard words.allSatisfy({ !common.contains($0.lowercased()) }) else { return nil }
            // A sentence-initial case adjustment alone isn't a vocabulary fix.
            if old.lowercased() == new.lowercased(), new != new.uppercased() { return nil }
        } else {
            guard new.count <= 8, old.count <= 8,
                  new.unicodeScalars.allSatisfy({ (0x3400...0x9FFF).contains($0.value) }) else { return nil }
        }
        return Candidate(oldTerm: old, newTerm: new)
    }
}
