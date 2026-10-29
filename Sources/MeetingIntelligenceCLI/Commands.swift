import Foundation
import GRDB
import MeetingAudio
import MeetingCore
import MeetingSemantic
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
                                diarizer: diarizer, recognizer: recognizer, booster: AcousticVocabularyBooster())
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
        let inputs = AudioDevices.inputDevices()
        for device in inputs { print("Micrófono disponible: \(device.name) [\(device.transport.rawValue)]") }
        let recommended = AudioDevices.preferredRecordingInput(defaultInput: AudioDevices.defaultInput(), devices: inputs)
        print("Micrófono recomendado para grabar sin activar Bluetooth: \(recommended?.name ?? "ninguno; elegir explícitamente")")
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
        options.acousticVocabularyBoost = args.flags.contains("boost-vocabulary")
        let summary = try await makeProcessor(database: db, paths: paths)
            .process(meetingId: meetingId, options: options, progress: progressPrinter())
        // Like the app: new segments join the semantic index when the model is present.
        let semantic = SemanticSearchEngine(modelsDirectory: paths.modelsDirectory)
        if semantic.isModelCached() { try await semantic.indexPending(database: db) }
        for t in summary.tracks {
            let rtfx = t.asrSeconds > 0 ? t.audioSeconds / t.asrSeconds : 0
            print(String(format: "%@: %.1f s audio · ASR %.2f s (RTFx %.0f×)%@ · %d palabras · %d segmentos · %d hablantes%@",
                         t.source.rawValue, t.audioSeconds, t.asrSeconds, rtfx,
                         t.diarizationSeconds.map { String(format: " · diarización %.2f s", $0) } ?? "",
                         t.words, t.segments, t.speakers,
                         t.echoSegments > 0 ? " · \(t.echoSegments) eco probable" : "")
              + (t.boostedSegments > 0 ? " · \(t.boostedSegments) segmentos con términos reforzados" : ""))
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

    static func search(_ args: Arguments, paths: AppPaths) async throws {
        let query = args.positional.joined(separator: " ")
        let db = try openDatabase(paths)
        let scope: SearchScope = args.options["meeting"].map { .meetings([$0]) } ?? .allMeetings
        let service = SearchService(reader: db.reader)
        var hits = try service.search(query, scope: scope, speakerName: args.options["speaker"])
        if let semantic = try await semanticQuery(query, args: args, paths: paths) {
            // --floor <x>: diagnostic, shows semantic hits down to that similarity with their score.
            if let floor = args.options["floor"].flatMap(Float.init) {
                for h in try service.semanticSearch(semantic, scope: scope, limit: 10, minSimilarity: floor) {
                    print(String(format: "%.3f  %@ · %@ · %@", -h.rank, h.meetingTitle, Timecode.hms(h.startTime), h.text))
                }
                return
            }
            hits = SearchService.merge(semantic: try service.semanticSearch(semantic, scope: scope), keyword: hits, limit: 50)
        }
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
        case "copilot", "copilot-cli", "github-copilot": .copilotCLI
        case "ollama": .ollama
        default: throw CLIError(message: "Indica --provider claude|codex|agy|copilot|ollama")
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
        let semantic = try await semanticQuery(question, args: args, paths: paths)
        guard let providerName = args.options["provider"] else {
            let retrieval = try chat.retrieve(question: question, scope: scope, model: nil, timeout: 60, semantic: semantic)
            try save(chat.localAnswer(question: question, retrieval: retrieval), args: args, db: db)
            if retrieval.excerpts.isEmpty { print("Sin resultados locales.") }
            for c in retrieval.excerpts { print("\(c.reference) \(c.meetingTitle) · \(Timecode.hms(c.startTime)) · \(c.speakerName): \(c.text)") }
            return
        }
        let kind = try providerKind(providerName)
        let config = try db.providerConfiguration(kind)
        let retrieval = try chat.retrieve(question: question, scope: scope, model: config.model, timeout: config.timeoutSeconds,
                                          semantic: semantic)
        print(retrieval.sharedSummary)
        if kind.sendsDataToRemoteService && !args.flags.contains("share") {
            throw CLIError(message: "No se envió nada. Repite con --share para autorizar el envío descrito arriba.")
        }
        let answer = try await chat.answer(question: question, retrieval: retrieval, provider: AIProviders.provider(for: kind),
                                           configuration: config, consentGiven: args.flags.contains("share"))
        try save(answer, args: args, db: db)
        print("\nRespuesta (IA, \(kind.displayName)): \(answer.text ?? "")")
        for c in answer.citations { print("  \(c.reference) \(c.meetingTitle) · \(Timecode.hms(c.startTime)) · \(c.speakerName): \(c.text)") }
    }

    /// `--save` keeps the question in the same chat history as the app (per meeting with `--meeting`).
    static func save(_ answer: MeetingChatService.Answer, args: Arguments, db: AppDatabase) throws {
        guard args.flags.contains("save") else { return }
        let meeting = args.options["meeting"]
        try db.appendChatMessage(ChatHistoryMessage(question: answer.question, answer: answer,
                                                    scopeMeetingIds: meeting.map { [$0] }),
                                 thread: meeting.map { .meeting($0) } ?? .library)
    }

    // MARK: models

    static func managedModels(paths: AppPaths) -> [ManagedModel] {
        [ParakeetUltraProvider().managedModel, DiarizationService().managedModel,
         AcousticVocabularyBooster().managedModel(inUse: true),
         SemanticSearchEngine(modelsDirectory: paths.modelsDirectory).managedModel(inUse: true)]
    }

    /// `mi models` lists versions (queries Hugging Face); `mi models update <id>` applies one.
    static func models(_ args: Arguments, paths: AppPaths) async throws {
        let installer = ModelInstaller()
        let models = managedModels(paths: paths)
        for model in models { installer.recoverInterrupted(model) }
        if args.positional.first == "update" {
            guard let id = args.positional.dropFirst().first, let model = models.first(where: { $0.id == id }) else {
                throw CLIError(message: "Indica el modelo: " + models.map(\.id).joined(separator: ", "))
            }
            guard case .updateAvailable(let plan) = try await installer.check(model) else {
                print("\(model.id): no hay actualización."); return
            }
            print("Descargando \(plan.changed.count) archivo(s), \(ByteCountFormatter.string(fromByteCount: plan.downloadBytes, countStyle: .file))")
            let staging = try await installer.stage(model, plan: plan) { _, _ in }
            try installer.swapIn(model, staging: staging)
            do {
                switch model.id {
                case "parakeet-ultra": try await ParakeetUltraProvider().prepare { _ in }
                case "parakeet-ctc-110m": try await AcousticVocabularyBooster().prepare()
                case "multilingual-e5-small": try await SemanticSearchEngine(modelsDirectory: paths.modelsDirectory).prepare()
                default: try await DiarizationService().prepare()
                }
                installer.commit(model)
                print("\(model.id): actualizado a \(plan.revision.prefix(7)) y verificado.")
            } catch {
                try installer.rollback(model)
                throw CLIError(message: "La versión nueva no cargó; se restauró la anterior: \(error.localizedDescription)")
            }
            return
        }
        for model in models {
            let size = ByteCountFormatter.string(fromByteCount: StorageMaintenance.size(of: model.directory), countStyle: .file)
            let state: String
            do {
                switch try await installer.check(model) {
                case .notInstalled: state = "no descargado"
                case .upToDate(let revision): state = "al día (\(revision.prefix(7)))"
                case .pinned(let revision): state = "fijado por FluidAudio (\(revision.prefix(7)))"
                case .updateAvailable(let plan):
                    state = "actualización: \(plan.changed.count) archivo(s), "
                        + ByteCountFormatter.string(fromByteCount: plan.downloadBytes, countStyle: .file)
                        + (plan.obsolete.isEmpty ? "" : ", \(plan.obsolete.count) obsoleto(s)")
                }
            } catch {
                state = "error: \(error.localizedDescription)"
            }
            print("\(model.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(state)")
        }
        let root = ParakeetUltraProvider().cacheDirectory.deletingLastPathComponent()
        let used = Set(models.prefix(3).map(\.directory))
        for folder in ModelInventory.unusedFolders(in: root, used: used) {
            print("sin uso: \(folder.url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: folder.bytes, countStyle: .file)))")
        }
    }

    // MARK: semantic search

    /// Query vector when `--semantic` is given (the model must be downloaded: `mi semantic-index`).
    static func semanticQuery(_ text: String, args: Arguments, paths: AppPaths) async throws -> SemanticQuery? {
        guard args.flags.contains("semantic") else { return nil }
        let engine = SemanticSearchEngine(modelsDirectory: paths.modelsDirectory)
        guard engine.isModelCached() else {
            throw CLIError(message: "El modelo semántico no está descargado. Ejecuta: mi semantic-index")
        }
        return try await engine.embedQuery(text)
    }

    static func semanticIndex(paths: AppPaths) async throws {
        let db = try openDatabase(paths)
        let engine = SemanticSearchEngine(modelsDirectory: paths.modelsDirectory)
        if !engine.isModelCached() {
            print("Descargando \(SemanticSearchEngine.modelId) (~470 MB, una sola vez) en \(paths.modelsDirectory.path)")
        }
        let started = Date()
        try await engine.prepare()
        print(String(format: "Modelo listo en %.1f s", Date().timeIntervalSince(started)))
        let indexStart = Date()
        let count = try await engine.indexPending(database: db)
        let coverage = try db.semanticIndexCoverage(model: SemanticSearchEngine.modelId)
        print(String(format: "%d fragmentos indexados en %.1f s · cobertura %d/%d", count,
                     Date().timeIntervalSince(indexStart), coverage.indexed, coverage.total))
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
