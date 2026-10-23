import Foundation
import GRDB
import Testing
@testable import MeetingCore

/// Test fixtures below are synthetic and explicitly labelled; they never reach production paths.
enum Fixture {
    static func meeting(_ db: AppDatabase, title: String = "FIXTURE · Validación de ingresos",
                        texts: [(String, Double, Double)]) throws -> (Meeting, AudioTrack, Transcript, [TranscriptSegment]) {
        let meeting = Meeting(title: title, origin: .imported, captureScope: .importedFile, status: .ready)
        let track = AudioTrack(meetingId: meeting.id, source: .imported, relativePath: "Recordings/\(meeting.id)/imported.wav",
                               sampleRate: 16_000, channelCount: 1, durationSeconds: 120)
        try db.insert(meeting: meeting, tracks: [track])
        let transcript = Transcript(meetingId: meeting.id, trackId: track.id, engine: "fixture", modelIdentifier: "fixture",
                                    language: "es-CO", isFinal: true, audioDurationSeconds: 120, processingSeconds: 1,
                                    meanConfidence: 0.9)
        let segments = texts.enumerated().map { index, item in
            TranscriptSegment(transcriptId: transcript.id, meetingId: meeting.id, trackId: track.id, source: .imported,
                              orderIndex: index, startTime: item.1, endTime: item.2, asrText: item.0)
        }
        try db.replaceTranscript(transcript, segments: segments)
        return (meeting, track, transcript, segments)
    }
}

@Suite("Persistencia")
struct PersistenceTests {
    @Test func migrationsCreateExpectedSchema() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table') ORDER BY name")
        }
        for expected in ["meeting", "audioTrack", "transcript", "transcriptSegment", "participant", "speakerProfile",
                         "voiceSample", "meetingSpeaker", "speakerAssignment", "aiAnalysis", "analysisItem",
                         "aiProviderConfiguration", "processingJob", "correctionEvent", "vocabularyTerm",
                         "transcriptSegmentFts", "analysisItemFts"] {
            #expect(tables.contains(expected), "Falta la tabla \(expected)")
        }
        let fkViolations = try db.reader.read { db in try Row.fetchAll(db, sql: "PRAGMA foreign_key_check") }
        #expect(fkViolations.isEmpty)
        let integrity = try db.reader.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }
        #expect(integrity == "ok")
    }

    @Test func meetingDetailRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, track, _, segments) = try Fixture.meeting(db, texts: [
            ("Debemos validar ese campo en el response", 75.2, 83.8),
            ("De acuerdo, lo reviso mañana", 84.0, 86.5),
        ])
        let detail = try #require(try db.meetingDetail(id: meeting.id))
        #expect(detail.meeting.title == meeting.title)
        #expect(detail.tracks.map(\.id) == [track.id])
        #expect(detail.segments.map(\.id) == segments.map(\.id))
        #expect(detail.segments.first?.startTime == 75.2)
        // No identity is invented for unattributed segments.
        #expect(detail.speakerName(for: detail.segments[0]) == "Sin identificar")
    }

    @Test func renamingTrimsIgnoresEmptyAndRecordsHistory() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("Hola", 0, 1)])
        func title() throws -> String? { try db.meetingDetail(id: meeting.id)?.meeting.title }
        func events() throws -> [Row] {
            try db.reader.read { try Row.fetchAll($0, sql: "SELECT previousValue, newValue FROM correctionEvent WHERE field = 'title'") }
        }

        try db.renameMeeting(id: meeting.id, title: "  Comité de arquitectura \n")
        #expect(try title() == "Comité de arquitectura")
        try db.renameMeeting(id: meeting.id, title: "   ")
        try db.renameMeeting(id: meeting.id, title: "Comité de arquitectura")
        #expect(try title() == "Comité de arquitectura")
        let history = try events()
        #expect(history.count == 1)
        #expect(history.first?["previousValue"] as String? == meeting.title)
        #expect(history.first?["newValue"] as String? == "Comité de arquitectura")
    }

    @Test func editingPreservesOriginalASRAndRecordsHistory() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [("el servicio de viavilidad inicial", 0, 3)])
        try db.editSegmentText(segmentId: segments[0].id, newText: "el servicio de viabilidad inicial")
        var detail = try #require(try db.meetingDetail(id: meeting.id))
        #expect(detail.segments[0].asrText == "el servicio de viavilidad inicial")
        #expect(detail.segments[0].editedText == "el servicio de viabilidad inicial")
        #expect(detail.segments[0].textOrigin == .userEdited)
        let history = try db.corrections(meetingId: meeting.id)
        #expect(history.count == 1)
        #expect(history.first?.previousValue == "el servicio de viavilidad inicial")

        try db.revertSegmentText(segmentId: segments[0].id)
        detail = try #require(try db.meetingDetail(id: meeting.id))
        #expect(detail.segments[0].editedText == nil)
        #expect(detail.segments[0].displayText == "el servicio de viavilidad inicial")
        #expect(try db.corrections(meetingId: meeting.id).count == 2)
    }

    @Test func retranscriptionSupersedesInsteadOfDeleting() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, track, first, _) = try Fixture.meeting(db, texts: [("versión uno", 0, 1)])
        let second = Transcript(meetingId: meeting.id, trackId: track.id, engine: "fixture", modelIdentifier: "fixture",
                                language: "es-CO", isFinal: true, audioDurationSeconds: 1, processingSeconds: 1,
                                meanConfidence: nil)
        try db.replaceTranscript(second, segments: [
            TranscriptSegment(transcriptId: second.id, meetingId: meeting.id, trackId: track.id, source: .imported,
                              orderIndex: 0, startTime: 0, endTime: 1, asrText: "versión dos"),
        ])
        let detail = try #require(try db.meetingDetail(id: meeting.id))
        #expect(detail.transcripts.count == 2)
        #expect(detail.transcripts.first { $0.id == first.id }?.supersededAt != nil)
        #expect(detail.segments.map(\.asrText) == ["versión dos"])
    }

    @Test func deletingMeetingCascadesAndRemovesFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let db = try AppDatabase.open(paths: paths)
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("hola", 0, 1)])
        let dir = try paths.prepareMeetingDirectory(meeting.id)
        try Data("x".utf8).write(to: dir.appendingPathComponent("imported.wav"))

        try db.deleteMeeting(id: meeting.id, paths: paths)
        #expect(try db.meeting(id: meeting.id) == nil)
        let orphanSegments = try db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcriptSegment") }
        #expect(orphanSegments == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func libraryFilesAreOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        _ = try AppDatabase.open(paths: paths)
        let rootPerms = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        let dbPerms = try FileManager.default.attributesOfItem(atPath: paths.databaseURL.path)[.posixPermissions] as? Int
        #expect(rootPerms == 0o700)
        #expect(dbPerms == 0o600)
    }

    @Test func interruptedRecordingIsRecovered() throws {
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(title: "FIXTURE", origin: .recording, captureScope: .teamsProcesses, status: .recording)
        try db.insert(meeting: meeting, tracks: [])
        let recovered = try db.recoverInterruptedMeetings()
        #expect(recovered == [meeting.id])
        #expect(try db.meeting(id: meeting.id)?.status == .interrupted)
    }

    @Test func singleLocalUser() throws {
        let db = try AppDatabase.inMemory()
        let me = try db.setLocalUserName("Jorge")
        try db.save(participant: Participant(displayName: "Otra persona", isLocalUser: true))
        let participants = try db.participants()
        #expect(participants.filter(\.isLocalUser).count == 1)
        #expect(participants.first { $0.id == me.id }?.isLocalUser == false)
    }
}

