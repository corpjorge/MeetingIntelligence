import Foundation
import GRDB
import Testing
@testable import MeetingCore

@Suite("Datos: hablantes, participantes y perfiles de voz")
struct DataSpeakerFixesTests {
    private func participant(_ db: AppDatabase, _ name: String) throws -> Participant {
        let participant = Participant(displayName: name)
        try db.save(participant: participant)
        return participant
    }

    private func speaker(_ db: AppDatabase, meetingId: String, key: String, ordinal: Int, participantId: String? = nil,
                         segments: [TranscriptSegment] = [], embedding: Data? = nil) throws -> MeetingSpeaker {
        let speaker = MeetingSpeaker(meetingId: meetingId, source: .imported, clusterKey: key, ordinal: ordinal,
                                     totalSpeechSeconds: segments.reduce(0) { $0 + $1.duration },
                                     embeddingCiphertext: embedding, embeddingModel: embedding == nil ? nil : "fixture",
                                     participantId: participantId)
        try db.writer.write { db in
            try speaker.insert(db)
            for segment in segments {
                try db.execute(sql: """
                    UPDATE transcriptSegment SET meetingSpeakerId = ?, diarizedSpeakerId = ?, participantId = ?,
                           attribution = ? WHERE id = ?
                    """, arguments: [speaker.id, speaker.id, participantId, participantId == nil ? "diarized" : "manual", segment.id])
            }
        }
        return speaker
    }

    private func sample(_ profile: SpeakerProfile) -> VoiceSample {
        VoiceSample(profileId: profile.id, origin: .enrollment, durationSeconds: 10,
                    embeddingCiphertext: Data([1, 2, 3]), embeddingModel: "fixture")
    }

    private func speechSeconds(_ db: AppDatabase, _ id: String) throws -> Double? {
        try db.reader.read { try Double.fetchOne($0, sql: "SELECT totalSpeechSeconds FROM meetingSpeaker WHERE id = ?", arguments: [id]) }
    }

    private func importedMeeting(_ db: AppDatabase) throws -> (Meeting, AudioTrack) {
        let meeting = Meeting(title: "FIXTURE · Reproceso", origin: .imported, captureScope: .importedFile, status: .ready)
        let track = AudioTrack(meetingId: meeting.id, source: .imported, relativePath: "Recordings/\(meeting.id)/imported.wav",
                               sampleRate: 16_000, channelCount: 1, durationSeconds: 60)
        try db.insert(meeting: meeting, tracks: [track])
        return (meeting, track)
    }

    private func processedTrack(_ meeting: Meeting, _ track: AudioTrack, text: String)
        -> (transcript: Transcript, speaker: MeetingSpeaker, segment: TranscriptSegment) {
        let transcript = Transcript(meetingId: meeting.id, trackId: track.id, engine: "fixture", modelIdentifier: "fixture",
                                    language: "es-CO", isFinal: true, audioDurationSeconds: 60, processingSeconds: 1,
                                    meanConfidence: nil)
        let speaker = MeetingSpeaker(meetingId: meeting.id, source: .imported, clusterKey: "S1", ordinal: 1, totalSpeechSeconds: 4)
        let segment = TranscriptSegment(transcriptId: transcript.id, meetingId: meeting.id, trackId: track.id, source: .imported,
                                        orderIndex: 0, startTime: 0, endTime: 4, asrText: text, meetingSpeakerId: speaker.id,
                                        attribution: .diarized)
        return (transcript, speaker, segment)
    }

