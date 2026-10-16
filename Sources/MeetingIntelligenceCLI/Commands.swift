import Foundation
import GRDB
import MeetingAudio
import MeetingCore
import MeetingSpeech

enum Commands {
    static func openDatabase(_ paths: AppPaths) throws -> AppDatabase {
        try AppDatabase.open(paths: paths)
    }

    static func makeProcessor(database: AppDatabase, paths: AppPaths) -> MeetingProcessor {
        let diarizer = DiarizationService()
        let recognizer = SpeakerRecognitionService(
            database: database, vault: BiometricVault(keyProvider: KeychainBiometricKeyProvider()), diarizer: diarizer)
        return MeetingProcessor(database: database, paths: paths, asr: ParakeetUltraProvider(),
                                diarizer: diarizer, recognizer: recognizer)
    }

    static func progressPrinter() -> @Sendable (PipelineProgress) -> Void {
        let last = LockedBox<String>("")
        return { p in
            let pct = p.fraction.map { String(format: " %3.0f%%", $0 * 100) } ?? ""
            let line = "[\(p.stage.rawValue)]\(pct) \(p.message)"
            if last.swap(line) != line { printErr(line) }
        }
    }

    // MARK: doctor

    static func doctor(paths: AppPaths) async throws {
        let info = ProcessInfo.processInfo
        print("== Sistema")
        print("macOS \(info.operatingSystemVersionString) · \(info.processorCount) núcleos · \(info.physicalMemory / 1_073_741_824) GB RAM")
        print("Biblioteca: \(paths.root.path)")
        print("\n== Modelos")
        let asr = ParakeetUltraProvider()
        print("Parakeet Ultra en caché: \(await asr.isModelCached() ? "sí" : "no") (\(asr.cacheDirectory.path))")
        print("Diarización en caché: \(await DiarizationService().isModelCached() ? "sí" : "no")")
        print("\n== Audio")
        if let input = AudioDevices.defaultInput() {
            print("Entrada: \(input.name) [\(input.transport.rawValue)] \(input.nominalSampleRate.map { "\(Int($0)) Hz" } ?? "")")
        } else {
            print("Entrada: ninguna")
        }
        if let output = AudioDevices.defaultOutput() {
            print("Salida: \(output.name) [\(output.transport.rawValue)] fuente=\(output.dataSourceName ?? "-") riesgo de eco=\(output.isLikelySpeakers ? "sí" : "no")")
        }
        print("Permiso de micrófono: \(RecordingSession.microphonePermissionGranted() ? "concedido" : "no concedido (se solicitará en la app)")")
        let apps = AudioApplicationResolver.currentApplications()
        print("Apps registradas en el audio del sistema: \(apps.count)")
        for app in apps {
            let state = app.isUsingInput && app.isUsingOutput ? "posible llamada"
                : (app.isUsingOutput ? "reproduce audio" : (app.isUsingInput ? "usa el micrófono" : "inactiva"))
            print("  · \(app.name) [\(app.kind.rawValue)\(app.isolation == .shared ? ", audio compartido" : "")] \(state) · \(app.processes.count) proceso(s)")
        }
    }

    // MARK: import / process

    static func importFile(_ args: Arguments, paths: AppPaths) async throws {
        guard let file = args.positional.first else { throw CLIError(message: "Falta el archivo a importar.") }
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let db = try openDatabase(paths)
        let meeting = try await MeetingImportService(database: db, paths: paths)
            .importAudio(at: url, title: args.options["title"])
        print("Reunión creada: \(meeting.id) — \(meeting.title) (\(Timecode.humanDuration(meeting.durationSeconds)))")
        guard !args.flags.contains("no-process") else { return }
        try await runProcessing(meetingId: meeting.id, args: args, db: db, paths: paths)
    }

    static func process(_ args: Arguments, paths: AppPaths) async throws {
        guard let id = args.positional.first else { throw CLIError(message: "Falta el ID de la reunión.") }
        try await runProcessing(meetingId: id, args: args, db: try openDatabase(paths), paths: paths)
    }

