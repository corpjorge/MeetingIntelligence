import Foundation
import Testing
@testable import MeetingSpeech

@Suite("Refuerzo acústico: reglas")
struct VocabularyBoostTests {
    typealias Booster = AcousticVocabularyBooster
    let spanish: Set<String> = ["mañana", "firma", "gira", "la", "vivienda", "si", "amara"]

    @Test func commonWordOfTheMeetingLanguageIsNeverReplaced() {
        let isWord: (String) -> Bool = { spanish.contains($0) }
        #expect(!Booster.isAllowed(.init(original: "Mañana", replacement: "Grafana"), isLanguageWord: isWord))
        #expect(!Booster.isAllowed(.init(original: "firma", replacement: "Figma"), isLanguageWord: isWord))
        #expect(Booster.isAllowed(.init(original: "Neki", replacement: "Nequi"), isLanguageWord: isWord))
        // A split rendering of the term is accepted even if its pieces are words.
        #expect(Booster.isAllowed(.init(original: "Si Amara", replacement: "Xiomara"), isLanguageWord: isWord))
        #expect(!Booster.isAllowed(.init(original: "katty", replacement: "Katty"), isLanguageWord: isWord))
    }

    @Test func replacementKeepsPunctuationAndTouchesOnlyTheSpan() throws {
        let words = ["Los", "pagos", "por", "¿Neki?", "Si", "Amara,", "revisa", "Neki"]
        let out = try #require(Booster.apply([.init(original: "Neki", replacement: "Nequi"),
                                              .init(original: "Si Amara", replacement: "Xiomara")], to: words))
        // First match only: the second "Neki" had no acoustic evidence of its own.
        #expect(out == ["Los", "pagos", "por", "¿Nequi?", "Xiomara,", "revisa", "Neki"])
        #expect(Booster.apply([.init(original: "Datadoc", replacement: "Datadog")], to: words) == nil)
    }
}
