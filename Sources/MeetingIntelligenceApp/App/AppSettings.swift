import Foundation
import MeetingAudio
import MeetingCore
import MeetingSpeech

/// Default source for the remote track when starting a recording.
enum DefaultCaptureMode: String, CaseIterable, Identifiable {
    /// The app currently in a call (detected), otherwise the user picks one.
    case callApp
    case systemWide
    case microphoneOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .callApp: "La app en llamada (detección automática)"
        case .systemWide: "Todo el sistema"
        case .microphoneOnly: "Solo micrófono"
        }
    }
}

/// User preferences (non-sensitive) persisted in UserDefaults.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var localUserName: String { didSet { defaults.set(localUserName, forKey: "localUserName") } }
    var defaultCaptureMode: DefaultCaptureMode { didSet { defaults.set(defaultCaptureMode.rawValue, forKey: "captureMode") } }
    /// Suggest recording when any app starts a call (never starts by itself).
    var suggestRecording: Bool { didSet { defaults.set(suggestRecording, forKey: "suggestRecording") } }
    /// Suggest stopping when the recorded app's call ends (never stops by itself).
    var suggestStop: Bool { didSet { defaults.set(suggestStop, forKey: "suggestStop") } }
    /// Also show suggestions as macOS notifications.
    var systemNotifications: Bool { didSet { defaults.set(systemNotifications, forKey: "systemNotifications") } }
    /// App group keys never suggested (e.g. a music or dictation app).
    var ignoredCallApps: [String] { didSet { defaults.set(ignoredCallApps, forKey: "ignoredCallApps") } }
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
    /// Acoustic rescoring of dictionary terms (downloads Parakeet CTC 110M on first use).
    var acousticVocabularyBoost: Bool { didSet { defaults.set(acousticVocabularyBoost, forKey: "acousticVocabularyBoost") } }
    /// Semantic chat retrieval with local embeddings (downloads multilingual-e5-small on first use).
    var semanticSearch: Bool { didSet { defaults.set(semanticSearch, forKey: "semanticSearch") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        localUserName = defaults.string(forKey: "localUserName") ?? NSFullUserName()
        // Recordings before v2 stored "teams": it maps to the detected call app.
        defaultCaptureMode = DefaultCaptureMode(rawValue: defaults.string(forKey: "captureMode") ?? "") ?? .callApp
        suggestRecording = defaults.object(forKey: "suggestRecording") as? Bool ?? true
        suggestStop = defaults.object(forKey: "suggestStop") as? Bool ?? true
        systemNotifications = defaults.object(forKey: "systemNotifications") as? Bool ?? true
        ignoredCallApps = defaults.stringArray(forKey: "ignoredCallApps") ?? []
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
        acousticVocabularyBoost = defaults.bool(forKey: "acousticVocabularyBoost")
        semanticSearch = defaults.bool(forKey: "semanticSearch")
    }

    var processingOptions: ProcessingOptions {
        var options = ProcessingOptions()
        options.language = language
        options.diarize = diarize
        options.detectMultipleLocalSpeakers = detectMultipleLocalSpeakers
        options.flagEcho = flagEcho
        options.acousticVocabularyBoost = acousticVocabularyBoost
        return options
    }
}
