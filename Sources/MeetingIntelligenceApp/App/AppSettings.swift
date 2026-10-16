import Foundation
import MeetingAudio
import MeetingCore
import MeetingSpeech

/// User preferences (non-sensitive) persisted in UserDefaults.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var localUserName: String { didSet { defaults.set(localUserName, forKey: "localUserName") } }
    var defaultRemoteTarget: RemoteCaptureTarget { didSet { defaults.set(defaultRemoteTarget.rawValue, forKey: "remoteTarget") } }
    var microphoneVoiceProcessing: Bool { didSet { defaults.set(microphoneVoiceProcessing, forKey: "voiceProcessing") } }
    var autoProcessAfterRecording: Bool { didSet { defaults.set(autoProcessAfterRecording, forKey: "autoProcess") } }
    var detectMultipleLocalSpeakers: Bool { didSet { defaults.set(detectMultipleLocalSpeakers, forKey: "localDiarization") } }
    var flagEcho: Bool { didSet { defaults.set(flagEcho, forKey: "flagEcho") } }
    var diarize: Bool { didSet { defaults.set(diarize, forKey: "diarize") } }
    var diarizationStepRatio: Double { didSet { defaults.set(diarizationStepRatio, forKey: "diarizationStepRatio") } }
    /// nil = keep audio forever.
    var audioRetentionDays: Int? { didSet { defaults.set(audioRetentionDays ?? 0, forKey: "audioRetentionDays") } }
    var defaultProfileRetentionDays: Int? { didSet { defaults.set(defaultProfileRetentionDays ?? 0, forKey: "profileRetentionDays") } }
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var requireConsentConfirmation: Bool { didSet { defaults.set(requireConsentConfirmation, forKey: "consentConfirmation") } }
    var showProbableEcho: Bool { didSet { defaults.set(showProbableEcho, forKey: "showEcho") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "onboarded") } }
    var liveTranscription: Bool { didSet { defaults.set(liveTranscription, forKey: "liveTranscription") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        localUserName = defaults.string(forKey: "localUserName") ?? NSFullUserName()
        defaultRemoteTarget = RemoteCaptureTarget(rawValue: defaults.string(forKey: "remoteTarget") ?? "") ?? .teams
        microphoneVoiceProcessing = defaults.object(forKey: "voiceProcessing") as? Bool ?? false
        autoProcessAfterRecording = defaults.object(forKey: "autoProcess") as? Bool ?? true
        detectMultipleLocalSpeakers = defaults.object(forKey: "localDiarization") as? Bool ?? true
        flagEcho = defaults.object(forKey: "flagEcho") as? Bool ?? true
        diarize = defaults.object(forKey: "diarize") as? Bool ?? true
        diarizationStepRatio = defaults.object(forKey: "diarizationStepRatio") as? Double ?? 0.1
        let audioDays = defaults.integer(forKey: "audioRetentionDays")
        audioRetentionDays = audioDays > 0 ? audioDays : nil
        let profileDays = defaults.integer(forKey: "profileRetentionDays")
        defaultProfileRetentionDays = profileDays > 0 ? profileDays : nil
        language = defaults.string(forKey: "language") ?? "es-CO"
        requireConsentConfirmation = defaults.object(forKey: "consentConfirmation") as? Bool ?? true
        showProbableEcho = defaults.object(forKey: "showEcho") as? Bool ?? false
        hasCompletedOnboarding = defaults.bool(forKey: "onboarded")
        liveTranscription = defaults.object(forKey: "liveTranscription") as? Bool ?? true
    }

    var processingOptions: ProcessingOptions {
        var options = ProcessingOptions()
        options.language = language
        options.diarize = diarize
        options.detectMultipleLocalSpeakers = detectMultipleLocalSpeakers
        options.flagEcho = flagEcho
        return options
    }
}
