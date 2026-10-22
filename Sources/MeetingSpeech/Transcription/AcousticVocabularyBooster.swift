public import Foundation
import AVFoundation
@preconcurrency import FluidAudio
public import MeetingCore
import NaturalLanguage
import OSLog

/// Acoustic boosting of dictionary terms (TD-24): FluidAudio's CTC keyword
/// rescoring with Parakeet CTC 110M, run per transcript segment on its own audio.
///
/// * Output goes to `vocabularyText` only; `asrText` is never touched.
/// * The CTC model is English-trained and scores Spanish words poorly, so it
///   tends to swap common words for similar-sounding terms ("firma" → "Figma",
///   "mañana" → "Grafana"). A single word that is a word of the meeting
///   language is therefore never replaced.
/// * Never breaks processing: callers treat any error as "no boost".
public actor AcousticVocabularyBooster {
    static let variant = CtcModelVariant.ctc110m
    public static let approximateDownloadBytes: Int64 = 97_500_000

    /// One segment on the track file's own timeline, with its displayed words.
    public struct Segment: Sendable {
        public var start: Double
        public var end: Double
        public var words: [String]
        public init(start: Double, end: Double, words: [String]) {
            self.start = start
            self.end = end
            self.words = words
        }
    }

    public struct Replacement: Sendable, Hashable {
        public var original: String
        public var replacement: String
    }

    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "vocab-boost")
    private var models: CtcModels?
    private var session: (key: [String], value: VocabularyBoostingSession)?
    private var lexicons: [String: NLEmbedding] = [:]

    public init() {}

    public nonisolated var cacheDirectory: URL { CtcModels.defaultCacheDirectory(for: Self.variant) }

    public nonisolated func isModelCached() -> Bool { CtcModels.modelsExist(at: cacheDirectory) }

    public nonisolated func managedModel(inUse: Bool) -> ManagedModel {
        ManagedModel(id: "parakeet-ctc-110m", displayName: "Parakeet CTC 110M · refuerzo del diccionario",
                     repository: Self.variant.repo.remotePath, revision: .from(Self.variant.repo.revision),
                     directory: cacheDirectory,
                     unusedReason: inUse ? nil : "El refuerzo acústico del diccionario está desactivado")
    }

    /// Releases the CTC model (before an update swaps its files).
    public func unload() {
        models = nil
        session = nil
    }

    /// Downloads (first time, ~97.5 MB) and loads the CTC model.
    public func prepare() async throws {
        guard models == nil else { return }
        models = try await CtcModels.downloadAndLoad(variant: Self.variant)
    }

    /// Boosted text for each segment, nil where nothing changed.
    public func boost(_ segments: [Segment], tokens: [ASRToken], fileURL: URL, terms: [String],
                      language: String) async throws -> [String?] {
        let terms = Array(Set(terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 })).sorted()
        guard !terms.isEmpty, !segments.isEmpty else { return segments.map { _ in nil } }
        try await prepare()
        let session = try await session(for: terms)
        let lexicon = lexicon(for: language)
        let file = try AVAudioFile(forReading: fileURL)
        let converter = AudioConverter()

        var output: [String?] = []
        for segment in segments {
            try Task.checkCancellation()
            let local = tokens.filter { ($0.start + $0.end) / 2 >= segment.start - 0.05 && ($0.start + $0.end) / 2 <= segment.end + 0.05 }
            guard let first = local.first, let last = local.last else { output.append(nil); continue }
            let sliceStart = max(0, first.start - 0.3)
            let samples = try AudioSlice.samples(of: file, from: sliceStart, to: last.end + 0.3, converter: converter)
            let timings = local.map {
                TokenTiming(token: $0.piece, tokenId: $0.tokenId, startTime: $0.start - sliceStart,
                            endTime: $0.end - sliceStart, confidence: $0.confidence)
            }
            let text = local.map(\.piece).joined()
                .replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
            guard let result = await session.rescore(text: text, tokenTimings: timings, audioSamples: samples),
                  result.wasModified else { output.append(nil); continue }
            let accepted = result.replacements.compactMap { r -> Replacement? in
                guard r.shouldReplace, let term = r.replacementWord else { return nil }
                return Replacement(original: r.originalWord, replacement: term)
            }.filter { Self.isAllowed($0, isLanguageWord: { lexicon?.contains($0) ?? false }) }
            output.append(Self.apply(accepted, to: segment.words).map { $0.joined(separator: " ") })
        }
        return output
    }

    private func session(for terms: [String]) async throws -> VocabularyBoostingSession {
        if let session, session.key == terms { return session.value }
        guard let models else { throw ASRProviderError.modelUnavailable("modelo CTC no cargado") }
        let created = try await VocabularyBoostingSession(
            vocabulary: CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }), ctcModels: models)
        session = (terms, created)
        return created
    }

    private func lexicon(for language: String) -> NLEmbedding? {
        let primary = language.split(separator: "-").first.map { String($0).lowercased() } ?? language
        if let cached = lexicons[primary] { return cached }
        guard let embedding = NLEmbedding.wordEmbedding(for: NLLanguage(rawValue: primary)) else {
            logger.error("No word list for \(primary, privacy: .public): language guard disabled")
            return nil
        }
        lexicons[primary] = embedding
        return embedding
    }

    // MARK: Pure helpers (tested)

    /// Minimum spelling similarity between the replaced text and the term. Measured (TD-24):
    /// genuine fixes 0.60–1.00 ("Neki" → "Nequi", "Si Amara" → "Xiomara"); with a small dictionary
    /// the rescorer also swapped whole phrases of common words, all ≤ 0.36 ("¿Algo más?" → "Bancolombia").
    static let minSpellingSimilarity = 0.5

    /// Kept: a one-word original that is an ordinary word of the meeting language, and any
    /// original that does not look like the term. Multi-word originals that do ("Si Amara" →
    /// "Xiomara") are split renderings of the term.
    static func isAllowed(_ replacement: Replacement, isLanguageWord: (String) -> Bool) -> Bool {
        let originals = replacement.original.split(separator: " ").map { comparable(String($0)) }.filter { !$0.isEmpty }
        let term = comparable(replacement.replacement)
        // A span that already contains the term would only lose its neighbours
        // ("Jonathan, ¿puedes" → "Jonathan").
        guard !originals.isEmpty, !originals.contains(term), originals.joined() != term else { return false }
        guard spellingSimilarity(originals.joined(), term) >= minSpellingSimilarity else { return false }
        return originals.count > 1 || !isLanguageWord(originals[0])
    }

    /// 1 − Levenshtein distance / longer length, on letters and digits only.
    static func spellingSimilarity(_ a: String, _ b: String) -> Double {
        let a = Array(a.folding(options: .diacriticInsensitive, locale: nil)),
            b = Array(b.folding(options: .diacriticInsensitive, locale: nil))
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        let distance = a.isEmpty ? b.count : row[b.count]
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }

    /// Replaces the first matching word span of each replacement, keeping the
    /// span's outer punctuation ("¿Neki?" → "¿Nequi?"). Nil when nothing matched.
    static func apply(_ replacements: [Replacement], to words: [String]) -> [String]? {
        var words = words
        var changed = false
        for r in replacements {
            let target = r.original.split(separator: " ").map { comparable(String($0)) }
            guard !target.isEmpty, words.count >= target.count else { continue }
            for i in 0...(words.count - target.count)
            where (0..<target.count).allSatisfy({ comparable(words[i + $0]) == target[$0] }) {
                let prefix = String(words[i].prefix { !$0.isLetter && !$0.isNumber })
                let lastWord = words[i + target.count - 1]
                let suffix = String(lastWord.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                words.replaceSubrange(i..<(i + target.count), with: [prefix + r.replacement + suffix])
                changed = true
                break
            }
        }
        return changed ? words : nil
    }

    static func comparable(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
