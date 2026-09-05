import Foundation

/// Decides whether a review-box edit looks like a single mishearing
/// correction worth folding into the vocabulary automatically, as opposed to
/// a larger rewrite (added content, restructured sentences) that would just
/// pollute it. Deliberately conservative: false negatives (a real correction
/// that doesn't get learned) are harmless, false positives (garbage added to
/// the vocabulary) are not.
enum CorrectionLearner {
    /// Neither side of a genuine word/phrase substitution is usually longer
    /// than this — well past it, and it stopped being a single term.
    private static let maxTermLength = 16

    struct Candidate: Equatable {
        let oldTerm: String
        let newTerm: String
    }

    /// Finds the changed middle between two strings by stripping their
    /// common prefix and suffix. Returns `nil` when the edit isn't a small,
    /// bounded substitution — e.g. one side is empty (pure insertion/
    /// deletion, not a correction) or either side is too long (a rewrite,
    /// not a term swap).
    static func detectSubstitution(original: String, corrected: String) -> Candidate? {
        guard original != corrected else { return nil }

        let a = Array(original)
        let b = Array(corrected)

        var prefixLen = 0
        while prefixLen < a.count, prefixLen < b.count, a[prefixLen] == b[prefixLen] {
            prefixLen += 1
        }

        var suffixLen = 0
        while suffixLen < a.count - prefixLen,
              suffixLen < b.count - prefixLen,
              a[a.count - 1 - suffixLen] == b[b.count - 1 - suffixLen] {
            suffixLen += 1
        }

        let oldMiddle = String(a[prefixLen..<(a.count - suffixLen)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newMiddle = String(b[prefixLen..<(b.count - suffixLen)])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !oldMiddle.isEmpty, !newMiddle.isEmpty else { return nil }
        guard oldMiddle.count <= maxTermLength, newMiddle.count <= maxTermLength else { return nil }

        return Candidate(oldTerm: oldMiddle, newTerm: newMiddle)
    }
}
