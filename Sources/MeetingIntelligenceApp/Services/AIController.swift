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
        didSet { defaults.set(selectedProvider.rawValue, forKey: "aiProvider") }
    }
    /// Remote providers whose share confirmation the user turned off ("No volver a preguntar");
    /// revocable per provider in Inteligencia › Proveedores.
    private(set) var consentSkipped: Set<AIProviderKind> {
        didSet { defaults.set(consentSkipped.map(\.rawValue).sorted(), forKey: "aiConsentSkipped") }
    }

    private let database: AppDatabase
    private let defaults: UserDefaults
    private let providerFor: (AIProviderKind) -> any AIProvider
    private var tasks: [String: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "ai")

    init(database: AppDatabase, defaults: UserDefaults = .standard,
         providerFor: @escaping (AIProviderKind) -> any AIProvider = AIProviders.provider(for:)) {
        self.database = database
        self.defaults = defaults
        self.providerFor = providerFor
        selectedProvider = AIProviderKind(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .claudeCode
        consentSkipped = Set((defaults.stringArray(forKey: "aiConsentSkipped") ?? []).compactMap(AIProviderKind.init(rawValue:)))
    }

    /// Whether sending to `kind` shows the confirmation with the summary of what is shared.
    func asksConsent(for kind: AIProviderKind) -> Bool {
        kind.sendsDataToRemoteService && !consentSkipped.contains(kind)
    }

    func setAsksConsent(_ asks: Bool, for kind: AIProviderKind) {
        if asks { consentSkipped.remove(kind) } else { consentSkipped.insert(kind) }
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
            let provider = providerFor(.ollama)
            Task { statuses[.ollama] = await provider.detect(configuration: configuration) }
        }
    }

    func refreshStatuses() async {
        guard !isDetecting else { return }
        isDetecting = true
        defer { isDetecting = false }
        await withTaskGroup(of: ProviderStatus.self) { group in
            for kind in AIProviderKind.allCases {
                let config = configuration(for: kind)
                let provider = providerFor(kind)
                group.addTask { await provider.detect(configuration: config) }
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
        if asksConsent(for: kind) {
            pendingConsent = ConsentRequest(provider: kind, summary: prepared.sharedSummary,
                                            characterCount: prepared.characterCount, onConfirm: start)
        } else {
            // Standing consent for a remote provider counts as given; local providers need none.
            startAnalysis(meetingId: meetingId, kind: kind, config: config, prepared: prepared,
                          consent: kind.sendsDataToRemoteService)
        }
    }

    func cancelAnalysis(_ meetingId: String) {
        tasks[meetingId]?.cancel()
    }

    private func startAnalysis(meetingId: String, kind: AIProviderKind, config: AIProviderConfiguration,
                               prepared: MeetingAnalysisService.PreparedPrompt, consent: Bool) {
        runningAnalyses.insert(meetingId)
        let service = MeetingAnalysisService(database: database)
        let provider = providerFor(kind)
        tasks[meetingId] = Task { [weak self] in
            do {
                try await service.run(meetingId: meetingId, provider: provider,
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
        if asksConsent(for: kind) {
            let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                pendingConsent = ConsentRequest(provider: kind, summary: retrieval.sharedSummary,
                                                characterCount: retrieval.context.reduce(0) { $0 + $1.text.count } + question.count,
                                                onConfirm: { continuation.resume(returning: true) })
                consentCancellation = { continuation.resume(returning: false) }
            }
            consentCancellation = nil
            guard confirmed else { return chat.localAnswer(question: question, retrieval: retrieval) }
        }
        do {
            return try await chat.answer(question: question, retrieval: retrieval, provider: providerFor(kind),
                                         configuration: config, consentGiven: true)
        } catch {
            lastError = error.localizedDescription
            return chat.localAnswer(question: question, retrieval: retrieval)
        }
    }

    private var consentCancellation: (() -> Void)?

    /// `remember` stops asking for this provider until re-enabled in its card.
    func confirmConsent(remember: Bool = false) {
        let request = pendingConsent
        if remember, let request { setAsksConsent(false, for: request.provider) }
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
