import Foundation
public import GRDB

/// Everything the UI needs to render one meeting.
public struct MeetingDetail: Sendable, Hashable {
    public var meeting: Meeting
    public var tracks: [AudioTrack]
    public var video: VideoAsset? = nil
    public var transcripts: [Transcript]
    public var segments: [TranscriptSegment]
    public var speakers: [MeetingSpeaker]
    public var participants: [String: Participant]
    public var jobs: [ProcessingJob]
    public var pauses: [RecordingPause] = []

    /// Name for a segment's speaker. Never invents a name: unresolved clusters
    /// use their neutral label and unknown identities say so explicitly.
    public func speakerName(for segment: TranscriptSegment) -> String {
        if let pid = segment.participantId, let participant = participants[pid] {
            return participant.displayName
        }
        if let sid = segment.meetingSpeakerId, let speaker = speakers.first(where: { $0.id == sid }) {
            return speaker.defaultLabel
        }
        switch segment.source {
        case .localMicrophone: return "Micrófono local"
        case .remoteSystemAudio: return "Audio remoto"
        case .imported: return "Sin identificar"
        }
    }
}

public struct MeetingSummaryRow: Sendable, Hashable, Identifiable {
    public var meeting: Meeting
    public var segmentCount: Int
    public var speakerCount: Int
    public var openActionItems: Int
    public var id: String { meeting.id }
}

extension AppDatabase {
    // MARK: Meetings

    public func insert(meeting: Meeting, tracks: [AudioTrack]) throws {
        try writer.write { db in
            try meeting.insert(db)
            for track in tracks { try track.insert(db) }
        }
    }

    public func meeting(id: String) throws -> Meeting? {
        try reader.read { db in try Meeting.fetchOne(db, key: id) }
    }

    public func meetingDetail(id: String) throws -> MeetingDetail? {
        try reader.read { db in try Self.fetchDetail(db, id: id) }
    }

