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

    @Test func splitClustersBothInheritTheIdentity() {
        let previous = [ManualIdentityRemapper.PreviousIdentity(participantId: "katty", spans: [Span(start: 0, end: 20)])]
        let result = remapper.remap(previous: previous, newClusters: [
            "part-1": [Span(start: 0, end: 9)],
            "part-2": [Span(start: 10, end: 20)],
        ])
        #expect(result["part-1"]?.participantId == "katty")
        #expect(result["part-2"]?.participantId == "katty")
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
}
