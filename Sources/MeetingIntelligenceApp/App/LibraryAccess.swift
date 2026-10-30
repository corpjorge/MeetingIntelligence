import Darwin
import Foundation
import MeetingCore
import MeetingSpeech
import OSLog

nonisolated final class LibraryLock: Sendable {
    nonisolated enum Acquisition: Sendable {
        case acquired(LibraryLock)
        case heldByAnotherInstance
        case unavailable(String)
    }

    static let fileName = ".instance.lock"
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func acquire(in root: URL) -> Acquisition {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .unavailable(error.localizedDescription)
        }
        let descriptor = open(root.appendingPathComponent(fileName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .unavailable(String(cString: strerror(errno))) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK ? .heldByAnotherInstance : .unavailable(String(cString: strerror(code)))
        }
        return .acquired(LibraryLock(descriptor: descriptor))
    }
}

struct LibraryStartupPolicy: Equatable {
    enum LockState: Equatable {
        case exclusive
        case heldByAnotherInstance
        case unavailable
    }

    var runsMaintenance: Bool
    var sharedWithAnotherInstance: Bool
    var blockedReason: String?

    static let databaseUnavailableReason = "La biblioteca no se pudo abrir: grabar, importar y procesar están desactivados porque nada se guardaría. Cierra la app y vuelve a abrirla."

    static var sharedLibraryReason: String {
        "Otra copia de \(AppIdentity.displayName) ya tiene abierta esta biblioteca. Para no dañar sus grabaciones, aquí no se puede grabar, importar ni procesar: usa la otra copia o ciérrala y vuelve a abrir la app."
    }

    static func decide(databaseOpened: Bool, lock: LockState) -> LibraryStartupPolicy {
        if !databaseOpened {
            return LibraryStartupPolicy(runsMaintenance: false, sharedWithAnotherInstance: lock == .heldByAnotherInstance,
                                        blockedReason: databaseUnavailableReason)
        }
        if lock == .heldByAnotherInstance {
            return LibraryStartupPolicy(runsMaintenance: false, sharedWithAnotherInstance: true,
                                        blockedReason: sharedLibraryReason)
        }
        return LibraryStartupPolicy(runsMaintenance: true, sharedWithAnotherInstance: false, blockedReason: nil)
    }
}

struct StartupMaintenance {
    let database: AppDatabase
    let importer: MeetingImportService
    let paths: AppPaths
    let audioRetentionDays: Int?
    let videoRetentionDays: Int?
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "app")

    init(database: AppDatabase, importer: MeetingImportService, paths: AppPaths,
         audioRetentionDays: Int?, videoRetentionDays: Int?) {
        self.database = database
        self.importer = importer
        self.paths = paths
        self.audioRetentionDays = audioRetentionDays
        self.videoRetentionDays = videoRetentionDays
    }

    func run(policy: LibraryStartupPolicy) -> [String] {
        guard policy.runsMaintenance else { return [] }
        let interrupted: InterruptedMeetings
        do {
            interrupted = try database.recoverInterrupted()
        } catch {
            logger.error("Recovery failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var reported = interrupted.recordings
        var pending = interrupted.recordings
        do {
            pending += try database.interruptedMeetingIdsWithoutTracks().filter { !pending.contains($0) }
        } catch {
            logger.error("Could not list interrupted meetings: \(error.localizedDescription, privacy: .public)")
        }
        for id in pending {
            do {
                let recovered = try importer.recoverInterruptedRecording(meetingId: id)
                if recovered > 0, !reported.contains(id) { reported.append(id) }
                logger.notice("Recovered \(recovered) track(s) for interrupted meeting")
            } catch {
                logger.error("Recovery of an interrupted meeting failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        attempt("Profile retention") { try database.enforceProfileRetention() }
        attempt("Audio retention") { try AudioRetention(database: database, paths: paths).apply(days: audioRetentionDays) }
        attempt("Video retention") { try VideoRetention(database: database, paths: paths).apply(days: videoRetentionDays) }
        attempt("Cleanup") {
            let orphans = try StorageMaintenance.removeOrphanedRecordings(database: database, paths: paths)
            let temporary = StorageMaintenance.sweepTemporaryFiles()
            if orphans.removedItems + temporary.removedItems > 0 {
                logger.notice("Removed \(orphans.removedItems + temporary.removedItems) leftover item(s), \(orphans.freedBytes + temporary.freedBytes) bytes")
            }
        }
        return reported
    }

    private func attempt(_ step: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            logger.error("\(step, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