    public static func fetchDetail(_ db: Database, id: String) throws -> MeetingDetail? {
        guard let meeting = try Meeting.fetchOne(db, key: id) else { return nil }
        let tracks = try AudioTrack.filter(Column("meetingId") == id).order(Column("source")).fetchAll(db)
        let transcripts = try Transcript.filter(Column("meetingId") == id).order(Column("createdAt")).fetchAll(db)
        let activeTranscriptIDs = transcripts.filter { $0.supersededAt == nil }.map(\.id)
        let segments = try TranscriptSegment
            .filter(activeTranscriptIDs.contains(Column("transcriptId")))
            .order(Column("startTime"), Column("orderIndex"))
            .fetchAll(db)
        let speakers = try MeetingSpeaker.filter(Column("meetingId") == id)
            .order(Column("source"), Column("ordinal")).fetchAll(db)
        let participantIDs = Set(segments.compactMap(\.participantId) + speakers.compactMap(\.participantId))
        let participants = try Participant.filter(participantIDs.contains(Column("id"))).fetchAll(db)
        let jobs = try ProcessingJob.filter(Column("meetingId") == id).order(Column("startedAt")).fetchAll(db)
        let pauses = try RecordingPause.filter(Column("meetingId") == id).order(Column("startTime")).fetchAll(db)
        return MeetingDetail(
            meeting: meeting, tracks: tracks, video: try VideoAsset.fetchOne(db, key: id), transcripts: transcripts, segments: segments,
            speakers: speakers,
            participants: Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) }),
            jobs: jobs,
            pauses: pauses
        )
    }

    /// Live meeting detail for the UI.
    public func observeMeetingDetail(id: String) -> AsyncValueObservation<MeetingDetail?> {
        ValueObservation
            .tracking { db in try Self.fetchDetail(db, id: id) }
            .removeDuplicates()
            .values(in: reader)
    }

    public func observeMeetingRows() -> AsyncValueObservation<[MeetingSummaryRow]> {
        ValueObservation
            .tracking { db in try Self.fetchMeetingRows(db) }
            .removeDuplicates()
            .values(in: reader)
    }

    public func meetingRows() throws -> [MeetingSummaryRow] {
        try reader.read { db in try Self.fetchMeetingRows(db) }
    }

    static func fetchMeetingRows(_ db: Database) throws -> [MeetingSummaryRow] {
        let meetings = try Meeting.order(Column("createdAt").desc).fetchAll(db)
        let segmentCounts = try Row.fetchAll(db, sql: """
            SELECT s.meetingId AS id, COUNT(*) AS n FROM transcriptSegment s
            JOIN transcript t ON t.id = s.transcriptId AND t.supersededAt IS NULL
            GROUP BY s.meetingId
            """).reduce(into: [String: Int]()) { $0[$1["id"]] = $1["n"] }
        let speakerCounts = try Row.fetchAll(db, sql: """
            SELECT meetingId AS id, COUNT(*) AS n FROM meetingSpeaker GROUP BY meetingId
            """).reduce(into: [String: Int]()) { $0[$1["id"]] = $1["n"] }
        let openItems = try Row.fetchAll(db, sql: """
            SELECT meetingId AS id, COUNT(*) AS n FROM analysisItem
            WHERE category IN ('actionItem','commitment') AND completedAt IS NULL
            GROUP BY meetingId
            """).reduce(into: [String: Int]()) { $0[$1["id"]] = $1["n"] }
        return meetings.map {
            MeetingSummaryRow(meeting: $0,
                              segmentCount: segmentCounts[$0.id] ?? 0,
                              speakerCount: speakerCounts[$0.id] ?? 0,
                              openActionItems: openItems[$0.id] ?? 0)
        }
    }

    public func updateMeeting(id: String, _ change: @Sendable @escaping (inout Meeting) -> Void) throws {
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else {
                throw AppDatabaseError.notFound("reunión \(id)")
            }
            change(&meeting)
            meeting.updatedAt = Date()
            try meeting.update(db)
        }
    }

    public func renameMeeting(id: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try writer.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else { return }
            let previous = meeting.title
            guard previous != trimmed else { return }
            meeting.title = trimmed
            meeting.updatedAt = Date()
            try meeting.update(db)
            try CorrectionEvent(meetingId: id, entityType: "meeting", entityId: id, field: "title",
                                previousValue: previous, newValue: trimmed).insert(db)
        }
    }

    /// Deletes the meeting row (cascading to every dependent row: transcripts, speakers,
    /// analyses, chat, vectors…) and its audio folder. Voice samples enrolled from it stay on
    /// the participant's profile unless `includeVoiceSamples`.
    public func deleteMeeting(id: String, paths: AppPaths, includeVoiceSamples: Bool = false) throws {
        _ = try writer.write { db in
            if includeVoiceSamples {
                try db.execute(sql: "DELETE FROM voiceSample WHERE meetingId = ?", arguments: [id])
            }
            try Meeting.deleteOne(db, key: id)
        }
        let dir = paths.meetingDirectory(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Tracks

    public func tracks(meetingId: String) throws -> [AudioTrack] {
        try reader.read { db in try AudioTrack.filter(Column("meetingId") == meetingId).fetchAll(db) }
    }

    public func update(track: AudioTrack) throws {
        try writer.write { db in try track.update(db) }
    }

    // MARK: Transcripts

    /// Stores a new final transcript for a track, superseding (not deleting)
    /// earlier ones so prior ASR output remains auditable.
    public func replaceTranscript(_ transcript: Transcript, segments: [TranscriptSegment]) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE transcript SET supersededAt = ? WHERE trackId = ? AND supersededAt IS NULL
                """, arguments: [Date(), transcript.trackId])
            try transcript.insert(db)
            for segment in segments { try segment.insert(db) }
        }
    }

    /// Saves a user correction without touching the original ASR text.
    public func editSegmentText(segmentId: String, newText: String) throws {
        try writer.write { db in
            guard var segment = try TranscriptSegment.fetchOne(db, key: segmentId) else {
                throw AppDatabaseError.notFound("segmento \(segmentId)")
            }
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            let previous = segment.displayText
            guard trimmed != previous else { return }
            // Editing back to the machine text clears the edit instead of duplicating it.
            let machineText = segment.vocabularyText ?? segment.asrText
            segment.editedText = (trimmed == machineText) ? nil : trimmed
            segment.editedAt = segment.editedText == nil ? nil : Date()
            try segment.update(db)
            try CorrectionEvent(meetingId: segment.meetingId, entityType: "transcriptSegment",
                                entityId: segmentId, field: "text",
                                previousValue: previous, newValue: trimmed).insert(db)
        }
    }

    /// Discards the user edit, returning to the machine transcript.
    public func revertSegmentText(segmentId: String) throws {
        try writer.write { db in
            guard var segment = try TranscriptSegment.fetchOne(db, key: segmentId),
                  let edited = segment.editedText else { return }
            segment.editedText = nil
            segment.editedAt = nil
            try segment.update(db)
            try CorrectionEvent(meetingId: segment.meetingId, entityType: "transcriptSegment",
                                entityId: segmentId, field: "text.revert",
                                previousValue: edited, newValue: segment.displayText).insert(db)
        }
    }

    public func corrections(meetingId: String) throws -> [CorrectionEvent] {
        try reader.read { db in
            try CorrectionEvent.filter(Column("meetingId") == meetingId)
                .order(Column("createdAt").desc).fetchAll(db)
        }
    }

    // MARK: Processing jobs

    @discardableResult
    public func record(job: ProcessingJob) throws -> ProcessingJob {
        try writer.write { db in try job.save(db) }
        return job
    }

    public func recentJobs(limit: Int = 50) throws -> [ProcessingJob] {
        try reader.read { db in
            try ProcessingJob.order(Column("startedAt").desc).limit(limit).fetchAll(db)
        }
    }

    /// Meetings left in `recording`/`processing` by a crash are surfaced as interrupted/failed.
    public func recoverInterruptedMeetings() throws -> [String] {
        try writer.write { db in
            let stuck = try Meeting.filter([MeetingStatus.recording.rawValue, MeetingStatus.processing.rawValue]
                .contains(Column("status"))).fetchAll(db)
            for var meeting in stuck {
                meeting.status = meeting.status == .recording ? .interrupted : .failed
                meeting.lastError = meeting.status == .interrupted
                    ? "La aplicación se cerró durante la grabación. El audio escrito hasta ese momento se conservó."
                    : "El procesamiento se interrumpió. Puedes volver a procesar la reunión."
                meeting.updatedAt = Date()
                try meeting.update(db)
            }
            try db.execute(sql: """
                UPDATE processingJob SET status = 'failed', errorMessage = 'Interrumpido', finishedAt = ?
                WHERE status = 'running'
                """, arguments: [Date()])
            return stuck.map(\.id)
        }
    }

    // MARK: Participants

    public func participants() throws -> [Participant] {
        try reader.read { db in try Participant.order(Column("displayName").collating(.localizedCaseInsensitiveCompare)).fetchAll(db) }
    }

    public func observeParticipants() -> AsyncValueObservation<[Participant]> {
        ValueObservation
            .tracking { db in try Participant.order(Column("displayName").collating(.localizedCaseInsensitiveCompare)).fetchAll(db) }
            .removeDuplicates()
            .values(in: reader)
    }

    public func save(participant: Participant) throws {
        try writer.write { db in
            var p = participant
            p.updatedAt = Date()
            if p.isLocalUser {
                try db.execute(sql: "UPDATE participant SET isLocalUser = 0 WHERE id != ?", arguments: [p.id])
            }
            try p.save(db)
        }
    }

    public func localUser() throws -> Participant? {
        try reader.read { db in try Participant.filter(Column("isLocalUser") == true).fetchOne(db) }
    }

    /// Creates or renames the local-user participant used for the microphone track.
    @discardableResult
    public func setLocalUserName(_ name: String) throws -> Participant {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try writer.write { db in
            if var existing = try Participant.filter(Column("isLocalUser") == true).fetchOne(db) {
                existing.displayName = trimmed.isEmpty ? existing.displayName : trimmed
                existing.updatedAt = Date()
                try existing.update(db)
                return existing
            }
            let p = Participant(displayName: trimmed.isEmpty ? "Yo" : trimmed, isLocalUser: true)
            try p.insert(db)
            return p
        }
    }

    // MARK: Vocabulary

    public func vocabulary() throws -> [VocabularyTerm] {
        try reader.read { db in try VocabularyTerm.order(Column("canonical")).fetchAll(db) }
    }

    public func observeVocabulary() -> AsyncValueObservation<[VocabularyTerm]> {
        ValueObservation.tracking { db in try VocabularyTerm.order(Column("canonical")).fetchAll(db) }
            .removeDuplicates()
            .values(in: reader)
    }

    public func save(term: VocabularyTerm) throws {
        try writer.write { db in try term.save(db) }
    }

    public func deleteTerm(id: String) throws {
        _ = try writer.write { db in try VocabularyTerm.deleteOne(db, key: id) }
    }

    // MARK: AI provider configuration

    public func providerConfiguration(_ kind: AIProviderKind) throws -> AIProviderConfiguration {
        try reader.read { db in
            try AIProviderConfiguration.fetchOne(db, key: kind.rawValue)
        } ?? AIProviderConfiguration(provider: kind)
    }

    public func save(providerConfiguration: AIProviderConfiguration) throws {
        try writer.write { db in try providerConfiguration.save(db) }
    }
}
