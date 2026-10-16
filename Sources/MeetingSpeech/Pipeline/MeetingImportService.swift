public import Foundation
public import MeetingAudio
public import MeetingCore

/// Creates meetings from imported files or finished recordings.
public struct MeetingImportService: Sendable {
    public let database: AppDatabase
    public let paths: AppPaths

    public init(database: AppDatabase, paths: AppPaths) {
        self.database = database
        self.paths = paths
    }

    /// Copies/extracts the file into the library and inserts a `recorded` meeting.
    public func importAudio(at url: URL, title: String? = nil, language: String = "es-CO") async throws -> Meeting {
        var meeting = Meeting(
            title: title ?? url.deletingPathExtension().lastPathComponent,
            origin: .imported, captureScope: .importedFile, status: .recorded, language: language)
        let fileDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate]) as? Date
        meeting.startedAt = fileDate
        let track: AudioTrack
        do {
            track = try await AudioImporter(paths: paths).importFile(url, meetingId: meeting.id)
        } catch {
            try? FileManager.default.removeItem(at: paths.meetingDirectory(meeting.id))
            throw error
        }
        meeting.durationSeconds = track.durationSeconds
        try database.insert(meeting: meeting, tracks: [track])
        return meeting
    }

    /// Inserts the meeting row at recording start so a crash leaves a recoverable entry.
    public func beginRecording(title: String, scope: CaptureScope, language: String = "es-CO") throws -> Meeting {
        let meeting = Meeting(title: title, startedAt: Date(), origin: .recording, captureScope: scope,
                              status: .recording, language: language)
        try database.insert(meeting: meeting, tracks: [])
        try paths.prepareMeetingDirectory(meeting.id)
        return meeting
    }

    /// Registers the finished WAV files and marks the meeting as recorded.
    public func finishRecording(meetingId: String, result: RecordingResult) throws {
        let tracks: [AudioTrack] = result.tracks.compactMap { stats in
            guard FileManager.default.fileExists(atPath: stats.url.path) else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: stats.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            var detail: [String] = []
            if stats.source == .remoteSystemAudio, let d = result.remoteProcessDescription { detail.append(d) }
            if stats.paddedSeconds > 0.05 { detail.append(String(format: "%.1f s de silencio insertado para sincronizar", stats.paddedSeconds)) }
            if stats.droppedSeconds > 0.05 { detail.append(String(format: "%.2f s descartados por deriva de reloj", stats.droppedSeconds)) }
            if !stats.inputSampleRates.isEmpty {
                detail.append("Entrada: " + stats.inputSampleRates.map { "\(Int($0)) Hz" }.joined(separator: ", "))
            }
            return AudioTrack(meetingId: meetingId, source: stats.source,
                              relativePath: paths.relativePath(for: stats.url) ?? stats.url.lastPathComponent,
                              sampleRate: 16_000, channelCount: 1, durationSeconds: stats.durationSeconds,
                              timelineOffsetSeconds: 0,
                              deviceName: stats.source == .localMicrophone ? result.inputDeviceName : nil,
                              captureDetail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                              fileSizeBytes: size)
        }
        try database.writer.write { db in
            for track in tracks { try track.insert(db) }
        }
        try database.updateMeeting(id: meetingId) {
            $0.status = .recorded
            $0.endedAt = Date()
            $0.durationSeconds = result.durationSeconds
            $0.captureScope = result.captureScope
        }
    }

    /// After a crash: repairs WAV headers left by an interrupted recording and
    /// registers whatever audio was written.
    public func recoverInterruptedRecording(meetingId: String) throws -> Int {
        let dir = paths.meetingDirectory(meetingId)
        let existing = try database.tracks(meetingId: meetingId)
        guard existing.isEmpty else { return 0 }
        var recovered: [AudioTrack] = []
        for source in [AudioSource.localMicrophone, .remoteSystemAudio] {
            let url = dir.appendingPathComponent("\(source.fileStem).wav")
            guard FileManager.default.fileExists(atPath: url.path),
                  let duration = try? WAVRepair.repairHeader(at: url), duration > 0.5 else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            recovered.append(AudioTrack(meetingId: meetingId, source: source,
                                        relativePath: paths.relativePath(for: url) ?? url.lastPathComponent,
                                        sampleRate: 16_000, channelCount: 1, durationSeconds: duration,
                                        captureDetail: "Recuperado tras cierre inesperado", fileSizeBytes: size))
        }
        try database.writer.write { db in for t in recovered { try t.insert(db) } }
        if let longest = recovered.map(\.durationSeconds).max() {
            try database.updateMeeting(id: meetingId) { $0.durationSeconds = longest }
        }
        return recovered.count
    }
}