    @Test func reprocessingArchivesReplacedAssignmentsAndStoresCorrections() throws {
        let db = try AppDatabase.inMemory()
        let katty = try participant(db, "FIXTURE Katty")
        let (meeting, track) = try importedMeeting(db)
        let first = processedTrack(meeting, track, text: "versión uno")
        let automatic = SpeakerAssignment(meetingId: meeting.id, meetingSpeakerId: first.speaker.id, participantId: nil,
                                          method: .automaticRecognition, decision: .unknown, similarity: 0.42, threshold: 0.7)
        try db.storeProcessedTrack(transcript: first.transcript, segments: [first.segment], speakers: [first.speaker],
                                   assignments: [automatic])
        try db.assignSpeaker(meetingSpeakerId: first.speaker.id, participantId: katty.id)
        let decisions = try db.assignments(meetingId: meeting.id)
        #expect(decisions.count == 2)

        let second = processedTrack(meeting, track, text: "versión dos")
        let carried = CorrectionEvent(meetingId: meeting.id, entityType: "transcriptSegment", entityId: second.segment.id,
                                      field: "text", previousValue: "versión dos", newValue: "versión corregida")
        try db.storeProcessedTrack(transcript: second.transcript, segments: [second.segment], speakers: [second.speaker],
                                   assignments: [], corrections: [carried])

        #expect(try db.assignments(meetingId: meeting.id).isEmpty)
        #expect(try db.corrections(meetingId: meeting.id).contains { $0.id == carried.id && $0.newValue == "versión corregida" })
        let archived = try db.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM speakerAssignmentArchive").reduce(into: [String: Row]()) { $0[$1["id"]] = $1 }
        }
        #expect(Set(archived.keys) == Set(decisions.map(\.id)))
        for row in archived.values {
            #expect(row["meetingId"] as String == meeting.id)
            #expect(row["meetingSpeakerId"] as String == first.speaker.id)
            #expect(row["speakerSource"] as String == AudioSource.imported.rawValue)
            #expect(row["speakerClusterKey"] as String == "S1")
            #expect(row["speakerOrdinal"] as Int == 1)
            #expect(row["archivedAt"] as Date? != nil)
        }
        let manual = try #require(decisions.first { $0.method == .manual })
        #expect(archived[manual.id]?["participantId"] as String? == katty.id)
        #expect(archived[manual.id]?["supersededAt"] as Date? == nil)
        #expect(archived[automatic.id]?["similarity"] as Double? == 0.42)
        #expect(archived[automatic.id]?["supersededAt"] as Date? != nil)

