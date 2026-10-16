import Foundation
public import GRDB

public struct MCPToolError: Error, Sendable {
    public let message: String
    init(_ message: String) { self.message = message }
}

/// Read-only tools exposed over MCP. Never returns audio, file paths of
/// recordings, or biometric data. Respects `MCPAccessPolicy` on every call.
public struct MCPTools: Sendable {
    public struct Output {
        public var text: String
        public var structured: Any
    }

    private let reader: any DatabaseReader
    private let policyProvider: @Sendable () -> MCPAccessPolicy

    public init(reader: any DatabaseReader, policy: @escaping @Sendable () -> MCPAccessPolicy) {
        self.reader = reader
        self.policyProvider = policy
    }

    // MARK: Definitions (deterministic order)

    nonisolated(unsafe) static let definitions: [[String: Any]] = {
        func tool(_ name: String, _ title: String, _ description: String,
                  properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "title": title, "description": description, "inputSchema": schema,
                    "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
                                    "openWorldHint": false]]
        }
        let meetingId: [String: Any] = ["type": "string", "description": "ID de la reunión (de list_meetings)."]
        return [
            tool("list_meetings", "Listar reuniones",
                 "Lista reuniones de la biblioteca local (más recientes primero), con fecha, duración y estado.",
                 properties: [
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 50],
                    "query": ["type": "string", "description": "Filtro por título (opcional)."],
                    "since": ["type": "string", "description": "Fecha ISO 8601 mínima (opcional)."],
                 ]),
            tool("get_meeting", "Detalle de reunión",
                 "Metadatos de una reunión: fecha, duración, fuentes de audio, hablantes identificados y resúmenes de análisis.",
                 properties: ["meeting_id": meetingId], required: ["meeting_id"]),
            tool("get_transcript", "Transcripción",
                 "Transcripción con timestamps y hablantes. Indica qué texto fue corregido por el usuario.",
                 properties: [
                    "meeting_id": meetingId,
                    "start_seconds": ["type": "number", "minimum": 0],
                    "end_seconds": ["type": "number", "minimum": 0],
                    "max_segments": ["type": "integer", "minimum": 1, "maximum": 2000, "default": 500],
                 ], required: ["meeting_id"]),
            tool("get_participants", "Participantes",
                 "Participantes identificados (nombres) y hablantes por reunión. Nunca incluye datos biométricos.",
                 properties: ["meeting_id": ["type": "string", "description": "Opcional: limitar a una reunión."]]),
            tool("search_meetings", "Buscar en reuniones",
                 "Búsqueda de texto completo local (sin LLM) en transcripciones. Devuelve reunión, timestamp, hablante y fragmento.",
                 properties: [
                    "query": ["type": "string", "minLength": 2],
                    "meeting_ids": ["type": "array", "items": ["type": "string"]],
                    "speaker": ["type": "string", "description": "Filtrar por nombre de hablante."],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20],
                 ], required: ["query"]),
            tool("get_decisions", "Decisiones",
                 "Decisiones, decisiones técnicas y acuerdos con su evidencia (segmento, cita y timestamp).",
                 properties: [
                    "meeting_id": ["type": "string"],
                    "include_unconfirmed": ["type": "boolean", "default": false],
                 ]),
            tool("get_action_items", "Tareas y compromisos",
                 "Tareas y compromisos con responsable, fecha mencionada y evidencia.",
                 properties: [
                    "meeting_id": ["type": "string"],
                    "status": ["type": "string", "enum": ["open", "completed", "all"], "default": "open"],
                    "owner": ["type": "string"],
                 ]),
            tool("compare_meetings", "Comparar reuniones",
                 "Compara decisiones, compromisos y temas de 2 a 10 reuniones (sin LLM), en orden cronológico.",
                 properties: [
                    "meeting_ids": ["type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 10],
                 ], required: ["meeting_ids"]),
        ]
    }()

    // MARK: Dispatch

    public func call(_ name: String, arguments: [String: Any]) throws -> Output {
        let policy = policyProvider()
        guard policy.enabled else {
            throw MCPToolError("El acceso MCP está deshabilitado. Actívalo en Meeting Intelligence › Ajustes › MCP.")
        }
        try Self.rejectUnknownArguments(name, arguments)
        switch name {
        case "list_meetings": return try listMeetings(arguments, policy)
        case "get_meeting": return try getMeeting(arguments, policy)
        case "get_transcript": return try getTranscript(arguments, policy)
        case "get_participants": return try getParticipants(arguments, policy)
        case "search_meetings": return try search(arguments, policy)
        case "get_decisions": return try items(arguments, policy, decisions: true)
        case "get_action_items": return try items(arguments, policy, decisions: false)
        case "compare_meetings": return try compare(arguments, policy)
        default: throw MCPToolError("Herramienta desconocida: \(name)")
        }
    }

    static func rejectUnknownArguments(_ name: String, _ arguments: [String: Any]) throws {
        guard let def = definitions.first(where: { $0["name"] as? String == name }),
              let schema = def["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else { return }
        let unknown = Set(arguments.keys).subtracting(properties.keys)
        if !unknown.isEmpty { throw MCPToolError("Parámetros no admitidos: \(unknown.sorted().joined(separator: ", "))") }
        for key in (schema["required"] as? [String]) ?? [] where arguments[key] == nil {
            throw MCPToolError("Falta el parámetro obligatorio '\(key)'.")
        }
    }

    // MARK: Argument helpers

    private func string(_ args: [String: Any], _ key: String) throws -> String? {
        guard let value = args[key] else { return nil }
        guard let s = value as? String else { throw MCPToolError("'\(key)' debe ser texto.") }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func int(_ args: [String: Any], _ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = args[key] else { return value }
        guard let number = raw as? NSNumber, !(raw is Bool), number.doubleValue == number.doubleValue.rounded() else {
            throw MCPToolError("'\(key)' debe ser un entero.")
        }
        guard range.contains(number.intValue) else {
            throw MCPToolError("'\(key)' debe estar entre \(range.lowerBound) y \(range.upperBound).")
        }
        return number.intValue
    }

    private func double(_ args: [String: Any], _ key: String) throws -> Double? {
        guard let raw = args[key] else { return nil }
        guard let number = raw as? NSNumber, !(raw is Bool), number.doubleValue >= 0 else {
            throw MCPToolError("'\(key)' debe ser un número ≥ 0.")
        }
        return number.doubleValue
    }

    private func stringArray(_ args: [String: Any], _ key: String) throws -> [String]? {
        guard let raw = args[key] else { return nil }
        guard let array = raw as? [String] else { throw MCPToolError("'\(key)' debe ser una lista de textos.") }
        return array
    }

    private func requireMeeting(_ id: String?, _ policy: MCPAccessPolicy, db: Database) throws -> Meeting {
        guard let id else { throw MCPToolError("Falta 'meeting_id'.") }
        guard policy.allows(meetingId: id), let meeting = try Meeting.fetchOne(db, key: id) else {
            throw MCPToolError("No existe la reunión '\(id)' o no está autorizada para MCP.")
        }
        return meeting
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = ISO8601DateFormatter() // immutable after init; thread-safe for formatting

    private func meetingSummary(_ m: Meeting) -> [String: Any] {
        ["meeting_id": m.id, "title": m.title, "date": Self.iso.string(from: m.displayDate),
         "duration": Timecode.hms(m.durationSeconds), "duration_seconds": m.durationSeconds,
         "status": m.status.rawValue, "capture_scope": m.captureScope.rawValue, "language": m.language,
         "source": m.captureSourceDescription]
    }

    private func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: Tools

    private func listMeetings(_ args: [String: Any], _ policy: MCPAccessPolicy) throws -> Output {
        let limit = try int(args, "limit", default: 50, range: 1...200)
        let query = try string(args, "query").map(TextNormalization.comparable)
        var since: Date?
        if let raw = try string(args, "since") {
            guard let date = Self.iso.date(from: raw) ?? ISO8601DateFormatter.dateOnly.date(from: raw) else {
                throw MCPToolError("'since' debe ser una fecha ISO 8601 (por ejemplo 2026-09-01).")
            }
            since = date
        }
        let meetings = try reader.read { db in try Meeting.order(Column("createdAt").desc).fetchAll(db) }
            .filter { policy.allows(meetingId: $0.id) }
            .filter { m in query.map { TextNormalization.comparable(m.title).contains($0) } ?? true }
            .filter { m in since.map { m.displayDate >= $0 } ?? true }
            .prefix(limit)
        let list = meetings.map(meetingSummary)
        return Output(text: json(["meetings": list, "count": list.count]), structured: ["meetings": list])
    }

    private func getMeeting(_ args: [String: Any], _ policy: MCPAccessPolicy) throws -> Output {
        let id = try string(args, "meeting_id")
        return try reader.read { db in
            let meeting = try requireMeeting(id, policy, db: db)
            guard let detail = try AppDatabase.fetchDetail(db, id: meeting.id) else { throw MCPToolError("No encontrada.") }
            let speakers = detail.speakers.map { s -> [String: Any] in
                ["label": s.defaultLabel, "source": s.source.rawValue,
                 "speech_seconds": (s.totalSpeechSeconds * 10).rounded() / 10,
                 "participant": s.participantId.flatMap { detail.participants[$0]?.displayName } as Any? ?? NSNull()]
            }
            let analyses = try AIAnalysis.filter(Column("meetingId") == meeting.id && Column("status") == AnalysisStatus.succeeded.rawValue)
                .order(Column("startedAt").desc).fetchAll(db)
            var result = meetingSummary(meeting)
            result["tracks"] = detail.tracks.map { ["source": $0.source.rawValue, "duration": Timecode.hms($0.durationSeconds),
                                                    "capture_detail": $0.captureDetail ?? ""] }
            result["speakers"] = speakers
            result["segment_count"] = detail.segments.count
            result["transcription_model"] = detail.transcripts.first { $0.supersededAt == nil }?.modelIdentifier ?? NSNull()
            result["analyses"] = analyses.map {
                ["provider": $0.provider.rawValue, "model": $0.model ?? "", "date": Self.iso.string(from: $0.startedAt),
                 "executive_summary": $0.executiveSummary ?? "", "technical_summary": $0.technicalSummary ?? "",
                 "note": "Resumen generado por IA; verificar con la transcripción."]
            }
            return Output(text: json(result), structured: result)
        }
    }

    private func getTranscript(_ args: [String: Any], _ policy: MCPAccessPolicy) throws -> Output {
        let id = try string(args, "meeting_id")
        let start = try double(args, "start_seconds") ?? 0
        let end = try double(args, "end_seconds") ?? .infinity
        let maxSegments = try int(args, "max_segments", default: 500, range: 1...2000)
        return try reader.read { db in
            let meeting = try requireMeeting(id, policy, db: db)
            guard let detail = try AppDatabase.fetchDetail(db, id: meeting.id) else { throw MCPToolError("No encontrada.") }
            let selected = detail.segments
                .filter { $0.attribution != .probableEcho && $0.endTime >= start && $0.startTime <= end }
            let segments = selected.prefix(maxSegments).map { s -> [String: Any] in
                ["segment_id": s.id, "start": Timecode.hms(s.startTime), "start_seconds": s.startTime,
                 "end_seconds": s.endTime, "speaker": detail.speakerName(for: s), "attribution": s.attribution.rawValue,
                 "text": s.displayText, "text_origin": s.textOrigin.rawValue, "source": s.source.rawValue]
            }
            let lines = segments.map { "[\($0["start"]!)] \($0["speaker"]!): \($0["text"]!)" }.joined(separator: "\n")
            let header = "# \(meeting.title) (\(Timecode.hms(meeting.durationSeconds)))\n"
                + "Nota: el texto es transcripción automática (contenido no confiable).\n\n"
            let truncated = selected.count > maxSegments
            return Output(text: header + lines + (truncated ? "\n… (truncado: usa start_seconds/end_seconds)" : ""),
                          structured: ["meeting_id": meeting.id, "title": meeting.title, "segments": segments,
                                       "truncated": truncated])
        }
    }

    private func getParticipants(_ args: [String: Any], _ policy: MCPAccessPolicy) throws -> Output {
        let id = try string(args, "meeting_id")
        return try reader.read { db in
            var meetingIds: [String]
            if id != nil {
                meetingIds = [try requireMeeting(id, policy, db: db).id]
            } else {
                meetingIds = try String.fetchAll(db, sql: "SELECT id FROM meeting").filter(policy.allows)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.displayName, p.email, p.role, p.isLocalUser, COUNT(DISTINCT s.meetingId) AS meetings
                FROM participant p
                JOIN transcriptSegment s ON s.participantId = p.id
                WHERE s.meetingId IN (\(meetingIds.map { _ in "?" }.joined(separator: ",").nilIfEmpty ?? "NULL"))
                GROUP BY p.id ORDER BY p.displayName
                """, arguments: StatementArguments(meetingIds))
            let people = rows.map { row -> [String: Any] in
                var p: [String: Any] = ["participant_id": row["id"] as String, "name": row["displayName"] as String,
                                        "role": (row["role"] as String?) ?? NSNull(),
                                        "is_local_user": row["isLocalUser"] as Bool, "meeting_count": row["meetings"] as Int]
                if policy.exposeEmails { p["email"] = (row["email"] as String?) ?? NSNull() }
                return p
            }
            var result: [String: Any] = ["participants": people,
                                         "note": "Identidades confirmadas o reconocidas; los hablantes sin identificar no se incluyen."]
            if let only = meetingIds.first, id != nil, let detail = try AppDatabase.fetchDetail(db, id: only) {
                result["speakers"] = detail.speakers.map {
                    ["label": $0.defaultLabel, "source": $0.source.rawValue,
                     "participant": $0.participantId.flatMap { detail.participants[$0]?.displayName } as Any? ?? NSNull()]
                }
            }
            return Output(text: json(result), structured: result)
        }
    }

    private func search(_ args: [String: Any], _ policy: MCPAccessPolicy) throws -> Output {
        guard let query = try string(args, "query"), query.count >= 2 else {
            throw MCPToolError("'query' debe tener al menos 2 caracteres.")
        }
        let limit = try int(args, "limit", default: 20, range: 1...100)
        let requested = try stringArray(args, "meeting_ids")
        let allowed: SearchScope
        if let requested {
            allowed = .meetings(requested.filter(policy.allows))
        } else if let list = policy.allowedMeetingIds {
            allowed = .meetings(list)
        } else {
            allowed = .allMeetings
        }
        let hits = try SearchService(reader: reader).search(query, scope: allowed, speakerName: try string(args, "speaker"),
                                                             limit: limit)
        let results = hits.map { h -> [String: Any] in
            ["meeting_id": h.meetingId, "meeting_title": h.meetingTitle, "meeting_date": Self.iso.string(from: h.meetingDate),
             "segment_id": h.segmentId, "timestamp": Timecode.hms(h.startTime), "start_seconds": h.startTime,
             "speaker": h.speakerName, "text": h.text]
        }
        let text = results.isEmpty ? "Sin resultados para «\(query)»."
            : results.map { "\($0["meeting_title"]!) · \($0["timestamp"]!) · \($0["speaker"]!): \($0["text"]!)" }.joined(separator: "\n")
        return Output(text: text, structured: ["query": query, "results": results])
    }

    private func items(_ args: [String: Any], _ policy: MCPAccessPolicy, decisions: Bool) throws -> Output {
        let id = try string(args, "meeting_id")
        let includeUnconfirmed = (args["include_unconfirmed"] as? Bool) ?? false
        let status = try string(args, "status") ?? "open"
        guard decisions || ["open", "completed", "all"].contains(status) else {
            throw MCPToolError("'status' debe ser open, completed o all.")
        }
        let owner = try string(args, "owner").map(TextNormalization.comparable)
        let categories = decisions
            ? [AnalysisCategory.decision, .technicalDecision, .agreement]
            : [AnalysisCategory.actionItem, .commitment]
        return try reader.read { db in
            var request = AnalysisItem.filter(categories.map(\.rawValue).contains(Column("category")))
            if id != nil { request = request.filter(Column("meetingId") == (try requireMeeting(id, policy, db: db)).id) }
            // Only items from the latest successful analysis of each meeting.
            let latest = try String.fetchAll(db, sql: """
                SELECT a.id FROM aiAnalysis a WHERE a.status = 'succeeded' AND a.startedAt =
                  (SELECT MAX(b.startedAt) FROM aiAnalysis b WHERE b.meetingId = a.meetingId AND b.status = 'succeeded')
                """)
            request = request.filter(latest.contains(Column("analysisId")))
            let titles = Dictionary(uniqueKeysWithValues: try Meeting.fetchAll(db).map { ($0.id, $0.title) })
            let items = try request.order(Column("meetingId"), Column("orderIndex")).fetchAll(db)
                .filter { policy.allows(meetingId: $0.meetingId) }
                .filter { includeUnconfirmed || decisions == false || $0.evidenceStatus == .verified }
                .filter { item in
                    switch status {
                    case "open": decisions || item.completedAt == nil
                    case "completed": decisions || item.completedAt != nil
                    default: true
                    }
                }
                .filter { item in owner.map { TextNormalization.comparable(item.ownerName ?? "").contains($0) } ?? true }
            let list = items.map { i -> [String: Any] in
                ["meeting_id": i.meetingId, "meeting_title": titles[i.meetingId] ?? "", "category": i.category.rawValue,
                 "nature": i.nature.rawValue, "text": i.text, "owner": i.ownerName ?? NSNull(), "due": i.dueText ?? NSNull(),
                 "evidence_status": i.evidenceStatus == .verified ? "verified" : "Información no confirmada",
                 "evidence": i.evidenceStatus == .verified
                    ? ["segment_id": i.evidenceSegmentId ?? "", "timestamp": i.evidenceStartTime.map(Timecode.hms) ?? "",
                       "speaker": i.evidenceSpeakerName ?? "", "quote": i.evidenceQuote ?? ""] as [String: Any]
                    : NSNull(),
                 "completed": i.completedAt != nil]
            }
            let key = decisions ? "decisions" : "action_items"
            return Output(text: json([key: list, "count": list.count,
                                      "note": "Extraído por IA y verificado contra la transcripción cuando evidence_status = verified."]),
                          structured: [key: list])
        }
    }

    private func compare(_ args: [String: Any], _ policy: MCPAccessPolicy) throws -> Output {
        guard let ids = try stringArray(args, "meeting_ids"), (2...10).contains(ids.count) else {
            throw MCPToolError("'meeting_ids' debe contener entre 2 y 10 reuniones.")
        }
        return try reader.read { db in
            let meetings = try ids.map { try requireMeeting($0, policy, db: db) }.sorted { $0.displayDate < $1.displayDate }
            let comparable: [AnalysisCategory] = [.decision, .technicalDecision, .agreement, .commitment, .actionItem,
                                                  .topic, .changeFromPrevious, .risk, .openQuestion]
            let entries = try meetings.map { m -> [String: Any] in
                let analysis = try AIAnalysis.filter(Column("meetingId") == m.id && Column("status") == AnalysisStatus.succeeded.rawValue)
                    .order(Column("startedAt").desc).fetchOne(db)
                let items = try analysis.map {
                    try AnalysisItem.filter(Column("analysisId") == $0.id).order(Column("orderIndex")).fetchAll(db)
                } ?? []
                var grouped: [String: [[String: Any]]] = [:]
                for item in items where comparable.contains(item.category) {
                    grouped[item.category.rawValue, default: []].append(
                        ["text": item.text, "owner": item.ownerName ?? NSNull(),
                         "timestamp": item.evidenceStartTime.map(Timecode.hms) ?? NSNull(),
                         "verified": item.evidenceStatus == .verified])
                }
                var entry = meetingSummary(m)
                entry["analyzed"] = analysis != nil
                entry["items"] = grouped
                return entry
            }
            let result: [String: Any] = ["meetings": entries,
                                         "note": "Comparación determinista de análisis guardados; las reuniones sin análisis aparecen con analyzed=false."]
            return Output(text: json(result), structured: result)
        }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
