public import Foundation
import GRDB

public struct ParticipantMergeRecord: Codable, Sendable {
    public var fromParticipant: Participant
    public var intoParticipantId: String
    public var segmentIds: [String]
    public var meetingSpeakerIds: [String]
    public var analysisItemIds: [String]
    public var profileMoved: Bool
}

extension AppDatabase {
    // MARK: Pipeline output

    /// Atomically stores one processed track: supersedes earlier transcripts of
    /// the track, replaces that source's diarized speakers, inserts new rows.
    public func storeProcessedTrack(transcript: Transcript, segments: [TranscriptSegment],
                                    speakers: [MeetingSpeaker], assignments: [SpeakerAssignment]) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE transcript SET supersededAt = ? WHERE trackId = ? AND supersededAt IS NULL",
                           arguments: [Date(), transcript.trackId])
            let source = segments.first?.source.rawValue ?? speakers.first?.source.rawValue
            if let source {
                try db.execute(sql: "DELETE FROM meetingSpeaker WHERE meetingId = ? AND source = ?",
                               arguments: [transcript.meetingId, source])
            }
            for speaker in speakers { try speaker.insert(db) }
            try transcript.insert(db)
            for segment in segments { try segment.insert(db) }
            for assignment in assignments { try assignment.insert(db) }
        }
    }

    public func meetingSpeakers(meetingId: String) throws -> [MeetingSpeaker] {
        try reader.read { db in
            try MeetingSpeaker.filter(Column("meetingId") == meetingId).order(Column("source"), Column("ordinal")).fetchAll(db)
        }
    }

    public func assignments(meetingId: String) throws -> [SpeakerAssignment] {
        try reader.read { db in
            try SpeakerAssignment.filter(Column("meetingId") == meetingId).order(Column("createdAt").desc).fetchAll(db)
        }
    }

    // MARK: Identity decisions

    /// Records an automatic recognition decision. Only `.accepted` changes the transcript.
    public func applyRecognition(meetingSpeakerId: String, decision: MatchDecision) throws {
        try writer.write { db in
            guard var speaker = try MeetingSpeaker.fetchOne(db, key: meetingSpeakerId) else { return }
            try db.execute(sql: "UPDATE speakerAssignment SET supersededAt = ? WHERE meetingSpeakerId = ? AND supersededAt IS NULL",
                           arguments: [Date(), meetingSpeakerId])
            let outcome: AssignmentDecision = switch decision.outcome {
            case .accepted: .accepted
            case .suggested: .suggested
            case .unknown: .unknown
            }
            try SpeakerAssignment(meetingId: speaker.meetingId, meetingSpeakerId: meetingSpeakerId,
                                  participantId: decision.best?.participantId, method: .automaticRecognition,
                                  decision: outcome, similarity: decision.best?.similarity, margin: decision.margin,
                                  threshold: decision.threshold, note: decision.reason).insert(db)
            guard decision.outcome == .accepted, let pid = decision.best?.participantId else { return }
            speaker.participantId = pid
            try speaker.update(db)
            try db.execute(sql: """
                UPDATE transcriptSegment SET participantId = ?, attribution = 'recognized', speakerConfidence = ?
                WHERE meetingSpeakerId = ? AND attribution = 'diarized'
                """, arguments: [pid, decision.best?.similarity, meetingSpeakerId])
            try db.execute(sql: "UPDATE speakerProfile SET lastMatchedAt = ? WHERE participantId = ?", arguments: [Date(), pid])
        }
    }

    /// Manual identity for a meeting speaker (nil = mark as unknown participant).
    public func assignSpeaker(meetingSpeakerId: String, participantId: String?) throws {
        try writer.write { db in
            guard var speaker = try MeetingSpeaker.fetchOne(db, key: meetingSpeakerId) else {
                throw AppDatabaseError.notFound("hablante \(meetingSpeakerId)")
            }
            let previous = speaker.participantId
            try db.execute(sql: "UPDATE speakerAssignment SET supersededAt = ? WHERE meetingSpeakerId = ? AND supersededAt IS NULL",
                           arguments: [Date(), meetingSpeakerId])
            try SpeakerAssignment(meetingId: speaker.meetingId, meetingSpeakerId: meetingSpeakerId, participantId: participantId,
                                  method: .manual, decision: participantId == nil ? .unknown : .accepted,
                                  note: "Corrección manual").insert(db)
            speaker.participantId = participantId
            try speaker.update(db)
            if let participantId {
                try db.execute(sql: """
                    UPDATE transcriptSegment SET participantId = ?, attribution = 'manual', speakerConfidence = NULL
                    WHERE meetingSpeakerId = ? AND attribution NOT IN ('probableEcho')
                    """, arguments: [participantId, meetingSpeakerId])
            } else {
                try db.execute(sql: """
                    UPDATE transcriptSegment SET participantId = NULL, attribution = 'diarized', speakerConfidence = NULL
                    WHERE meetingSpeakerId = ? AND attribution IN ('manual','recognized','localUserTrack')
                    """, arguments: [meetingSpeakerId])
            }
            try CorrectionEvent(meetingId: speaker.meetingId, entityType: "meetingSpeaker", entityId: meetingSpeakerId,
                                field: "participantId", previousValue: previous, newValue: participantId).insert(db)
        }
    }

    /// Reassigns one segment to another speaker of the same meeting.
    public func moveSegment(segmentId: String, toMeetingSpeakerId targetId: String) throws {
        try writer.write { db in
            guard var segment = try TranscriptSegment.fetchOne(db, key: segmentId),
                  let target = try MeetingSpeaker.fetchOne(db, key: targetId),
                  target.meetingId == segment.meetingId else {
                throw AppDatabaseError.invalidOperation("El segmento y el hablante deben pertenecer a la misma reunión.")
            }
            let previous = segment.meetingSpeakerId
            segment.meetingSpeakerId = targetId
            segment.participantId = target.participantId
            segment.attribution = target.participantId == nil ? .diarized : .manual
            segment.speakerConfidence = nil
            try segment.update(db)
            try CorrectionEvent(meetingId: segment.meetingId, entityType: "transcriptSegment", entityId: segmentId,
                                field: "meetingSpeakerId", previousValue: previous, newValue: targetId).insert(db)
        }
    }

    /// Merges two diarization clusters that are the same person (over-split).
    public func mergeSpeakers(_ sourceId: String, into targetId: String) throws {
        try writer.write { db in
            guard let source = try MeetingSpeaker.fetchOne(db, key: sourceId),
                  var target = try MeetingSpeaker.fetchOne(db, key: targetId),
                  source.meetingId == target.meetingId, sourceId != targetId else {
                throw AppDatabaseError.invalidOperation("Solo se pueden fusionar hablantes distintos de la misma reunión.")
            }
            let attribution = target.participantId == nil ? "diarized" : "manual"
            try db.execute(sql: """
                UPDATE transcriptSegment SET meetingSpeakerId = ?, participantId = ?,
                       attribution = CASE WHEN attribution = 'probableEcho' THEN attribution ELSE ? END
                WHERE meetingSpeakerId = ?
                """, arguments: [targetId, target.participantId, attribution, sourceId])
            target.totalSpeechSeconds += source.totalSpeechSeconds
            try target.update(db)
            try SpeakerAssignment(meetingId: source.meetingId, meetingSpeakerId: sourceId, participantId: target.participantId,
                                  method: .merge, decision: .accepted, note: "Fusionado en \(target.defaultLabel)").insert(db)
            try CorrectionEvent(meetingId: source.meetingId, entityType: "meetingSpeaker", entityId: sourceId,
                                field: "mergeInto", previousValue: nil, newValue: targetId).insert(db)
        }
    }

    /// Undoes merges/moves: every segment originally diarized as `speakerId`
    /// returns to it (its own identity, or unknown).
    public func splitSpeaker(_ speakerId: String) throws {
        try writer.write { db in
            guard let speaker = try MeetingSpeaker.fetchOne(db, key: speakerId) else {
                throw AppDatabaseError.notFound("hablante \(speakerId)")
            }
            let attribution = speaker.participantId == nil ? "diarized" : "manual"
            try db.execute(sql: """
                UPDATE transcriptSegment SET meetingSpeakerId = diarizedSpeakerId, participantId = ?,
                       attribution = CASE WHEN attribution = 'probableEcho' THEN attribution ELSE ? END
                WHERE diarizedSpeakerId = ? AND meetingSpeakerId IS NOT diarizedSpeakerId
                """, arguments: [speaker.participantId, attribution, speakerId])
            try SpeakerAssignment(meetingId: speaker.meetingId, meetingSpeakerId: speakerId, participantId: speaker.participantId,
                                  method: .split, decision: speaker.participantId == nil ? .unknown : .accepted,
                                  note: "Segmentos restaurados a su hablante original").insert(db)
            try CorrectionEvent(meetingId: speaker.meetingId, entityType: "meetingSpeaker", entityId: speakerId,
                                field: "split", previousValue: nil, newValue: speakerId).insert(db)
        }
    }

    // MARK: Participants merge / undo

    /// Merges a duplicate participant into another, recording everything needed to undo it.
    @discardableResult
    public func mergeParticipants(_ fromId: String, into intoId: String) throws -> CorrectionEvent {
        try writer.write { db in
            guard fromId != intoId,
                  let from = try Participant.fetchOne(db, key: fromId),
                  try Participant.exists(db, key: intoId) else {
                throw AppDatabaseError.invalidOperation("Selecciona dos participantes distintos.")
            }
            let segmentIds = try String.fetchAll(db, sql: "SELECT id FROM transcriptSegment WHERE participantId = ?", arguments: [fromId])
            let speakerIds = try String.fetchAll(db, sql: "SELECT id FROM meetingSpeaker WHERE participantId = ?", arguments: [fromId])
            let itemIds = try String.fetchAll(db, sql: "SELECT id FROM analysisItem WHERE ownerParticipantId = ?", arguments: [fromId])
            let fromProfile = try SpeakerProfile.filter(Column("participantId") == fromId).fetchOne(db)
            let intoProfile = try SpeakerProfile.filter(Column("participantId") == intoId).fetchOne(db)
            var profileMoved = false
            if let fromProfile {
                if let intoProfile {
                    try db.execute(sql: "UPDATE voiceSample SET profileId = ? WHERE profileId = ?", arguments: [intoProfile.id, fromProfile.id])
                    try fromProfile.delete(db)
                } else {
                    var moved = fromProfile
                    moved.participantId = intoId
                    try moved.update(db)
                }
                profileMoved = true
            }
            try db.execute(sql: "UPDATE transcriptSegment SET participantId = ? WHERE participantId = ?", arguments: [intoId, fromId])
            try db.execute(sql: "UPDATE meetingSpeaker SET participantId = ? WHERE participantId = ?", arguments: [intoId, fromId])
            try db.execute(sql: "UPDATE analysisItem SET ownerParticipantId = ? WHERE ownerParticipantId = ?", arguments: [intoId, fromId])
            try db.execute(sql: "UPDATE speakerAssignment SET participantId = ? WHERE participantId = ?", arguments: [intoId, fromId])
            try from.delete(db)
            let record = ParticipantMergeRecord(fromParticipant: from, intoParticipantId: intoId, segmentIds: segmentIds,
                                                meetingSpeakerIds: speakerIds, analysisItemIds: itemIds, profileMoved: profileMoved)
            let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            let event = CorrectionEvent(meetingId: nil, entityType: "participant", entityId: fromId,
                                        field: "mergeInto", previousValue: json, newValue: intoId)
            try event.insert(db)
            return event
        }
    }

    /// Separates a wrongly merged participant: recreates it and restores its
    /// transcript/speaker references. Voice samples merged into the other
    /// profile cannot be told apart and stay there (reported to the user).
    public func undoParticipantMerge(eventId: String) throws {
        try writer.write { db in
            guard let event = try CorrectionEvent.fetchOne(db, key: eventId), event.field == "mergeInto",
                  event.entityType == "participant", let json = event.previousValue,
                  let record = try? JSONDecoder().decode(ParticipantMergeRecord.self, from: Data(json.utf8)) else {
                throw AppDatabaseError.invalidOperation("No hay una fusión que deshacer.")
            }
            try record.fromParticipant.insert(db)
            let pid = record.fromParticipant.id
            for id in record.segmentIds {
                try db.execute(sql: "UPDATE transcriptSegment SET participantId = ? WHERE id = ?", arguments: [pid, id])
            }
            for id in record.meetingSpeakerIds {
                try db.execute(sql: "UPDATE meetingSpeaker SET participantId = ? WHERE id = ?", arguments: [pid, id])
            }
            for id in record.analysisItemIds {
                try db.execute(sql: "UPDATE analysisItem SET ownerParticipantId = ? WHERE id = ?", arguments: [pid, id])
            }
            try CorrectionEvent(meetingId: nil, entityType: "participant", entityId: pid, field: "unmerge",
                                previousValue: record.intoParticipantId, newValue: pid).insert(db)
        }
    }

    public func participantMergeEvents() throws -> [CorrectionEvent] {
        try reader.read { db in
            try CorrectionEvent.filter(Column("entityType") == "participant" && Column("field") == "mergeInto")
                .order(Column("createdAt").desc).fetchAll(db)
        }
    }

    /// Deletes a participant everywhere (segments become "unknown"), including
    /// their biometric profile and samples.
    public func deleteParticipant(id: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE transcriptSegment SET attribution = 'diarized', speakerConfidence = NULL
                WHERE participantId = ? AND attribution IN ('recognized','manual','localUserTrack')
                """, arguments: [id])
            _ = try Participant.deleteOne(db, key: id) // cascades profile + samples, nulls references
        }
    }

    // MARK: Voice profiles (biometric)

    public func profile(participantId: String) throws -> SpeakerProfile? {
        try reader.read { db in try SpeakerProfile.filter(Column("participantId") == participantId).fetchOne(db) }
    }

    public func samples(profileId: String) throws -> [VoiceSample] {
        try reader.read { db in try VoiceSample.filter(Column("profileId") == profileId).order(Column("createdAt")).fetchAll(db) }
    }

    @discardableResult
    public func createProfile(participantId: String, consentStatement: String, retentionDays: Int?) throws -> SpeakerProfile {
        try writer.write { db in
            if var existing = try SpeakerProfile.filter(Column("participantId") == participantId).fetchOne(db) {
                existing.status = .active
                existing.consentStatement = consentStatement
                existing.consentRecordedAt = Date()
                existing.retentionDays = retentionDays
                existing.updatedAt = Date()
                try existing.update(db)
                return existing
            }
            let profile = SpeakerProfile(participantId: participantId, consentStatement: consentStatement,
                                         retentionDays: retentionDays)
            try profile.insert(db)
            return profile
        }
    }

    public func add(sample: VoiceSample) throws {
        try writer.write { db in
            guard let profile = try SpeakerProfile.fetchOne(db, key: sample.profileId), profile.status == .active else {
                throw AppDatabaseError.invalidOperation("El perfil no está activo; se requiere consentimiento vigente.")
            }
            try sample.insert(db)
        }
    }

    public func deleteSample(id: String) throws {
        _ = try writer.write { db in try VoiceSample.deleteOne(db, key: id) }
    }

    /// Revokes consent: deletes every embedding and keeps an audit stub.
    public func revokeProfile(participantId: String) throws {
        try writer.write { db in
            guard var profile = try SpeakerProfile.filter(Column("participantId") == participantId).fetchOne(db) else { return }
            try db.execute(sql: "DELETE FROM voiceSample WHERE profileId = ?", arguments: [profile.id])
            profile.status = .revoked
            profile.updatedAt = Date()
            try profile.update(db)
        }
    }

    /// Removes the profile entirely (no audit stub) and any meeting-cluster
    /// embeddings already matched to this participant.
    public func deleteProfile(participantId: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM speakerProfile WHERE participantId = ?", arguments: [participantId])
            try db.execute(sql: "UPDATE meetingSpeaker SET embeddingCiphertext = NULL WHERE participantId = ?", arguments: [participantId])
        }
    }

    /// Active profiles with samples of the given embedding model.
    public func activeVoiceSamples(embeddingModel: String) throws -> [(profile: SpeakerProfile, samples: [VoiceSample])] {
        try reader.read { db in
            let profiles = try SpeakerProfile.filter(Column("status") == ProfileStatus.active.rawValue).fetchAll(db)
            return try profiles.map { p in
                (p, try VoiceSample.filter(Column("profileId") == p.id && Column("embeddingModel") == embeddingModel).fetchAll(db))
            }.filter { !$0.1.isEmpty }
        }
    }

    /// Applies per-profile retention: profiles unused for longer than their
    /// retention period lose their samples (revoked). Returns affected participant IDs.
    @discardableResult
    public func enforceProfileRetention(now: Date = Date()) throws -> [String] {
        let expired = try reader.read { db in
            try SpeakerProfile.filter(Column("status") == ProfileStatus.active.rawValue && Column("retentionDays") != nil).fetchAll(db)
                .filter { p in
                    let last = p.lastMatchedAt ?? p.updatedAt
                    return now.timeIntervalSince(last) > Double(p.retentionDays ?? 0) * 86_400
                }
        }
        for profile in expired { try revokeProfile(participantId: profile.participantId) }
        return expired.map(\.participantId)
    }
}
