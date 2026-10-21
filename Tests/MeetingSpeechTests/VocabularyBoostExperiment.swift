import FluidAudio
import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

/// Measurement only (TD-24): FluidAudio CTC vocabulary rescoring on Spanish speech.
/// Runs when `MI_BOOST_DATA` points to a folder with `data/*.wav` + `.txt` references
/// and `terms.txt`; writes `report-<mode>.txt` there. Downloads Parakeet CTC 110M on first run.
@Suite("Experimento: refuerzo acústico de vocabulario",
       .enabled(if: ProcessInfo.processInfo.environment["MI_BOOST_DATA"] != nil), .serialized)
struct VocabularyBoostExperiment {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MI_BOOST_DATA"] ?? "/nonexistent")

    @Test(arguments: ["default"])
    func measure(mode: String) async throws {
        let terms = try String(contentsOf: root.appendingPathComponent("terms.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let models = try await ParakeetUltraProvider().loadedModels()
        let version = ParakeetUltraProvider.modelVersion
        let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId),
                                                   encoderHiddenSize: version.encoderHiddenSize))
        try await manager.loadModels(models)
        let ctc = try await CtcModels.downloadAndLoad()
        let config = mode == "noRescue" ? VocabularyRescorer.Config(spotterRescueEnabled: false) : nil
        let session = try await VocabularyBoostingSession(
            vocabulary: CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }),
            ctcModels: ctc, config: config)

        let converter = AudioConverter()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("data"),
                                                                 includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []
        var baseHits = 0, boostHits = 0, termSentences = 0
        var baseErrors = 0, boostErrors = 0, refWords = 0
        var controlChanged = 0, controls = 0, brokenCorrect = 0
        for wav in files {
            let reference = try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let samples = try converter.resampleAudioFile(wav)
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(samples, decoderState: &state,
                                                      language: ParakeetUltraProvider.fluidLanguage(for: "es-CO"))
            let output = await session.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [],
                                               audioSamples: samples)
            let boosted = output?.text ?? result.text
            let base = Metrics.wordErrorRate(reference: reference, hypothesis: result.text)
            let boost = Metrics.wordErrorRate(reference: reference, hypothesis: boosted)
            refWords += base.referenceWords
            baseErrors += base.substitutions + base.deletions + base.insertions
            boostErrors += boost.substitutions + boost.deletions + boost.insertions
            let term = terms.first { TextNormalization.comparable(reference).contains(TextNormalization.comparable($0)) }
            if let term {
                termSentences += 1
                let hitBase = TextNormalization.comparable(result.text).contains(TextNormalization.comparable(term))
                let hitBoost = TextNormalization.comparable(boosted).contains(TextNormalization.comparable(term))
                if hitBase { baseHits += 1 }
                if hitBoost { boostHits += 1 }
                if hitBase && !hitBoost { brokenCorrect += 1 }
            } else {
                controls += 1
                if TextNormalization.comparable(boosted) != TextNormalization.comparable(result.text) { controlChanged += 1 }
            }
            let words = WordGrouping.words(from: (result.tokenTimings ?? []).map { ($0.token, $0.startTime, $0.endTime, $0.confidence) })
            for r in output?.replacements ?? [] where r.shouldReplace {
                let originals = r.originalWord.split(separator: " ").map { TextNormalization.comparable(String($0)) }
                let conf = words.filter { originals.contains(TextNormalization.comparable($0.word)) }.compactMap(\.confidence)
                lines.append(String(format: "  REPL %@ | '%@' → '%@' conf=%.2f orig=%.2f repl=%.2f %@", wav.lastPathComponent,
                                    r.originalWord, r.replacementWord ?? "", conf.isEmpty ? -1 : conf.min()!,
                                    r.originalScore, r.replacementScore ?? 0, r.reason))
            }
            lines.append("\(wav.lastPathComponent) | ref: \(reference)\n    base:  \(result.text)\n    boost: \(boosted)"
                         + (output?.detectedTerms.isEmpty == false ? "  [detectados: \(output!.detectedTerms.joined(separator: ", "))]" : ""))
        }
        let summary = """
        modo=\(mode)
        términos acertados: base \(baseHits)/\(termSentences) · refuerzo \(boostHits)/\(termSentences) · rotos por el refuerzo \(brokenCorrect)
        WER total: base \(String(format: "%.1f", 100 * Double(baseErrors) / Double(max(1, refWords))))% · refuerzo \(String(format: "%.1f", 100 * Double(boostErrors) / Double(max(1, refWords))))%
        frases de control modificadas: \(controlChanged)/\(controls)
        """
        try (summary + "\n\n" + lines.joined(separator: "\n")).write(
            to: root.appendingPathComponent("report-\(mode).txt"), atomically: true, encoding: .utf8)
    }
}
