import Foundation
import Testing
@testable import MeetingCore

@Suite("Identidades manuales al reprocesar")
struct ManualIdentityTests {
    private typealias Span = ManualIdentityRemapper.Span
    private let remapper = ManualIdentityRemapper()

    @Test func cleanRemapFollowsTemporalOverlap() {
        let previous = [
            ManualIdentityRemapper.PreviousIdentity(participantId: "katty", spans: [Span(start: 0, end: 5), Span(start: 11, end: 17)]),
            ManualIdentityRemapper.PreviousIdentity(participantId: "carlos", spans: [Span(start: 5.5, end: 10), Span(start: 17.5, end: 22)]),
        ]
        // New cluster boundaries jitter slightly against the old ones.
        let result = remapper.remap(previous: previous, newClusters: [
            "new-a": [Span(start: 0.2, end: 4.9), Span(start: 11.1, end: 16.8)],
            "new-b": [Span(start: 5.6, end: 10.2), Span(start: 17.6, end: 21.9)],
        ])
        #expect(result["new-a"]?.participantId == "katty")
        #expect(result["new-b"]?.participantId == "carlos")
        #expect((result["new-a"]?.share ?? 0) > 0.95)
    }

    @Test func ambiguousOrWeakOverlapIsNotApplied() {
        let previous = [
            ManualIdentityRemapper.PreviousIdentity(participantId: "katty", spans: [Span(start: 0, end: 5)]),
            ManualIdentityRemapper.PreviousIdentity(participantId: "carlos", spans: [Span(start: 5, end: 10)]),
        ]
        let result = remapper.remap(previous: previous, newClusters: [
            "tie": [Span(start: 2.5, end: 7.5)],          // 50 % / 50 % → ambiguous
            "weak": [Span(start: 4, end: 5), Span(start: 30, end: 40)], // ≈ 9 % → too little evidence
            "none": [Span(start: 50, end: 60)],
        ])
        #expect(result.isEmpty)
    }

    @Test func unevenSplitOnlyMajorityPartInherits() {
        let previous = [ManualIdentityRemapper.PreviousIdentity(participantId: "katty", spans: [Span(start: 0, end: 20)])]
        let result = remapper.remap(previous: previous, newClusters: [
            "major": [Span(start: 0, end: 14)], // 70 % of Katty's previous speech
            "minor": [Span(start: 15, end: 20)], // 25 % → may be someone else
        ])
        #expect(result["major"]?.participantId == "katty")
        #expect(result["minor"] == nil)
    }

    @Test func evenSplitIsAmbiguous() {
        let previous = [ManualIdentityRemapper.PreviousIdentity(participantId: "katty", spans: [Span(start: 0, end: 20)])]
        let result = remapper.remap(previous: previous, newClusters: [
            "part-1": [Span(start: 0, end: 10)],
            "part-2": [Span(start: 10, end: 20)],
        ])
        #expect(result.isEmpty)
    }

    @Test func personAbsorbedByANamedClusterStaysUnknown() {
        // The old "Katty" cluster also held Juan (10–14 s); re-processing separates him.
        let previous = [
            ManualIdentityRemapper.PreviousIdentity(participantId: "katty", spans: [Span(start: 0, end: 10), Span(start: 10, end: 14)]),
            ManualIdentityRemapper.PreviousIdentity(participantId: "carlos", spans: [Span(start: 20, end: 30)]),
        ]
        let result = remapper.remap(previous: previous, newClusters: [
            "katty": [Span(start: 0, end: 10)],
            "juan": [Span(start: 10, end: 14)],
            "carlos": [Span(start: 20, end: 30)],
        ])
        #expect(result["katty"]?.participantId == "katty")
        #expect(result["juan"] == nil) // never "Katty"
        #expect(result["carlos"]?.participantId == "carlos")
    }

