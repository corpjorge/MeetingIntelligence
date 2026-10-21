import Foundation
import MeetingCore
import OSLog

/// App-side orchestration of AI providers: detection, selection, consent and runs.
@Observable
final class AIController {
    struct ConsentRequest: Identifiable {
        let id = UUID()
        let provider: AIProviderKind
        let summary: String
        let characterCount: Int
        let onConfirm: () -> Void
    }

    private(set) var statuses: [AIProviderKind: ProviderStatus] = [:]
    private(set) var isDetecting = false
    private(set) var runningAnalyses: Set<String> = []
    private(set) var lastError: String?
    var pendingConsent: ConsentRequest?
    var selectedProvider: AIProviderKind {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "aiProvider") }
    }

    private let database: AppDatabase
    private var tasks: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "ai")

    init(database: AppDatabase) {
        self.database = database
        selectedProvider = AIProviderKind(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .claudeCode
    }

    func configuration(for kind: AIProviderKind) -> AIProviderConfiguration {
        _ = configurationRevision // observation dependency
        return (try? database.providerConfiguration(kind)) ?? AIProviderConfiguration(provider: kind)
    }

    /// Bumped on every save so views reading `configuration(for:)` refresh.
    private(set) var configurationRevision = 0

    func save(_ configuration: AIProviderConfiguration) {
        try? database.save(providerConfiguration: configuration)
        configurationRevision += 1
        // Ollama's levels depend on the selected model.
        if configuration.provider == .ollama {
            Task { statuses[.ollama] = await AIProviders.provider(for: .ollama).detect(configuration: configuration) }
        }
    }

    func refreshStatuses() async {
        guard !isDetecting else { return }
        isDetecting = true
        defer { isDetecting = false }
        await withTaskGroup(of: ProviderStatus.self) { group in
            for kind in AIProviderKind.allCases {
                let config = configuration(for: kind)
                group.addTask { await AIProviders.provider(for: kind).detect(configuration: config) }
            }
            for await status in group {
                statuses[status.kind] = status
                var config = configuration(for: status.kind)
                config.lastDetectedVersion = status.version
                config.lastCheckedAt = Date()
                save(config)
            }
        }
    }

    func dismissError() { lastError = nil }

    // MARK: Analysis

    func isAnalyzing(_ meetingId: String) -> Bool { runningAnalyses.contains(meetingId) }

    /// Prepares the prompt, asks for consent when the provider is remote, then runs.
    func analyze(meetingId: String, previousMeetingIds: [String] = []) {
        let kind = selectedProvider
        let config = configuration(for: kind)
        let service = MeetingAnalysisService(database: database)
        let prepared: MeetingAnalysisService.PreparedPrompt
        do {
            prepared = try service.prepare(meetingId: meetingId, previousMeetingIds: previousMeetingIds,
                                           model: config.model, effort: config.effort, timeout: config.timeoutSeconds)
        } catch {
            lastError = error.localizedDescription
            return
        }
        let start: () -> Void = { [weak self] in
            self?.startAnalysis(meetingId: meetingId, kind: kind, config: config, prepared: prepared, consent: true)
        }
        if kind.sendsDataToRemoteService {
            pendingConsent = ConsentRequest(provider: kind, summary: prepared.sharedSummary,
                                            characterCount: prepared.characterCount, onConfirm: start)
        } else {
            startAnalysis(meetingId: meetingId, kind: kind, config: config, prepared: prepared, consent: false)
        }
    }

    func cancelAnalysis(_ meetingId: String) {
        tasks[meetingId]?.cancel()
    }

    private func startAnalysis(meetingId: String, kind: AIProviderKind, config: AIProviderConfiguration,
                               prepared: MeetingAnalysisService.PreparedPrompt, consent: Bool) {
        runningAnalyses.insert(meetingId)
        let service = MeetingAnalysisService(database: database)
        tasks[meetingId] = Task { [weak self] in
            do {
                try await service.run(meetingId: meetingId, provider: AIProviders.provider(for: kind),
                                      configuration: config, prepared: prepared, consentGiven: consent)
            } catch is CancellationError {
            } catch {
                self?.lastError = error.localizedDescription
            }
            self?.runningAnalyses.remove(meetingId)
            self?.tasks[meetingId] = nil
        }
    }

    // MARK: Chat

    /// Local retrieval always; LLM answer only after consent for remote providers.
    func ask(question: String, scope: SearchScope, useAI: Bool, semantic: SemanticQuery? = nil) async -> MeetingChatService.Answer? {
        let chat = MeetingChatService(database: database)
        let kind = selectedProvider
        let config = configuration(for: kind)
        guard let retrieval = try? chat.retrieve(question: question, scope: scope, model: config.model,
                                                 effort: config.effort, timeout: config.timeoutSeconds,
                                                 semantic: semantic) else { return nil }
        guard useAI else { return chat.localAnswer(question: question, retrieval: retrieval) }
        if kind.sendsDataToRemoteService {
            let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                pendingConsent = ConsentRequest(provider: kind, summary: retrieval.sharedSummary,
                                                characterCount: retrieval.excerpts.reduce(0) { $0 + $1.text.count },
                                                onConfirm: { continuation.resume(returning: true) })
                consentCancellation = { continuation.resume(returning: false) }
            }
            consentCancellation = nil
            guard confirmed else { return chat.localAnswer(question: question, retrieval: retrieval) }
        }
        do {
            return try await chat.answer(question: question, retrieval: retrieval, provider: AIProviders.provider(for: kind),
                                         configuration: config, consentGiven: true)
        } catch {
            lastError = error.localizedDescription
            return chat.localAnswer(question: question, retrieval: retrieval)
        }
    }

    private var consentCancellation: (() -> Void)?

    func confirmConsent() {
        let request = pendingConsent
        pendingConsent = nil
        consentCancellation = nil
        request?.onConfirm()
    }

    func declineConsent() {
        pendingConsent = nil
        consentCancellation?()
        consentCancellation = nil
    }
}
