import FluidAudio
import Foundation
import NaturalLanguage
import Testing
@testable import MeetingCore
@testable import MeetingSpeech

/// Measurement only (TD-22 follow-up): short isolated Spanish replies decoded alone vs.
/// re-decoded after earlier Spanish speech. Runs when `MI_LANG_DATA` has `data/*.wav|txt`
/// and `ctx/v<N>.wav`; writes `report.txt` there.
@Suite("Experimento: idioma de frases cortas",
       .enabled(if: ProcessInfo.processInfo.environment["MI_LANG_DATA"] != nil), .serialized)
struct LanguageDriftExperiment {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MI_LANG_DATA"] ?? "/nonexistent")

    @Test func measure() async throws {
        let provider = ParakeetUltraProvider()
        let models = try await provider.loadedModels()
        let version = ParakeetUltraProvider.modelVersion
        let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId),
                                                   encoderHiddenSize: version.encoderHiddenSize))
        try await manager.loadModels(models)
        let converter = AudioConverter()
        let language = ParakeetUltraProvider.fluidLanguage(for: "es-CO")
        func decode(_ samples: [Float]) async throws -> [TokenTiming] {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            return try await manager.transcribe(samples, decoderState: &state, language: language).tokenTimings ?? []
        }
        func text(_ tokens: [TokenTiming]) -> String {
            tokens.map(\.token).joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
        }
        func ok(_ hyp: String, _ ref: String) -> Bool { TextNormalization.comparable(hyp) == TextNormalization.comparable(ref) }
        func detected(_ s: String) -> (NLLanguage?, Double) {
            let r = NLLanguageRecognizer()
            r.languageConstraints = [.spanish, .english, .german, .french, .portuguese, .italian, .russian, .catalan]
            r.processString(s)
            let top = r.languageHypotheses(withMaximum: 1).first
            return (top?.key, top?.value ?? 0)
        }

        let contexts = try (1...4).map { try converter.resampleAudioFile(root.appendingPathComponent("ctx/v\($0).wav")) }
        let gap = [Float](repeating: 0, count: 9_600) // 0.6 s
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("data"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        struct Row { var group: String; var base: Bool; var same: Bool; var other: Bool; var flagged: Bool; var confPick: Bool }
        var rows: [Row] = []
        var lines: [String] = []
        for wav in files {
            let ref = try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let voice = Int(wav.lastPathComponent.dropFirst().prefix(1))!
            let first = try await provider.transcribe(fileURL: wav, languageHint: "es-CO") { _ in }
            let all = try converter.resampleAudioFile(wav)
            var sameText = "", otherText = "", sameConf: Float = 0
            if let start = first.tokens.first?.start, let end = first.tokens.last?.end {
                let a = max(0, Int((start - 0.3) * 16_000)), b = min(all.count, Int((end + 0.3) * 16_000))
                let phrase = Array(all[a..<b])
                for (ctx, slot) in [(contexts[voice - 1], 0), (contexts[voice % 4], 1)] {
                    let boundary = Double(ctx.count + gap.count) / 16_000 - 0.15
                    let tokens = try await decode(ctx + gap + phrase).filter { $0.startTime >= boundary }
                    if slot == 0 {
                        sameText = text(tokens)
                        sameConf = tokens.isEmpty ? 0 : tokens.map(\.confidence).reduce(0, +) / Float(tokens.count)
                    } else { otherText = text(tokens) }
                }
            }
            let (lang, p) = detected(first.text)
            let baseConf = first.tokens.isEmpty ? 0 : first.tokens.map(\.confidence).reduce(0, +) / Float(first.tokens.count)
            rows.append(Row(group: wav.lastPathComponent.contains("_e") ? "inglés" : "español",
                            base: ok(first.text, ref), same: ok(sameText, ref), other: ok(otherText, ref),
                            flagged: lang != nil && lang != .spanish,
                            confPick: ok(sameConf >= baseConf ? sameText : first.text, ref)))
            lines.append("\(wav.lastPathComponent) | \(ref)\n   base: \(first.text) [\(lang?.rawValue ?? "?") \(String(format: "%.2f", p)) conf \(String(format: "%.2f", baseConf))] ctx conf \(String(format: "%.2f", sameConf))"
                         + "\n   ctx misma voz: \(sameText)\n   ctx otra voz: \(otherText)")
        }
        var summary = ""
        for group in ["español", "inglés"] {
            let g = rows.filter { $0.group == group }
            func n(_ f: (Row) -> Bool) -> Int { g.filter(f).count }
            summary += """
            [\(group)] frases \(g.count) · exactas: base \(n(\.base)) · ctx misma voz \(n(\.same)) · ctx otra voz \(n(\.other))
              base bien→ctx mal: \(n { $0.base && !$0.same }) · base mal→ctx bien: \(n { !$0.base && $0.same })
              elegir mayor confianza: \(n(\.confPick)) · solo si el detector ≠ es: \(n { $0.flagged ? $0.same : $0.base })
              detector ≠ es: \(n { !$0.base && $0.flagged })/\(n { !$0.base }) erróneas · \(n { $0.base && $0.flagged })/\(n(\.base)) correctas

            """
        }
        try (summary + "\n\n" + lines.joined(separator: "\n")).write(to: root.appendingPathComponent("report.txt"),
                                                                    atomically: true, encoding: .utf8)
    }
}
