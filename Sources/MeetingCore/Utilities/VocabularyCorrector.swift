import Foundation

/// Deterministic custom-dictionary pass applied after ASR.
///
/// Replaces whole-word occurrences of known misrecognitions (and wrong casing
/// of the canonical form) with the canonical spelling. Matching is case- and
/// accent-insensitive; the raw ASR text is preserved separately by callers.
public struct VocabularyCorrector: Sendable {
    public struct Replacement: Sendable, Hashable {
        public let from: String
        public let to: String
    }

    private let rules: [(pattern: String, canonical: String)]

    public init(terms: [VocabularyTerm]) {
        var rules: [(String, String)] = []
        for term in terms {
            let canonical = term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }
            for variant in term.variants + [canonical] {
                let v = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { rules.append((v, canonical)) }
            }
        }
        // Longest patterns first so multi-word variants win over their parts.
        self.rules = rules.sorted { $0.0.count > $1.0.count }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// Returns the corrected text, or nil when nothing changed.
    public func apply(to text: String) -> (text: String, replacements: [Replacement])? {
        guard !rules.isEmpty else { return nil }
        var result = text
        var applied: [Replacement] = []
        for rule in rules {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result.range(of: rule.pattern,
                                           options: [.caseInsensitive, .diacriticInsensitive],
                                           range: searchStart..<result.endIndex,
                                           locale: Locale(identifier: "es_CO")) {
                let found = String(result[range])
                if Self.isWordBoundary(in: result, before: range.lowerBound),
                   Self.isWordBoundary(in: result, after: range.upperBound),
                   found != rule.canonical {
                    result.replaceSubrange(range, with: rule.canonical)
                    applied.append(Replacement(from: found, to: rule.canonical))
                    let offset = result.distance(from: result.startIndex, to: range.lowerBound) + rule.canonical.count
                    searchStart = result.index(result.startIndex, offsetBy: offset)
                } else {
                    searchStart = range.upperBound
                }
            }
        }
        return applied.isEmpty ? nil : (result, applied)
    }

    private static func isWordBoundary(in text: String, before index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        return !isWordCharacter(text[text.index(before: index)])
    }

    private static func isWordBoundary(in text: String, after index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        return !isWordCharacter(text[index])
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
