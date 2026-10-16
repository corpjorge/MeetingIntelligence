import Foundation

public enum TextNormalization {
    /// Lowercased, accent-free, punctuation-free, single-spaced form used for
    /// evidence verification and fuzzy comparisons.
    public static func comparable(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "es_CO"))
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                scalars.append(" ")
                lastWasSpace = true
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// Word tokens of `comparable(text)`.
    public static func tokens(_ text: String) -> [String] {
        comparable(text).split(separator: " ").map(String.init)
    }

    /// Spanish + English function words ignored when turning questions into search terms.
    public static let stopwords: Set<String> = [
        // Spanish
        "a", "al", "algo", "alguna", "alguno", "ante", "como", "con", "cual", "cuales", "cuando", "de", "del",
        "desde", "donde", "dijo", "dice", "decir", "el", "ella", "ellos", "en", "entre", "era", "es", "esa", "ese",
        "eso", "esta", "este", "esto", "fue", "ha", "han", "hay", "hasta", "la", "las", "le", "les", "lo", "los",
        "mas", "me", "mi", "muy", "no", "nos", "o", "para", "pero", "por", "porque", "que", "quien", "se", "ser",
        "si", "sin", "sobre", "son", "su", "sus", "tambien", "te", "tiene", "tu", "un", "una", "uno", "unos", "unas",
        "y", "ya", "yo", "debemos", "hablo", "hablaron", "menciono", "mencionaron", "reunion", "reuniones",
        // English
        "the", "of", "and", "to", "in", "is", "it", "that", "what", "which", "who", "did", "say", "said", "about",
        "for", "on", "with", "as", "was", "were", "be", "are", "an",
    ]

    /// Light Spanish plural reduction used for prefix search, so that
    /// "iniciales" matches "inicial" and "almuerzos" matches "almuerzo".
    /// Deliberately conservative: it only shortens, so prefix matching keeps
    /// finding the plural forms too.
    public static func searchStem(_ token: String) -> String {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        if token.count > 5, token.hasSuffix("es") {
            let beforeES = token[token.index(token.endIndex, offsetBy: -3)]
            if !vowels.contains(beforeES) { return String(token.dropLast(2)) }
        }
        if token.count > 4, token.hasSuffix("s") {
            return String(token.dropLast())
        }
        return token
    }

    /// Meaningful search terms extracted from a natural-language question.
    public static func searchTerms(from question: String) -> [String] {
        var seen = Set<String>()
        return tokens(question).filter { token in
            guard token.count > 1, !stopwords.contains(token) else { return false }
            return seen.insert(token).inserted
        }
    }
}
