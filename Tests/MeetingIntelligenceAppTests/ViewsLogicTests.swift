import Foundation
import MeetingAudio
import Testing
@testable import MeetingCore
@testable import MeetingIntelligenceApp

@Suite("App: lógica de las vistas")
struct ViewsLogicTests {
    @Test func transcriptDraftSurvivesSwitchingSegmentsAndReappearing() throws {
        let db = try AppDatabase.inMemory()
        let (meetingId, segments) = try Self.meeting(db, texts: ["Primer fragmento", "Segundo fragmento"])
        let model = MeetingDetailModel()
        model.detail = try db.meetingDetail(id: meetingId)
        let first = segments[0]
        let second = segments[1]

        model.beginEditing(first)
        #expect(model.editingSegmentId == first.id)
        let draft = try #require(model.segmentDrafts[first.id])
        #expect(draft.text == "Primer fragmento")
        draft.text = "Primer fragmento corregido"

        model.beginEditing(first)
        #expect(model.segmentDrafts[first.id]?.text == "Primer fragmento corregido")

        model.beginEditing(second)
        #expect(model.editingSegmentId == second.id)
        #expect(model.hasUnsavedDraft(first.id))
        #expect(model.segmentDrafts[first.id]?.text == "Primer fragmento corregido")

        model.beginEditing(first)
        #expect(model.editingSegmentId == first.id)
        #expect(model.segmentDrafts[first.id]?.text == "Primer fragmento corregido")
        #expect(model.segmentDrafts[second.id] == nil)

        model.discardDraft(first.id)
        #expect(model.editingSegmentId == nil)
        #expect(model.segmentDrafts.isEmpty)
    }

    @Test func unchangedDraftIsNotReportedAsUnsaved() throws {
        let db = try AppDatabase.inMemory()
        let (meetingId, segments) = try Self.meeting(db, texts: ["Texto original"])
        let model = MeetingDetailModel()
        model.detail = try db.meetingDetail(id: meetingId)

        model.beginEditing(segments[0])
        let draft = try #require(model.segmentDrafts[segments[0].id])
        draft.text = "Texto original  \n"
        #expect(!model.hasUnsavedDraft(segments[0].id))
        draft.text = "Texto revisado"
        #expect(model.hasUnsavedDraft(segments[0].id))

        model.resetEdits()
        #expect(model.editingSegmentId == nil)
        #expect(model.segmentDrafts.isEmpty)
        #expect(!model.hasUnsavedDraft(segments[0].id))
    }

    @Test func meetingBeingRecordedIsProtected() {
        let ready = Meeting(title: "FIXTURE", origin: .imported, captureScope: .importedFile, status: .ready)
        let live = Meeting(title: "FIXTURE", origin: .recording, captureScope: .microphoneOnly, status: .recording)
        #expect(MeetingDeletion.isRecording(live, recordingMeetingId: nil))
        #expect(MeetingDeletion.isRecording(ready, recordingMeetingId: ready.id))
        #expect(!MeetingDeletion.isRecording(ready, recordingMeetingId: nil))
        #expect(!MeetingDeletion.isRecording(ready, recordingMeetingId: live.id))
    }

    @Test func recordingFormResetsOnlyAfterARecordingEnds() {
        #expect(RecordingView.recordingEnded(from: .stopping, to: .idle))
        #expect(RecordingView.recordingEnded(from: .recording, to: .idle))
        #expect(RecordingView.recordingEnded(from: .paused, to: .idle))
        #expect(RecordingView.recordingEnded(from: .stopping, to: .failed("No se pudo registrar")))
        #expect(!RecordingView.recordingEnded(from: .starting, to: .failed("Sin permiso")))
        #expect(!RecordingView.recordingEnded(from: .starting, to: .idle))
        #expect(!RecordingView.recordingEnded(from: .starting, to: .recording))
        #expect(!RecordingView.recordingEnded(from: .recording, to: .stopping))
        #expect(!RecordingView.recordingEnded(from: .idle, to: .starting))
    }

    @Test func identityDecisionsAreLabelledInSpanish() {
        #expect(SpeakersTab.decisionLabel(.accepted) == "aceptada")
        #expect(SpeakersTab.decisionLabel(.suggested) == "sugerida")
        #expect(SpeakersTab.decisionLabel(.rejected) == "rechazada")
        #expect(SpeakersTab.decisionLabel(.unknown) == "sin coincidencia")
    }

    @Test func deviceTransportsAreLabelledInSpanish() {
        #expect(AudioSettings.transportLabel(.builtIn) == "integrado")
        #expect(AudioSettings.transportLabel(.usb) == "USB")
        #expect(AudioSettings.transportLabel(.bluetooth) == "Bluetooth")
        #expect(AudioSettings.transportLabel(.bluetoothLE) == "Bluetooth LE")
        #expect(AudioSettings.transportLabel(.virtual) == "virtual")
        #expect(AudioSettings.transportLabel(.aggregate) == "agregado")
        #expect(AudioSettings.transportLabel(.airPlay) == "AirPlay")
        #expect(AudioSettings.transportLabel(.other) == "otro")
    }

    private static func meeting(_ db: AppDatabase, texts: [String]) throws -> (String, [TranscriptSegment]) {
        let meeting = Meeting(title: "FIXTURE · Edición", origin: .imported, captureScope: .importedFile, status: .ready)
        let track = AudioTrack(meetingId: meeting.id, source: .imported, relativePath: "Recordings/\(meeting.id)/imported.wav",
                               sampleRate: 16_000, channelCount: 1, durationSeconds: 60)
        try db.insert(meeting: meeting, tracks: [track])
        let transcript = Transcript(meetingId: meeting.id, trackId: track.id, engine: "fixture", modelIdentifier: "fixture",
                                    language: "es-CO", isFinal: true, audioDurationSeconds: 60, processingSeconds: 1,
                                    meanConfidence: 0.9)
        let segments = texts.enumerated().map { index, text in
            TranscriptSegment(transcriptId: transcript.id, meetingId: meeting.id, trackId: track.id, source: .imported,
                              orderIndex: index, startTime: Double(index * 5), endTime: Double(index * 5 + 4), asrText: text)
        }
        try db.replaceTranscript(transcript, segments: segments)
        return (meeting.id, segments)
    }
}