    @Test func speakersNamedAlikeKeepTheirName() {
        // The user named two over-split clusters as the same person.
        let previous = [
            ManualIdentityRemapper.PreviousIdentity(participantId: "katty", spans: [Span(start: 0, end: 10)]),
            ManualIdentityRemapper.PreviousIdentity(participantId: "katty", spans: [Span(start: 20, end: 30)]),
        ]
        let stillSplit = remapper.remap(previous: previous, newClusters: [
            "x": [Span(start: 0, end: 10)],
            "y": [Span(start: 20, end: 30)],
        ])
        #expect(stillSplit["x"]?.participantId == "katty")
        #expect(stillSplit["y"]?.participantId == "katty")
        let joined = remapper.remap(previous: previous, newClusters: ["z": [Span(start: 0, end: 10), Span(start: 20, end: 30)]])
        #expect(joined["z"]?.participantId == "katty")
    }

    @Test func overlappingSpansAreNotDoubleCounted() {
        let a = [Span(start: 0, end: 10)]
        let b = [Span(start: 0, end: 6), Span(start: 4, end: 10)] // overlapping previous spans
        #expect(abs(ManualIdentityRemapper.overlap(a, b) - 10) < 1e-9)
    }

    @Test func onlyCurrentManualAssignmentsAreCaptured() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [("hola", 0, 4), ("adiós", 5, 9)])
        let katty = Participant(displayName: "FIXTURE Katty")
        let carlos = Participant(displayName: "FIXTURE Carlos")
        try db.save(participant: katty)
        try db.save(participant: carlos)
        let manual = MeetingSpeaker(meetingId: meeting.id, source: .imported, clusterKey: "S1", ordinal: 1, totalSpeechSeconds: 4)
        let automatic = MeetingSpeaker(meetingId: meeting.id, source: .imported, clusterKey: "S2", ordinal: 2, totalSpeechSeconds: 4)
        try db.writer.write { db in
            try manual.insert(db)
            try automatic.insert(db)
            try db.execute(sql: "UPDATE transcriptSegment SET meetingSpeakerId = ? WHERE id = ?", arguments: [manual.id, segments[0].id])
            try db.execute(sql: "UPDATE transcriptSegment SET meetingSpeakerId = ? WHERE id = ?", arguments: [automatic.id, segments[1].id])
        }
        try db.assignSpeaker(meetingSpeakerId: manual.id, participantId: katty.id)
        try db.applyRecognition(meetingSpeakerId: automatic.id, decision: MatchDecision(
            outcome: .accepted, best: MatchCandidate(participantId: carlos.id, similarity: 0.9), runnerUp: nil,
            threshold: 0.7, reason: "test"))

        let captured = try db.manualIdentities(meetingId: meeting.id, source: .imported)
        #expect(captured.map(\.participantId) == [katty.id]) // automatic recognition is not carried over
        #expect(captured.first?.spans == [ManualIdentityRemapper.Span(start: 0, end: 4)])
    }

    @Test func manualIdentitySurvivesUndoneMerge() throws {
        let db = try AppDatabase.inMemory()
        let (meeting, _, _, segments) = try Fixture.meeting(db, texts: [("hola", 0, 4), ("adiós", 5, 9)])
        let carlos = Participant(displayName: "FIXTURE Carlos")
        try db.save(participant: carlos)
        let first = MeetingSpeaker(meetingId: meeting.id, source: .imported, clusterKey: "S1", ordinal: 1, totalSpeechSeconds: 4)
        let second = MeetingSpeaker(meetingId: meeting.id, source: .imported, clusterKey: "S2", ordinal: 2, totalSpeechSeconds: 4)
        try db.writer.write { db in
            try first.insert(db)
            try second.insert(db)
            try db.execute(sql: "UPDATE transcriptSegment SET meetingSpeakerId = ?, diarizedSpeakerId = ? WHERE id = ?",
                           arguments: [first.id, first.id, segments[0].id])
            try db.execute(sql: "UPDATE transcriptSegment SET meetingSpeakerId = ?, diarizedSpeakerId = ? WHERE id = ?",
                           arguments: [second.id, second.id, segments[1].id])
        }
        try db.assignSpeaker(meetingSpeakerId: second.id, participantId: carlos.id)
        try db.mergeSpeakers(second.id, into: first.id) // mistaken merge…
        try db.splitSpeaker(second.id)                  // …undone: a `.split` row is now the latest

        let captured = try db.manualIdentities(meetingId: meeting.id, source: .imported)
        #expect(captured.map(\.participantId) == [carlos.id])
        #expect(captured.first?.spans == [ManualIdentityRemapper.Span(start: 5, end: 9)])
    }
}