    static func runProcessing(meetingId: String, args: Arguments, db: AppDatabase, paths: AppPaths) async throws {
        var options = ProcessingOptions()
        options.diarize = !args.flags.contains("no-diarize")
        options.detectMultipleLocalSpeakers = !args.flags.contains("no-local-diarization")
        let summary = try await makeProcessor(database: db, paths: paths)
            .process(meetingId: meetingId, options: options, progress: progressPrinter())
        for t in summary.tracks {
            let rtfx = t.asrSeconds > 0 ? t.audioSeconds / t.asrSeconds : 0
            print(String(format: "%@: %.1f s audio · ASR %.2f s (RTFx %.0f×)%@ · %d palabras · %d segmentos · %d hablantes%@",
                         t.source.rawValue, t.audioSeconds, t.asrSeconds, rtfx,
                         t.diarizationSeconds.map { String(format: " · diarización %.2f s", $0) } ?? "",
                         t.words, t.segments, t.speakers,
                         t.echoSegments > 0 ? " · \(t.echoSegments) eco probable" : ""))
        }
        print(String(format: "Total: %.2f s", summary.totalSeconds))
        try show(Arguments([meetingId]), paths: paths)
    }

    // MARK: list / show / search

    static func list(paths: AppPaths) throws {
        let rows = try openDatabase(paths).meetingRows()
        if rows.isEmpty { print("No hay reuniones."); return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for r in rows {
            print("\(r.meeting.id)  \(formatter.string(from: r.meeting.displayDate))  \(r.meeting.status.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(Timecode.compact(r.meeting.durationSeconds).padding(toLength: 8, withPad: " ", startingAt: 0)) \(r.meeting.title)")
        }
    }

    static func show(_ args: Arguments, paths: AppPaths) throws {
        guard let id = args.positional.first else { throw CLIError(message: "Falta el ID de la reunión.") }
        guard let detail = try openDatabase(paths).meetingDetail(id: id) else {
            throw CLIError(message: "No existe la reunión \(id).")
        }
        print("\n# \(detail.meeting.title)  [\(detail.meeting.status.rawValue)]")
        for track in detail.tracks {
            print("pista \(track.source.rawValue): \(Timecode.compact(track.durationSeconds)) \(track.captureDetail ?? "")")
        }
        print("")
        for seg in detail.segments {
            let tag: String = switch seg.attribution {
            case .probableEcho: " (eco probable)"
            case .uncertain: " (?)"
            case .suggested: " (sugerido)"
            default: ""
            }
            let edited = seg.textOrigin == .asr ? "" : " ✎"
            print("[\(Timecode.hms(seg.startTime))] \(detail.speakerName(for: seg))\(tag): \(seg.displayText)\(edited)")
        }
    }

    static func search(_ args: Arguments, paths: AppPaths) throws {
        let query = args.positional.joined(separator: " ")
        let db = try openDatabase(paths)
        let scope: SearchScope = args.options["meeting"].map { .meetings([$0]) } ?? .allMeetings
        let hits = try SearchService(reader: db.reader).search(query, scope: scope, speakerName: args.options["speaker"])
        if hits.isEmpty { print("Sin resultados."); return }
        for h in hits {
            print("\(h.meetingTitle) · \(Timecode.hms(h.startTime)) · \(h.speakerName)\n   \(h.snippet)")
        }
    }

    // MARK: export

    static func export(_ args: Arguments, paths: AppPaths) throws {
        guard let id = args.positional.first else { throw CLIError(message: "Falta el ID de la reunión.") }
        guard let format = ExportFormat(rawValue: args.options["format"] ?? "markdown") else {
            throw CLIError(message: "Formato inválido. Usa: " + ExportFormat.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let db = try openDatabase(paths)
        guard let meeting = try db.meeting(id: id) else { throw CLIError(message: "No existe la reunión \(id).") }
        let out = args.options["out"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? paths.exportsDirectory.appendingPathComponent(MeetingExporter.suggestedFileName(for: meeting, format: format))
        try MeetingExporter(database: db).export(meetingId: id, format: format, to: out)
        print("Exportado: \(out.path)")
    }

    // MARK: AI

    static func providerKind(_ raw: String?) throws -> AIProviderKind {
        switch raw?.lowercased() {
        case "claude", "claudecode", "claude-code": .claudeCode
        case "codex": .codex
        case "agy", "antigravity": .antigravity
        case "ollama": .ollama
        default: throw CLIError(message: "Indica --provider claude|codex|agy|ollama")
        }
    }

    static func aiProviders(paths: AppPaths) async {
        let db = try? openDatabase(paths)
        for kind in AIProviderKind.allCases {
            let config = (try? db?.providerConfiguration(kind)) ?? AIProviderConfiguration(provider: kind)
            let s = await AIProviders.provider(for: kind).detect(configuration: config)
            print("\(kind.displayName): \(s.installed ? "instalado" : "no instalado")"
                  + (s.version.map { " · \($0)" } ?? "")
                  + (s.authenticated.map { $0 ? " · sesión activa" : " · SIN sesión" } ?? "")
                  + (s.models.isEmpty ? "" : " · modelos: \(s.models.prefix(6).joined(separator: ", "))")
                  + (s.effortLevels.isEmpty ? "" : " · esfuerzo: \(s.effortLevels.joined(separator: "/"))")
                  + (kind.sendsDataToRemoteService ? " · NUBE" : " · LOCAL"))
            if let detail = s.authDetail { print("   \(detail)") }
            if let path = s.executablePath { print("   \(path)") }
        }
    }

    static func analyze(_ args: Arguments, paths: AppPaths) async throws {
        guard let id = args.positional.first else { throw CLIError(message: "Falta el ID de la reunión.") }
        let kind = try providerKind(args.options["provider"])
        let db = try openDatabase(paths)
        var config = try db.providerConfiguration(kind)
        if let model = args.options["model"] { config.model = model }
        if let effort = args.options["effort"] { config.effort = effort }
        let service = MeetingAnalysisService(database: db)
        let prepared = try service.prepare(meetingId: id, model: config.model, effort: config.effort, timeout: config.timeoutSeconds)
        print("Proveedor: \(kind.displayName) (\(kind.sendsDataToRemoteService ? "nube" : "local"))")
        print(prepared.sharedSummary)
        if kind.sendsDataToRemoteService && !args.flags.contains("share") {
            throw CLIError(message: "No se envió nada. Repite con --share para autorizar el envío descrito arriba.")
        }
        let analysis = try await service.run(meetingId: id, provider: AIProviders.provider(for: kind), configuration: config,
                                             prepared: prepared, consentGiven: args.flags.contains("share"))
        print(String(format: "\nAnálisis %@ · modelo %@ · esfuerzo %@ · %.1f s", analysis.status.rawValue,
                     analysis.model ?? "?", analysis.effort ?? "predeterminado", analysis.durationSeconds ?? 0))
        print("\nResumen ejecutivo (IA): \(analysis.executiveSummary ?? "")")
        let items = try await db.reader.read { db in
            try AnalysisItem.filter(Column("analysisId") == analysis.id).order(Column("orderIndex")).fetchAll(db)
        }
        for item in items {
            let evidence = item.evidenceStatus == .verified
                ? "[\(item.evidenceStartTime.map(Timecode.hms) ?? "")] \(item.evidenceSpeakerName ?? ""): “\(item.evidenceQuote ?? "")”"
                : "Información no confirmada"
            print("- [\(item.category.rawValue)/\(item.nature.rawValue)] \(item.text)"
                  + (item.ownerName.map { " — \($0)" } ?? "") + (item.dueText.map { " (\($0))" } ?? "") + "\n    \(evidence)")
        }
    }

    static func ask(_ args: Arguments, paths: AppPaths) async throws {
        let question = args.positional.joined(separator: " ")
        let db = try openDatabase(paths)
        let scope: SearchScope = args.options["meeting"].map { .meetings([$0]) } ?? .allMeetings
        let chat = MeetingChatService(database: db)
        guard let providerName = args.options["provider"] else {
            let retrieval = try chat.retrieve(question: question, scope: scope, model: nil, timeout: 60)
            if retrieval.excerpts.isEmpty { print("Sin resultados locales.") }
            for c in retrieval.excerpts { print("\(c.reference) \(c.meetingTitle) · \(Timecode.hms(c.startTime)) · \(c.speakerName): \(c.text)") }
            return
        }
        let kind = try providerKind(providerName)
        let config = try db.providerConfiguration(kind)
        let retrieval = try chat.retrieve(question: question, scope: scope, model: config.model, timeout: config.timeoutSeconds)
        print(retrieval.sharedSummary)
        if kind.sendsDataToRemoteService && !args.flags.contains("share") {
            throw CLIError(message: "No se envió nada. Repite con --share para autorizar el envío descrito arriba.")
        }
        let answer = try await chat.answer(question: question, retrieval: retrieval, provider: AIProviders.provider(for: kind),
                                           configuration: config, consentGiven: args.flags.contains("share"))
        print("\nRespuesta (IA, \(kind.displayName)): \(answer.text ?? "")")
        for c in answer.citations { print("  \(c.reference) \(c.meetingTitle) · \(Timecode.hms(c.startTime)) · \(c.speakerName): \(c.text)") }
    }

    // MARK: evaluate

    static func evaluate(_ args: Arguments) async throws {
        guard let file = args.positional.first else { throw CLIError(message: "Falta el archivo de audio.") }
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let asr = ParakeetUltraProvider()
        let prepStart = Date()
        try await asr.prepare { _ in }
        print(String(format: "Preparación del modelo: %.2f s", Date().timeIntervalSince(prepStart)))
        let result = try await asr.transcribe(fileURL: url, languageHint: "es-CO") { _ in }
        print(String(format: "Audio: %.2f s · ASR: %.3f s · RTFx: %.1f×", result.audioDurationSeconds,
                     result.processingSeconds, result.audioDurationSeconds / max(0.001, result.processingSeconds)))
        print("Hipótesis: \(result.text)")
        if let refPath = args.options["reference"] {
            let reference = try String(contentsOfFile: (refPath as NSString).expandingTildeInPath, encoding: .utf8)
            let wer = Metrics.wordErrorRate(reference: reference, hypothesis: result.text)
            print(String(format: "WER: %.2f%% (S=%d D=%d I=%d, N=%d)", wer.wer * 100, wer.substitutions,
                         wer.deletions, wer.insertions, wer.referenceWords))
        }
        guard !args.flags.contains("no-diarize") else { return }
        let diarizer = DiarizationService()
        try await diarizer.prepare()
        let output = try await diarizer.diarize(fileURL: url) { _ in }
        print(String(format: "Diarización: %.3f s · %d turnos · %d hablantes", output.processingSeconds,
                     output.turns.count, Set(output.turns.map(\.clusterKey)).count))
        for t in output.turns {
            print(String(format: "  %@ %7.2f – %7.2f", t.clusterKey, t.start, t.end))
        }
        if let rttm = args.options["rttm"] {
            let reference = try RTTM.parse(String(contentsOfFile: (rttm as NSString).expandingTildeInPath, encoding: .utf8))
            let der = Metrics.diarizationErrorRate(
                reference: reference,
                hypothesis: output.turns.map { .init(speaker: $0.clusterKey, start: $0.start, end: $0.end) })
            print(String(format: "DER: %.2f%% (perdido %.2f s, falsa alarma %.2f s, confusión %.2f s, referencia %.2f s)",
                         der.der * 100, der.missed, der.falseAlarm, der.confusion, der.totalReference))
        }
    }
}

enum RTTM {
    static func parse(_ text: String) -> [Metrics.SpeakerTurn] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 8, f[0] == "SPEAKER", let start = Double(f[3]), let dur = Double(f[4]) else { return nil }
            return Metrics.SpeakerTurn(speaker: String(f[7]), start: start, end: start + dur)
        }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func swap(_ new: T) -> T { lock.withLock { let old = value; value = new; return old } }
}