@Suite("Búsqueda FTS5")
struct SearchTests {
    @Test func accentInsensitivePrefixSearchWithReferences() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [
            ("El servicio de viabilidad inicial debe exponer el indicador de ingresos validados", 872, 880),
            ("Hablemos del almuerzo", 900, 902),
        ])
        let service = SearchService(reader: db.reader)
        let hits = try service.search("¿Qué dijo sobre VIABILIDAD inicial?")
        #expect(hits.first?.segmentId == segments[0].id)
        #expect(hits.first?.meetingId == meeting.id)
        #expect(hits.first?.startTime == 872)
        #expect(hits.first?.snippet.contains("[") == true)

        let accentless = try service.search("indicador ingresos validados")
        #expect(accentless.first?.segmentId == segments[0].id)
        // Plural query finds singular text through light stemming.
        #expect(try service.search("almuerzos").first?.segmentId == segments[1].id)
        #expect(try service.search("viabilidades iniciales").first?.segmentId == segments[0].id)
    }

    @Test func searchSeesUserEditsAndScopes() throws {
        let db = try AppDatabase.inMemory()
        let (m1, _, _, s1) = try Fixture.meeting(db, title: "FIXTURE A", texts: [("campo mal escrito", 0, 1)])
        _ = try Fixture.meeting(db, title: "FIXTURE B", texts: [("otro campo", 0, 1)])
        try db.editSegmentText(segmentId: s1[0].id, newText: "campo onboarding corregido")
        let service = SearchService(reader: db.reader)
        #expect(try service.search("onboarding").map(\.segmentId) == [s1[0].id])
        #expect(try service.search("campo", scope: .meetings([m1.id])).count == 1)
        #expect(try service.search("campo").count == 2)
        #expect(try service.search("de la que").isEmpty) // only stopwords
    }
}

@Suite("Exportación")
struct ExportTests {
    @Test func allFormatsKeepStructure() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [
            ("Debemos validar ese campo en el response", 75.2, 83.8),
            ("De acuerdo", 84.0, 85.0),
        ])
        try db.editSegmentText(segmentId: segments[1].id, newText: "De acuerdo, lo valido.")
        let exporter = MeetingExporter(database: db)

        let json = try exporter.data(meetingId: meeting.id, format: .json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(MeetingExportDocument.self, from: json)
        #expect(doc.schemaVersion == 1)
        #expect(doc.segments.count == 2)
        #expect(doc.segments[0].start == 75.2 && doc.segments[0].end == 83.8)
        #expect(doc.segments[1].asrText == "De acuerdo")
        #expect(doc.segments[1].editedText == "De acuerdo, lo valido.")
        #expect(doc.segments[1].textOrigin == "userEdited")
        #expect(doc.corrections.count == 1)
        // No biometric material in exports.
        #expect(String(decoding: json, as: UTF8.self).contains("embedding") == false)

        let srt = String(decoding: try exporter.data(meetingId: meeting.id, format: .srt), as: UTF8.self)
        #expect(srt.hasPrefix("1\n00:01:15,200 --> 00:01:23,800\n"))
        let md = String(decoding: try exporter.data(meetingId: meeting.id, format: .markdown), as: UTF8.self)
        #expect(md.contains("**[00:01:15] Sin identificar**: Debemos validar ese campo en el response"))
        let txt = String(decoding: try exporter.data(meetingId: meeting.id, format: .txt), as: UTF8.self)
        #expect(txt.contains("[00:01:24] Sin identificar: De acuerdo, lo valido."))
        let pdf = try exporter.data(meetingId: meeting.id, format: .pdf)
        #expect(pdf.prefix(5) == Data("%PDF-".utf8))
        #expect(pdf.count > 1000)
    }
}
