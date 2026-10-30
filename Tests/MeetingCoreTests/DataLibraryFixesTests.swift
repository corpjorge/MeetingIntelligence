import Foundation
import GRDB
import Testing
@testable import MeetingCore

@Suite("Datos: biblioteca, almacenamiento y búsqueda")
struct DataLibraryFixesTests {
    private func library() throws -> (AppDatabase, AppPaths, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mi-test-\(UUID().uuidString)")
        let paths = AppPaths(root: root)
        return (try AppDatabase.open(paths: paths), paths, root)
    }

    @Test func deletingAMeetingBeingRecordedNeedsExplicitPermission() throws {
        let (db, paths, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = Meeting(title: "FIXTURE · En grabación", origin: .recording, captureScope: .microphoneOnly, status: .recording)
        try db.insert(meeting: meeting, tracks: [])
        let dir = try paths.prepareMeetingDirectory(meeting.id)
        try Data("x".utf8).write(to: dir.appendingPathComponent("local_microphone.wav"))

        let error = #expect(throws: AppDatabaseError.self) { try db.deleteMeeting(id: meeting.id, paths: paths) }
        #expect(error?.localizedDescription == "La reunión se está grabando; detén la grabación antes de eliminarla.")
        #expect(try db.meeting(id: meeting.id) != nil)
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try db.deleteMeeting(id: meeting.id, paths: paths, allowRecording: true)
        #expect(try db.meeting(id: meeting.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func recoveryReportsRecordingsAndProcessingAndFailsRunningAnalyses() throws {
        let db = try AppDatabase.inMemory()
        let recording = Meeting(title: "FIXTURE · Grabando", createdAt: Date(timeIntervalSince1970: 100), origin: .recording,
                                captureScope: .microphoneOnly, status: .recording)
        let processing = Meeting(title: "FIXTURE · Procesando", createdAt: Date(timeIntervalSince1970: 200), origin: .imported,
                                 captureScope: .importedFile, status: .processing)
        let ready = Meeting(title: "FIXTURE · Lista", createdAt: Date(timeIntervalSince1970: 300), origin: .imported,
                            captureScope: .importedFile, status: .ready)
        for meeting in [recording, processing, ready] { try db.insert(meeting: meeting, tracks: []) }
        try db.record(job: ProcessingJob(meetingId: processing.id, stage: .transcription))
        let running = AIAnalysis(meetingId: ready.id, provider: .ollama, model: nil, promptVersion: "fixture",
                                 sharedContentSummary: "fixture")
        let finished = AIAnalysis(meetingId: ready.id, provider: .ollama, model: nil, promptVersion: "fixture",
                                  sharedContentSummary: "fixture", status: .succeeded, finishedAt: Date())
        try db.writer.write { db in
            try running.insert(db)
            try finished.insert(db)
        }

        let recovered = try db.recoverInterrupted()
        #expect(recovered == InterruptedMeetings(recordings: [recording.id], processing: [processing.id]))
        #expect(try db.meeting(id: recording.id)?.status == .interrupted)
        #expect(try db.meeting(id: processing.id)?.status == .failed)
        #expect(try db.meeting(id: ready.id)?.status == .ready)
        #expect(try db.recentJobs().allSatisfy { $0.status == .failed && $0.errorMessage == "Interrumpido" && $0.finishedAt != nil })
        let analyses = try db.reader.read { db in
            try AIAnalysis.fetchAll(db).reduce(into: [String: AIAnalysis]()) { $0[$1.id] = $1 }
        }
        #expect(analyses[running.id]?.status == .failed)
        #expect(analyses[running.id]?.errorMessage == "Interrumpido")
        #expect(analyses[running.id]?.finishedAt != nil)
        #expect(analyses[finished.id]?.status == .succeeded)
        #expect(try db.recoverInterrupted() == InterruptedMeetings())

        let another = Meeting(title: "FIXTURE · Otra", origin: .recording, captureScope: .microphoneOnly, status: .recording)
        try db.insert(meeting: another, tracks: [])
        #expect(try db.recoverInterruptedMeetings() == [another.id])
    }

    @Test func interruptedMeetingsWithoutAudioAreListed() throws {
        let db = try AppDatabase.inMemory()
        let empty = Meeting(title: "FIXTURE · Sin audio", origin: .recording, captureScope: .microphoneOnly, status: .interrupted)
        let withAudio = Meeting(title: "FIXTURE · Con audio", origin: .recording, captureScope: .microphoneOnly, status: .interrupted)
        let readyEmpty = Meeting(title: "FIXTURE · Lista", origin: .imported, captureScope: .importedFile, status: .ready)
        try db.insert(meeting: empty, tracks: [])
        try db.insert(meeting: withAudio, tracks: [
            AudioTrack(meetingId: withAudio.id, source: .localMicrophone, relativePath: "Recordings/\(withAudio.id)/local_microphone.wav",
                       sampleRate: 16_000, channelCount: 1, durationSeconds: 5),
        ])
        try db.insert(meeting: readyEmpty, tracks: [])
        #expect(try db.interruptedMeetingIdsWithoutTracks() == [empty.id])
    }

    @Test func orphanCleanupSparesEmptyLibrariesAndRecentFolders() throws {
        let (db, paths, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let stray = try paths.prepareMeetingDirectory("FIXTURE-STRAY")
        let file = stray.appendingPathComponent("remote_system_audio.wav")
        try Data(count: 1000).write(to: file)

        let emptyLibrary = try StorageMaintenance.removeOrphanedRecordings(database: db, paths: paths,
                                                                          now: Date().addingTimeInterval(2 * 3600))
        #expect(emptyLibrary.removedItems == 0)
        #expect(fm.fileExists(atPath: stray.path))

        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("hola", 0, 1)])
        let kept = try paths.prepareMeetingDirectory(meeting.id)
        #expect(try StorageMaintenance.removeOrphanedRecordings(database: db, paths: paths).removedItems == 0)
        #expect(fm.fileExists(atPath: stray.path))

        let old = Date().addingTimeInterval(-2 * 3600)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: stray.path)
        #expect(try StorageMaintenance.removeOrphanedRecordings(database: db, paths: paths).removedItems == 0)
        #expect(fm.fileExists(atPath: file.path))

