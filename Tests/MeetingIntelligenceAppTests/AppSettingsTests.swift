import Foundation
import MeetingCore
import Testing
@testable import MeetingIntelligenceApp

@Suite("App: preferencias")
struct AppSettingsTests {
    @Test func freshInstallUsesSafeDefaults() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let settings = AppSettings(defaults: suite.defaults)
        #expect(settings.defaultCaptureMode == .callApp)
        // Suggestions only: recording never starts or stops by itself.
        #expect(settings.suggestRecording && settings.suggestStop)
        #expect(settings.requireConsentConfirmation)
        #expect(!settings.hasCompletedOnboarding)
        #expect(settings.audioRetentionDays == nil && settings.defaultProfileRetentionDays == nil)
        // Model downloads are opt-in.
        #expect(!settings.acousticVocabularyBoost && !settings.semanticSearch)
        #expect(settings.diarizationStepRatio == 0.1)
        #expect(settings.language == "es-CO")
        #expect(settings.ignoredCallApps.isEmpty)
    }

    @Test func preferencesPersistAcrossLaunches() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let first = AppSettings(defaults: suite.defaults)
        first.localUserName = "Persona de prueba"
        first.defaultCaptureMode = .microphoneOnly
        first.suggestStop = false
        first.ignoredCallApps = ["com.example.music"]
        first.audioRetentionDays = 30
        first.defaultProfileRetentionDays = 180
        first.diarizationStepRatio = 0.2
        first.semanticSearch = true
        first.hasCompletedOnboarding = true

        let second = AppSettings(defaults: suite.defaults)
        #expect(second.localUserName == "Persona de prueba")
        #expect(second.defaultCaptureMode == .microphoneOnly)
        #expect(!second.suggestStop)
        #expect(second.ignoredCallApps == ["com.example.music"])
        #expect(second.audioRetentionDays == 30 && second.defaultProfileRetentionDays == 180)
        #expect(second.diarizationStepRatio == 0.2)
        #expect(second.semanticSearch && second.hasCompletedOnboarding)

        // "Keep forever" is stored as 0 and read back as nil.
        second.audioRetentionDays = nil
        #expect(AppSettings(defaults: suite.defaults).audioRetentionDays == nil)
    }

    @Test func legacyCaptureModeMapsToDetectedCallApp() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        suite.defaults.set("teams", forKey: "captureMode") // stored before v2
        #expect(AppSettings(defaults: suite.defaults).defaultCaptureMode == .callApp)
    }

    @Test func processingOptionsFollowSettings() throws {
        let suite = try IsolatedDefaults()
        defer { suite.remove() }
        let settings = AppSettings(defaults: suite.defaults)
        settings.language = "es-ES"
        settings.diarize = false
        settings.detectMultipleLocalSpeakers = false
        settings.flagEcho = false
        settings.acousticVocabularyBoost = true
        let options = settings.processingOptions
        #expect(options.language == "es-ES")
        #expect(!options.diarize && !options.detectMultipleLocalSpeakers && !options.flagEcho)
        #expect(options.acousticVocabularyBoost)
    }
}
