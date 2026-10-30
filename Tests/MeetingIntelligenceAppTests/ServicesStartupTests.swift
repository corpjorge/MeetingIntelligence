import Foundation
import MeetingCore
import MeetingSpeech
import Testing
@testable import MeetingIntelligenceApp

@Suite("App: arranque seguro de la biblioteca")
struct ServicesStartupTests {
    private func agedOrphanFolder(_ paths: AppPaths) throws -> URL {
        let folder = try paths.prepareMeetingDirectory("orphan-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("local_microphone.wav")
        try Data("fixture audio".utf8).write(to: file)
        let old = Date().addingTimeInterval(-7_200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        return folder
    }

    private func writeUnfinishedWAV(seconds: Double, to url: URL) throws {
        let sampleRate: UInt32 = 16_000
        let samples = Int(Double(sampleRate) * seconds)
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append32(36)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append32(16)
        append16(1); append16(1); append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8)); append32(0)
        data.append(Data(count: samples * 2))
        try data.write(to: url)
    }

    private func maintenance(_ db: AppDatabase, _ paths: AppPaths) -> StartupMaintenance {
        StartupMaintenance(database: db, importer: MeetingImportService(database: db, paths: paths), paths: paths,
                           audioRetentionDays: nil, videoRetentionDays: nil)
    }

    @Test func policyBlocksMaintenanceAndCaptureWhenTheLibraryIsNotOwned() {
        let normal = LibraryStartupPolicy.decide(databaseOpened: true, lock: .exclusive)
        #expect(normal.runsMaintenance && normal.blockedReason == nil && !normal.sharedWithAnotherInstance)

        let failed = LibraryStartupPolicy.decide(databaseOpened: false, lock: .exclusive)
        #expect(!failed.runsMaintenance)
        #expect(failed.blockedReason == LibraryStartupPolicy.databaseUnavailableReason)

        let shared = LibraryStartupPolicy.decide(databaseOpened: true, lock: .heldByAnotherInstance)
        #expect(!shared.runsMaintenance && shared.sharedWithAnotherInstance)
        #expect(shared.blockedReason == LibraryStartupPolicy.sharedLibraryReason)

        let unlockable = LibraryStartupPolicy.decide(databaseOpened: true, lock: .unavailable)
        #expect(unlockable.runsMaintenance && unlockable.blockedReason == nil)
    }

    @Test func failedDatabaseOpenOrSharedLibraryNeverDeletesRealRecordings() throws {
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let folder = try agedOrphanFolder(paths)
        let fallback = try AppDatabase.inMemory()
        _ = try AppFixture.meeting(fallback)

        let failed = LibraryStartupPolicy.decide(databaseOpened: false, lock: .exclusive)
        #expect(maintenance(fallback, paths).run(policy: failed).isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        let library = try AppDatabase.open(paths: paths)
        _ = try AppFixture.meeting(library)
        let shared = LibraryStartupPolicy.decide(databaseOpened: true, lock: .heldByAnotherInstance)
        _ = maintenance(library, paths).run(policy: shared)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        let owner = LibraryStartupPolicy.decide(databaseOpened: true, lock: .exclusive)
        _ = maintenance(library, paths).run(policy: owner)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func recoveryReportsOnlyRecordingsAndRetriesInterruptedMeetingsWithoutTracks() throws {
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.open(paths: paths)
        let recording = Meeting(title: "FIXTURE · grabando", origin: .recording, captureScope: .microphoneOnly,
                                status: .recording)
        let processing = Meeting(title: "FIXTURE · procesando", origin: .imported, captureScope: .importedFile,
                                 status: .processing)
        let stale = Meeting(title: "FIXTURE · interrumpida", origin: .recording, captureScope: .microphoneOnly,
                            status: .interrupted)
        for meeting in [recording, processing, stale] {
            try db.insert(meeting: meeting, tracks: [])
            try paths.prepareMeetingDirectory(meeting.id)
        }
        let wav = paths.meetingDirectory(stale.id).appendingPathComponent("\(AudioSource.localMicrophone.fileStem).wav")
        try writeUnfinishedWAV(seconds: 2, to: wav)

        let reported = maintenance(db, paths).run(policy: .decide(databaseOpened: true, lock: .exclusive))

        #expect(reported.contains(recording.id))
        #expect(!reported.contains(processing.id))
        #expect(reported.contains(stale.id))
        #expect(try db.meeting(id: recording.id)?.status == .interrupted)
        #expect(try db.meeting(id: processing.id)?.status == .failed)
        #expect(try db.tracks(meetingId: stale.id).count == 1)
        #expect(FileManager.default.fileExists(atPath: paths.meetingDirectory(processing.id).path))
    }

    @Test func libraryLockIsExclusiveUntilReleased() throws {
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var first: LibraryLock? = {
            if case .acquired(let lock) = LibraryLock.acquire(in: paths.root) { return lock }
            return nil
        }()
        #expect(first != nil)
        guard case .heldByAnotherInstance = LibraryLock.acquire(in: paths.root) else {
            Issue.record("Una segunda instancia obtuvo el mismo bloqueo")
            return
        }
        first = nil
        guard case .acquired = LibraryLock.acquire(in: paths.root) else {
            Issue.record("El bloqueo no se liberó")
            return
        }
    }

    @Test func blockedLibraryRefusesImportRecordingAndProcessing() async throws {
        let reason = LibraryStartupPolicy.sharedLibraryReason
        let router = AppRouter()
        router.importBlockedReason = reason
        router.isImporting = true
        #expect(!router.isImporting)
        #expect(router.blockedNotice == reason)

        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let paths = try AppFixture.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.inMemory()
        let settings = AppSettings(defaults: suite.defaults)
        let recording = RecordingController(importer: MeetingImportService(database: db, paths: paths), paths: paths,
                                            settings: settings, asr: ParakeetUltraProvider(),
                                            startCapture: { _ in Issue.record("La captura no debía empezar") })
        recording.blockedReason = reason
        await recording.start(title: "FIXTURE", target: .none, captureMicrophone: false)
        #expect(recording.state == .failed(reason))
        #expect(try db.meetingRows().isEmpty)

        let processing = ProcessingCoordinator(
            processor: MeetingProcessor(database: db, paths: paths, asr: ParakeetUltraProvider(),
                                        diarizer: DiarizationService(), recognizer: nil),
            settings: settings, database: db)
        processing.blockedReason = reason
        processing.enqueue("any")
        #expect(processing.active == nil && processing.queue.isEmpty)
        #expect(processing.notice?.message == reason)
    }
}
