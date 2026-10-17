import Testing
@testable import MeetingAudio

@Suite("Recordatorio de silencio en la llamada")
struct CallMuteReminderTests {
    @Test func onlyWhileTheMicrophoneIsWrittenDuringACall() {
        #expect(CallMuteReminder.isRelevant(capturesMicrophone: true, capturesRemoteAudio: true,
                                            microphonePaused: false, dismissed: false))
        // Microphone only (in-person): there is no call app to be muted in.
        #expect(!CallMuteReminder.isRelevant(capturesMicrophone: true, capturesRemoteAudio: false,
                                             microphonePaused: false, dismissed: false))
        // Microphone not recorded, or already paused here: nothing to warn about.
        #expect(!CallMuteReminder.isRelevant(capturesMicrophone: false, capturesRemoteAudio: true,
                                             microphonePaused: false, dismissed: false))
        #expect(!CallMuteReminder.isRelevant(capturesMicrophone: true, capturesRemoteAudio: true,
                                             microphonePaused: true, dismissed: false))
        #expect(!CallMuteReminder.isRelevant(capturesMicrophone: true, capturesRemoteAudio: true,
                                             microphonePaused: false, dismissed: true))
    }

    @Test func namesTheAppAndTheOwnPauseControl() {
        #expect(CallMuteReminder.title(appName: "Microsoft Teams") == "Silenciarte en Microsoft Teams no pausa tu micrófono aquí")
        #expect(CallMuteReminder.title(appName: nil) == "Silenciarte en la llamada no pausa tu micrófono aquí")
        let message = CallMuteReminder.message(appName: "zoom.us")
        #expect(message.contains("silenciado en zoom.us"))
        #expect(message.contains("Pausar mi micrófono") && message.contains("⌃⌘M"))
    }
}