        try fm.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let removed = try StorageMaintenance.removeOrphanedRecordings(database: db, paths: paths)
        #expect(removed.removedItems == 1 && removed.freedBytes > 0)
        #expect(!fm.fileExists(atPath: stray.path))
        #expect(fm.fileExists(atPath: kept.path))
    }

    @Test func answersCitingADeletedMeetingAreNotSaved() throws {
        let (db, paths, root) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let (a, _, _, _) = try Fixture.meeting(db, title: "FIXTURE · A", texts: [("la latencia del API subió", 0, 2)])
        let (b, _, _, _) = try Fixture.meeting(db, title: "FIXTURE · B", texts: [("la latencia volvió a la normalidad", 0, 2)])
        let chat = MeetingChatService(database: db)
        func ask() throws -> MeetingChatService.Answer {
            chat.localAnswer(question: "latencia",
                             retrieval: try chat.retrieve(question: "latencia", scope: .allMeetings, model: nil, timeout: 10))
        }
        let stale = try ask()
        #expect(Set(stale.excerpts.map(\.meetingId)) == [a.id, b.id])

        try db.deleteMeeting(id: a.id, paths: paths)
        let saved = try db.appendChatMessage(ChatHistoryMessage(question: "latencia", answer: stale, scopeMeetingIds: nil),
                                             thread: .library)
        #expect(saved == false)
        #expect(try db.chatHistory(.library).isEmpty)
        #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chatMessageSource") } == 0)
        let ownThread = try db.appendChatMessage(ChatHistoryMessage(question: "hola", answer: nil, scopeMeetingIds: [a.id]),
                                                 thread: .meeting(a.id))
        #expect(ownThread == false)

        #expect(try db.appendChatMessage(ChatHistoryMessage(question: "latencia", answer: try ask(), scopeMeetingIds: nil),
                                         thread: .library))
        #expect(try db.chatHistory(.library).count == 1)
        try db.deleteMeeting(id: b.id, paths: paths)
        #expect(try db.chatHistory(.library).isEmpty)
    }

    @Test func srtSubtitlesNeverContainBlankLines() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [("primera intervención", 1, 3), ("segunda", 4, 6),
                                                                        ("tercera", 7, 9)])
        try db.editSegmentText(segmentId: segments[1].id, newText: "línea uno\n\n  línea dos  \r\n\r\nlínea tres")
        let srt = String(decoding: try MeetingExporter(database: db).data(meetingId: meeting.id, format: .srt), as: UTF8.self)
        let blocks = srt.components(separatedBy: "\n\n")
        #expect(blocks.count == 3)
        #expect(blocks[1] == "2\n00:00:04,000 --> 00:00:06,000\nSin identificar: línea uno\nlínea dos\nlínea tres")
        #expect(blocks[2] == "3\n00:00:07,000 --> 00:00:09,000\nSin identificar: tercera\n")
        #expect(MeetingExporter.subtitleText("a\n\n\n b \n") == "a\nb")
    }

    @Test func openActionItemsComeFromTheLatestSuccessfulAnalysis() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, _) = try Fixture.meeting(db, texts: [("hola", 0, 1)])
        let start = Date(timeIntervalSince1970: 1_000_000)
        func analysis(_ status: AnalysisStatus, minutes: Double) -> AIAnalysis {
            AIAnalysis(meetingId: meeting.id, provider: .ollama, model: nil, promptVersion: "fixture",
                       sharedContentSummary: "fixture", status: status, startedAt: start.addingTimeInterval(minutes * 60))
        }
        func item(_ analysis: AIAnalysis, _ category: AnalysisCategory, _ index: Int, done: Bool = false) -> AnalysisItem {
            AnalysisItem(analysisId: analysis.id, meetingId: meeting.id, category: category, nature: .fact,
                         text: "FIXTURE \(index)", evidenceStatus: .verified, orderIndex: index,
                         completedAt: done ? Date() : nil)
        }
        let older = analysis(.succeeded, minutes: 0)
        let latest = analysis(.succeeded, minutes: 10)
        let failed = analysis(.failed, minutes: 20)
        try db.writer.write { db in
            for analysis in [older, latest, failed] { try analysis.insert(db) }
            for index in 0..<3 { try item(older, .actionItem, index).insert(db) }
            try item(latest, .actionItem, 0).insert(db)
            try item(latest, .commitment, 1).insert(db)
            try item(latest, .actionItem, 2, done: true).insert(db)
            try item(latest, .decision, 3).insert(db)
            try item(failed, .actionItem, 0).insert(db)
        }
        #expect(try db.meetingRows().first { $0.id == meeting.id }?.openActionItems == 2)
    }

    @Test func speakerFilterAppliesBeforeTheLimitAndMatchesWordPrefixes() throws {
        let db = try AppDatabase.inMemory()
        let diana = Participant(displayName: "FIXTURE Diana")
        let ana = Participant(displayName: "FIXTURE Ána María")
        try db.save(participant: diana)
        try db.save(participant: ana)
        let dianaTexts = (0..<8).map { ("presupuesto presupuesto presupuesto", Double($0 * 10), Double($0 * 10 + 2)) }
        let anaTexts = [("revisamos con calma el presupuesto del trimestre junto con todo el equipo de finanzas", 100.0, 105.0),
                        ("al final el presupuesto anual quedó pendiente de aprobación por parte del comité", 110.0, 115.0)]
        let (_, _, _, segments) = try Fixture.meeting(db, texts: dianaTexts + anaTexts)
        try db.writer.write { db in
            for (index, segment) in segments.enumerated() {
                try db.execute(sql: "UPDATE transcriptSegment SET participantId = ? WHERE id = ?",
                               arguments: [index < 8 ? diana.id : ana.id, segment.id])
            }
        }
        let anaIds = Set(segments.suffix(2).map(\.id))
        let search = SearchService(reader: db.reader)

        #expect(try search.search("presupuesto", limit: 6).allSatisfy { $0.speakerName == diana.displayName })
        #expect(Set(try search.search("presupuesto", speakerName: "ana", limit: 2).map(\.segmentId)) == anaIds)
        #expect(Set(try search.search("presupuesto", speakerName: "ÁNA", limit: 5).map(\.segmentId)) == anaIds)
        #expect(Set(try search.search("presupuesto", speakerName: "maria", limit: 5).map(\.segmentId)) == anaIds)
        #expect(Set(try search.search("presupuesto", speakerName: "maría ána", limit: 5).map(\.segmentId)) == anaIds)
        let dianaHits = try search.search("presupuesto", speakerName: "Diana", limit: 3)
        #expect(dianaHits.count == 3 && dianaHits.allSatisfy { $0.speakerName == diana.displayName })
        #expect(try search.search("presupuesto", speakerName: "iana").isEmpty)
        #expect(try search.search("presupuesto", speakerName: "Hablante").isEmpty)
    }

    @Test func wordPrefixMatchingIgnoresCaseAndAccents() {
        #expect(TextNormalization.matchesWordPrefixes("Ana María", query: "ana"))
        #expect(TextNormalization.matchesWordPrefixes("Ana María", query: "MARI"))
        #expect(TextNormalization.matchesWordPrefixes("Ana María", query: "maría ana"))
        #expect(TextNormalization.matchesWordPrefixes("Hablante 2", query: "  "))
        #expect(!TextNormalization.matchesWordPrefixes("Diana", query: "ana"))
        #expect(!TextNormalization.matchesWordPrefixes("Ana María", query: "ana luisa"))
    }

    @Test func emptiedSegmentLosesItsVectorAndNeverMatches() throws {
        let db = try AppDatabase.inMemory()
        let model = "test-model"
        let vector: [Float] = [1, 0, 0]
        let (_, _, _, segments) = try Fixture.meeting(db, texts: [("se me cayó el internet", 0, 2), ("aprobamos el costo", 3, 5)])
        try db.storeEmbeddings(try db.segmentsNeedingEmbedding(model: model, limit: 10).map { ($0, vector) }, model: model)
        let search = SearchService(reader: db.reader)
        let query = SemanticQuery(vector: vector, model: model)
        #expect(try search.semanticSearch(query, minSimilarity: 0).count == 2)

        try db.editSegmentText(segmentId: segments[0].id, newText: "   ")
        #expect(try db.reader.read { try String.fetchAll($0, sql: "SELECT segmentId FROM segmentEmbedding") } == [segments[1].id])
        #expect(try search.semanticSearch(query, minSimilarity: 0).map(\.segmentId) == [segments[1].id])
        #expect(try db.semanticIndexCoverage(model: model) == SemanticIndexCoverage(indexed: 1, total: 1))
        #expect(try db.segmentsNeedingEmbedding(model: model, limit: 10).isEmpty)

        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO segmentEmbedding (segmentId, model, textHash, vector) VALUES (?, ?, ?, ?)",
                           arguments: [segments[0].id, model, "stale", EmbeddingCodec.encode(vector)])
        }
        #expect(try search.semanticSearch(query, minSimilarity: 0).map(\.segmentId) == [segments[1].id])
        #expect(try db.semanticIndexCoverage(model: model) == SemanticIndexCoverage(indexed: 1, total: 1))

        try db.revertSegmentText(segmentId: segments[0].id)
        #expect(try db.segmentsNeedingEmbedding(model: model, limit: 10).map(\.segmentId) == [segments[0].id])
    }
}