        _ = try db.writer.write { try Meeting.deleteOne($0, key: meeting.id) }
        #expect(try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM speakerAssignmentArchive") } == 0)
    }

    @Test func editedSegmentsComeOnlyFromActiveTranscriptsOfTheSource() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, track, _, segments) = try Fixture.meeting(db, texts: [("uno", 0, 1), ("dos", 2, 3), ("tres", 4, 5)])
        try db.editSegmentText(segmentId: segments[2].id, newText: "tres corregido")
        try db.editSegmentText(segmentId: segments[0].id, newText: "uno corregido")
        let edited = try db.editedSegments(meetingId: meeting.id, source: .imported)
        #expect(edited.map(\.id) == [segments[0].id, segments[2].id])
        #expect(edited.map(\.editedText) == ["uno corregido", "tres corregido"])
        #expect(edited.map(\.asrText) == ["uno", "tres"])
        #expect(try db.editedSegments(meetingId: meeting.id, source: .localMicrophone).isEmpty)

        let replacement = Transcript(meetingId: meeting.id, trackId: track.id, engine: "fixture", modelIdentifier: "fixture",
                                     language: "es-CO", isFinal: true, audioDurationSeconds: 5, processingSeconds: 1,
                                     meanConfidence: nil)
        try db.replaceTranscript(replacement, segments: [
            TranscriptSegment(transcriptId: replacement.id, meetingId: meeting.id, trackId: track.id, source: .imported,
                              orderIndex: 0, startTime: 0, endTime: 1, asrText: "uno"),
        ])
        #expect(try db.editedSegments(meetingId: meeting.id, source: .imported).isEmpty)
    }

    @Test func archiveMigrationRunsOverALibraryWithData() throws {
        let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(readOnly: false))
        try AppDatabase.migrator.migrate(queue, upTo: "v5-video-assets")
        let meeting = Meeting(title: "FIXTURE · Antes de v6", origin: .imported, captureScope: .importedFile, status: .ready)
        let track = AudioTrack(meetingId: meeting.id, source: .imported, relativePath: "Recordings/\(meeting.id)/imported.wav",
                               sampleRate: 16_000, channelCount: 1, durationSeconds: 60)
        let carlos = Participant(displayName: "FIXTURE Carlos")
        let oldSpeaker = MeetingSpeaker(meetingId: meeting.id, source: .imported, clusterKey: "S1", ordinal: 1,
                                        totalSpeechSeconds: 4, participantId: carlos.id)
        let decision = SpeakerAssignment(meetingId: meeting.id, meetingSpeakerId: oldSpeaker.id, participantId: carlos.id,
                                         method: .manual, decision: .accepted, note: "Corrección manual")
        try queue.write { db in
            try meeting.insert(db)
            try track.insert(db)
            try carlos.insert(db)
            try oldSpeaker.insert(db)
            try decision.insert(db)
        }
        #expect(try queue.read { try $0.tableExists("speakerAssignmentArchive") } == false)

        let db = try AppDatabase(queue)
        #expect(try queue.read { try AppDatabase.migrator.appliedIdentifiers($0) }.contains("v6-speaker-assignment-archive"))
        #expect(try queue.read { try $0.tableExists("speakerAssignmentArchive") })
        #expect(try db.assignments(meetingId: meeting.id).map(\.id) == [decision.id])
        #expect(try db.meetingSpeakers(meetingId: meeting.id).map(\.id) == [oldSpeaker.id])
        #expect(try queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check") }.isEmpty)
        #expect(try queue.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") } == "ok")

        let reprocessed = processedTrack(meeting, track, text: "hola")
        try db.storeProcessedTrack(transcript: reprocessed.transcript, segments: [reprocessed.segment],
                                   speakers: [reprocessed.speaker], assignments: [])
        let archived = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM speakerAssignmentArchive") }
        #expect(archived.count == 1)
        #expect(archived.first?["id"] as String? == decision.id)
        #expect(archived.first?["participantId"] as String? == carlos.id)
        #expect(archived.first?["method"] as String? == "manual")
        #expect(archived.first?["note"] as String? == "Corrección manual")
    }

    @Test func retentionCountsFromTheLastConsentSampleOrMatch() throws {
        let db = try AppDatabase.inMemory()
        let now = Date()
        let old = now.addingTimeInterval(-100 * 86_400)
        let reconsented = try participant(db, "FIXTURE Re-consentimiento")
        let unused = try participant(db, "FIXTURE Sin uso")
        let laterRetention = try participant(db, "FIXTURE Conservación nueva")
        let newSample = try participant(db, "FIXTURE Muestra nueva")
        let setups: [(Participant, Int?)] = [(reconsented, 90), (unused, 90), (laterRetention, nil), (newSample, 90)]
        for (person, retention) in setups {
            let profile = try db.createProfile(participantId: person.id, consentStatement: "fixture", retentionDays: retention)
            try db.add(sample: sample(profile))
            try db.writer.write { db in
                try db.execute(sql: """
                    UPDATE speakerProfile SET lastMatchedAt = ?, consentRecordedAt = ?, updatedAt = ? WHERE participantId = ?
                    """, arguments: [old, old, old, person.id])
            }
        }
        try db.createProfile(participantId: reconsented.id, consentStatement: "fixture, de nuevo", retentionDays: 90)
        try db.createProfile(participantId: laterRetention.id, consentStatement: "fixture", retentionDays: 90)
        try db.add(sample: sample(try #require(try db.profile(participantId: newSample.id))))

        #expect(try db.enforceProfileRetention(now: now) == [unused.id])
        #expect(try db.profile(participantId: unused.id)?.status == .revoked)
        for person in [reconsented, laterRetention, newSample] {
            let profile = try #require(try db.profile(participantId: person.id))
            #expect(profile.status == .active)
            #expect(try db.samples(profileId: profile.id).isEmpty == false)
        }
        let later = try db.enforceProfileRetention(now: now.addingTimeInterval(91 * 86_400))
        #expect(Set(later) == [reconsented.id, laterRetention.id, newSample.id])
    }

    @Test func revokingOrDeletingRemovesClusterVoiceprints() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [("uno", 0, 4), ("dos", 5, 9), ("tres", 10, 14),
                                                                        ("cuatro", 15, 19)])
        let revoked = try participant(db, "FIXTURE Revoca")
        let expired = try participant(db, "FIXTURE Caduca")
        let deleted = try participant(db, "FIXTURE Eliminado")
        let other = try participant(db, "FIXTURE Otra")
        let voiceprint = Data([9, 9, 9])
        var speakers: [String: String] = [:]
        for (index, person) in [revoked, expired, deleted, other].enumerated() {
            speakers[person.id] = try speaker(db, meetingId: meeting.id, key: "S\(index + 1)", ordinal: index + 1,
                                              participantId: person.id, segments: [segments[index]], embedding: voiceprint).id
            let profile = try db.createProfile(participantId: person.id, consentStatement: "fixture",
                                               retentionDays: person.id == expired.id ? 30 : nil)
            try db.add(sample: sample(profile))
        }
        func embedding(_ person: Participant) throws -> Data? {
            try db.reader.read {
                try Data.fetchOne($0, sql: "SELECT embeddingCiphertext FROM meetingSpeaker WHERE id = ?", arguments: [speakers[person.id]])
            }
        }

        try db.revokeProfile(participantId: revoked.id)
        #expect(try embedding(revoked) == nil)
        #expect(try db.profile(participantId: revoked.id)?.status == .revoked)

        #expect(try db.enforceProfileRetention(now: Date().addingTimeInterval(31 * 86_400)) == [expired.id])
        #expect(try embedding(expired) == nil)

        try db.deleteParticipant(id: deleted.id)
        #expect(try embedding(deleted) == nil)
        #expect(try db.meetingSpeakers(meetingId: meeting.id).first { $0.id == speakers[deleted.id] }?.participantId == nil)

        #expect(try embedding(other) == voiceprint)
        #expect(try db.samples(profileId: try #require(try db.profile(participantId: other.id)).id).count == 1)
    }

    @Test func speechSecondsFollowTheCurrentSegments() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [("uno", 0, 4), ("eco", 4, 5), ("dos", 5, 9),
                                                                        ("tres", 10, 12)])
        let first = try speaker(db, meetingId: meeting.id, key: "S1", ordinal: 1, segments: [segments[0], segments[1]])
        let second = try speaker(db, meetingId: meeting.id, key: "S2", ordinal: 2, segments: [segments[2], segments[3]])
        try db.writer.write { db in
            try db.execute(sql: "UPDATE transcriptSegment SET attribution = 'probableEcho' WHERE id = ?", arguments: [segments[1].id])
        }
        for _ in 0..<3 {
            try db.mergeSpeakers(second.id, into: first.id)
            #expect(try speechSeconds(db, first.id) == 10)
            #expect(try speechSeconds(db, second.id) == 0)
            try db.splitSpeaker(second.id)
            #expect(try speechSeconds(db, first.id) == 4)
            #expect(try speechSeconds(db, second.id) == 6)
        }
        try db.moveSegment(segmentId: segments[3].id, toMeetingSpeakerId: first.id)
        #expect(try speechSeconds(db, first.id) == 6)
        #expect(try speechSeconds(db, second.id) == 4)
    }

    @Test func undoingAParticipantMergeKeepsManualIdentities() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [("hola", 0, 4)])
        let katty = try participant(db, "FIXTURE Katty")
        let other = try participant(db, "FIXTURE Katherine")
        let cluster = try speaker(db, meetingId: meeting.id, key: "S1", ordinal: 1, segments: [segments[0]])
        try db.assignSpeaker(meetingSpeakerId: cluster.id, participantId: katty.id)
        let archivedId = UUID().uuidString
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO speakerAssignmentArchive (id, meetingId, meetingSpeakerId, speakerSource, speakerClusterKey,
                    speakerOrdinal, participantId, method, decision, createdAt, archivedAt)
                VALUES (?, ?, 'FIXTURE-OLD', 'imported', 'S9', 9, ?, 'manual', 'accepted', ?, ?)
                """, arguments: [archivedId, meeting.id, katty.id, Date(), Date()])
        }
        func archivedOwner() throws -> String? {
            try db.reader.read {
                try String.fetchOne($0, sql: "SELECT participantId FROM speakerAssignmentArchive WHERE id = ?", arguments: [archivedId])
            }
        }

        let merge = try db.mergeParticipants(katty.id, into: other.id)
        #expect(try db.manualIdentities(meetingId: meeting.id, source: .imported).map(\.participantId) == [other.id])
        #expect(try archivedOwner() == other.id)

        try db.undoParticipantMerge(eventId: merge.id)
        #expect(try db.manualIdentities(meetingId: meeting.id, source: .imported).map(\.participantId) == [katty.id])
        #expect(try db.assignments(meetingId: meeting.id).allSatisfy { $0.participantId == katty.id })
        #expect(try archivedOwner() == katty.id)
    }

    @Test func undoneMergesDisappearAndCannotBeUndoneAgain() throws {
        let db = try AppDatabase.inMemory()
        let from = try participant(db, "FIXTURE Juan duplicado")
        let into = try participant(db, "FIXTURE Juan")
        let merge = try db.mergeParticipants(from.id, into: into.id)
        #expect(try db.participantMergeEvents().map(\.id) == [merge.id])

        try db.undoParticipantMerge(eventId: merge.id)
        #expect(try db.participantMergeEvents().isEmpty)
        let again = #expect(throws: AppDatabaseError.self) { try db.undoParticipantMerge(eventId: merge.id) }
        #expect(again?.localizedDescription == "Esta fusión ya se deshizo; no se puede separar de nuevo.")

        try db.deleteParticipant(id: from.id)
        #expect(throws: AppDatabaseError.self) { try db.undoParticipantMerge(eventId: merge.id) }
        #expect(try db.participants().contains { $0.id == from.id } == false)
    }

    @Test func mergesUndoneByEarlierVersionsAreRecognized() throws {
        let db = try AppDatabase.inMemory()
        let from = try participant(db, "FIXTURE Ana duplicada")
        let into = try participant(db, "FIXTURE Ana")
        let first = try db.mergeParticipants(from.id, into: into.id)
        let past = Date().addingTimeInterval(-60)
        try db.writer.write { db in
            try db.execute(sql: "UPDATE correctionEvent SET createdAt = ? WHERE id = ?", arguments: [past, first.id])
            try from.insert(db)
            try CorrectionEvent(meetingId: nil, entityType: "participant", entityId: from.id, field: "unmerge",
                                previousValue: into.id, newValue: from.id, createdAt: past.addingTimeInterval(30)).insert(db)
        }
        #expect(try db.participantMergeEvents().isEmpty)
        #expect(throws: AppDatabaseError.self) { try db.undoParticipantMerge(eventId: first.id) }

        let second = try db.mergeParticipants(from.id, into: into.id)
        #expect(try db.participantMergeEvents().map(\.id) == [second.id])
        try db.undoParticipantMerge(eventId: second.id)
        #expect(try db.participants().filter { $0.id == from.id }.count == 1)
        #expect(try db.participantMergeEvents().isEmpty)
    }

    @Test func deletingAParticipantPurgesMergeRecordsWithItsData() throws {
        let db = try AppDatabase.inMemory()
        let alias = try participant(db, "FIXTURE Alias uno")
        let middle = try participant(db, "FIXTURE Alias dos")
        let person = try participant(db, "FIXTURE Persona")
        let separated = try participant(db, "FIXTURE Separada")
        let unrelatedFrom = try participant(db, "FIXTURE Otro duplicado")
        let unrelatedInto = try participant(db, "FIXTURE Otro")
        try db.mergeParticipants(alias.id, into: middle.id)
        try db.mergeParticipants(middle.id, into: person.id)
        let undone = try db.mergeParticipants(separated.id, into: person.id)
        try db.undoParticipantMerge(eventId: undone.id)
        let unrelated = try db.mergeParticipants(unrelatedFrom.id, into: unrelatedInto.id)

        try db.deleteParticipant(id: person.id)
        let events = try db.reader.read { try CorrectionEvent.fetchAll($0) }
        #expect(events.map(\.id) == [unrelated.id])
        #expect(events.allSatisfy { event in
            ["Alias", "Persona", "Separada"].allSatisfy { !(event.previousValue ?? "").contains($0) }
        })
        #expect(try db.participantMergeEvents().map(\.id) == [unrelated.id])
        #expect(try db.participants().contains { $0.id == separated.id })
    }

    @Test func mergingIntoARevokedProfileKeepsTheActiveConsent() throws {
        let db = try AppDatabase.inMemory()
        let from = try participant(db, "FIXTURE Juan (duplicado)")
        let into = try participant(db, "FIXTURE Juan")
        let active = try db.createProfile(participantId: from.id, consentStatement: "consentimiento vigente", retentionDays: 180)
        try db.add(sample: sample(active))
        let stub = try db.createProfile(participantId: into.id, consentStatement: "consentimiento antiguo", retentionDays: nil)
        try db.add(sample: sample(stub))
        try db.revokeProfile(participantId: into.id)

        try db.mergeParticipants(from.id, into: into.id)
        let profile = try #require(try db.profile(participantId: into.id))
        #expect(profile.id == active.id)
        #expect(profile.status == .active)
        #expect(profile.consentStatement == "consentimiento vigente")
        #expect(try db.samples(profileId: profile.id).count == 1)
        #expect(try db.reader.read { try SpeakerProfile.fetchCount($0) } == 1)
        #expect(try db.activeVoiceSamples(embeddingModel: "fixture").map(\.profile.participantId) == [into.id])
    }

    @Test func revokedDuplicateNeverReplacesAnActiveProfile() throws {
        let db = try AppDatabase.inMemory()
        let from = try participant(db, "FIXTURE Luisa (duplicada)")
        let into = try participant(db, "FIXTURE Luisa")
        let stub = try db.createProfile(participantId: from.id, consentStatement: "consentimiento antiguo", retentionDays: nil)
        try db.add(sample: sample(stub))
        try db.revokeProfile(participantId: from.id)
        let active = try db.createProfile(participantId: into.id, consentStatement: "consentimiento vigente", retentionDays: nil)
        try db.add(sample: sample(active))

        try db.mergeParticipants(from.id, into: into.id)
        let profile = try #require(try db.profile(participantId: into.id))
        #expect(profile.id == active.id)
        #expect(profile.status == .active)
        #expect(try db.samples(profileId: profile.id).count == 1)
        #expect(try db.reader.read { try SpeakerProfile.fetchCount($0) } == 1)
    }

    @Test func localUserMarkMovesWithTheMergeAndComesBackOnce() throws {
        let db = try AppDatabase.inMemory()
        let me = try db.setLocalUserName("FIXTURE Yo")
        let full = try participant(db, "FIXTURE Jorge")
        let merge = try db.mergeParticipants(me.id, into: full.id)
        #expect(try db.localUser()?.id == full.id)
        try db.undoParticipantMerge(eventId: merge.id)
        #expect(try db.participants().filter(\.isLocalUser).map(\.id) == [me.id])

        let second = try db.mergeParticipants(me.id, into: full.id)
        let someoneElse = Participant(displayName: "FIXTURE Nuevo usuario", isLocalUser: true)
        try db.save(participant: someoneElse)
        try db.undoParticipantMerge(eventId: second.id)
        #expect(try db.participants().filter(\.isLocalUser).map(\.id) == [someoneElse.id])
        #expect(try db.participants().contains { $0.id == me.id })
    }

    @Test func enrollmentWritesProfileAndSampleTogether() throws {
        let db = try AppDatabase.inMemory()
        let ana = try participant(db, "FIXTURE Ana")
        let bea = try participant(db, "FIXTURE Bea")
        _ = try db.createProfile(participantId: ana.id, consentStatement: "Consentimiento previo", retentionDays: nil)
        try db.revokeProfile(participantId: ana.id)
        let beaProfile = try db.createProfile(participantId: bea.id, consentStatement: "Consentimiento de Bea", retentionDays: nil)
        let beaSample = sample(beaProfile)
        try db.add(sample: beaSample)

        #expect(throws: (any Error).self) {
            try db.enrollSample(participantId: ana.id, consentStatement: "Consentimiento nuevo", retentionDays: 90) { profileId in
                VoiceSample(id: beaSample.id, profileId: profileId, origin: .enrollment, durationSeconds: 10,
                            embeddingCiphertext: Data([1, 2, 3]), embeddingModel: "fixture")
            }
        }
        let afterFailure = try #require(try db.profile(participantId: ana.id))
        #expect(afterFailure.status == .revoked)
        #expect(afterFailure.consentStatement == "Consentimiento previo")
        #expect(try db.samples(profileId: afterFailure.id).isEmpty)

        let enrolled = try db.enrollSample(participantId: ana.id, consentStatement: "Consentimiento nuevo", retentionDays: 90) { profileId in
            VoiceSample(profileId: profileId, origin: .enrollment, durationSeconds: 10,
                        embeddingCiphertext: Data([4, 5, 6]), embeddingModel: "fixture")
        }
        let active = try #require(try db.profile(participantId: ana.id))
        #expect(active.status == .active && active.retentionDays == 90)
        #expect(try db.samples(profileId: active.id).map(\.id) == [enrolled.id])
    }
}
