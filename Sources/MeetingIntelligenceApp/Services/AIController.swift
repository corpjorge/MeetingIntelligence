import Foundation
import MeetingCore
import OSLog

extension AIProviderConfiguration {
    /// Copilot accepts a custom effort only with an explicit model.
    var supportsEffortSelection: Bool {
        guard provider == .copilotCLI else { return true }
        let value = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !value.isEmpty && value.lowercased() != "auto"
    }

    var compatibleEffortConfiguration: Self {
        var configuration = self
        if !supportsEffortSelection { configuration.model = nil; configuration.effort = nil }
        return configuration
    }
}

/// App-side orchestration of AI providers: detection, selection, consent and runs.
@Observable
final class AIController {
    struct ConsentRequest: Identifiable {
        let id = UUID()
        let provider: AIProviderKind
        var model: String?
        let summary: String
        let characterCount: Int
        let onConfirm: () -> Void
        var onDecline: () -> Void = {}
        var analysisMeetingId: String?
    }

    struct ChatReply {
        var answer: MeetingChatService.Answer?
        var aiError: String?
    }

    private(set) var statuses: [AIProviderKind: ProviderStatus] = [:]
    private(set) var isDetecting = false
    private(set) var runningAnalyses: Set<String> = []
    private(set) var analysisErrors: [String: String] = [:]
    private(set) var consentQueue: [ConsentRequest] = []
    var pendingConsent: ConsentRequest? { consentQueue.first }
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
        asksConsent(for: kind, model: configuration(for: kind).model)
    }

    func asksConsent(for kind: AIProviderKind, model: String?) -> Bool {
        kind.sendsDataToRemoteService(model: model) && !consentSkipped.contains(kind)
    }

    func sendsDataToRemoteService(_ kind: AIProviderKind) -> Bool {
        kind.sendsDataToRemoteService(model: configuration(for: kind).model)
    }

    func setAsksConsent(_ asks: Bool, for kind: AIProviderKind) {
        if asks { consentSkipped.remove(kind) } else { consentSkipped.insert(kind) }
    }

    func configuration(for kind: AIProviderKind) -> AIProviderConfiguration {
        _ = configurationRevision // observation dependency
        return ((try? database.providerConfiguration(kind)) ?? AIProviderConfiguration(provider: kind))
            .compatibleEffortConfiguration
    }

    func modelChoices(for kind: AIProviderKind) -> [String] {
        var choices = Set((statuses[kind]?.models ?? []).filter { !$0.isEmpty && $0.lowercased() != "auto" })
        if kind == .copilotCLI, statuses[kind]?.modelCatalogLoaded == true {
            return choices.sorted()
        }
        if let saved = configuration(for: kind).model, !saved.isEmpty, saved.lowercased() != "auto" {
            choices.insert(saved)
        }
        return choices.sorted()
    }

    func selectedModel(for kind: AIProviderKind) -> String {
        let saved = configuration(for: kind).model ?? ""
        return kind == .copilotCLI && saved.lowercased() == "auto" ? "" : saved
    }

    func selectModel(_ model: String, for kind: AIProviderKind) {
        var configuration = configuration(for: kind)
        if selectedModel(for: kind) != model { configuration.effort = nil }
        configuration.model = model.isEmpty ? nil : model
        save(configuration)
    }

    /// Bumped on every save so views reading `configuration(for:)` refresh.
    private(set) var configurationRevision = 0

    func save(_ configuration: AIProviderConfiguration) {
        let configuration = configuration.compatibleEffortConfiguration
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
                if status.kind == .copilotCLI, status.modelCatalogLoaded,
                   let model = config.model, !status.models.contains(model) {
                    config.model = nil
                    config.effort = nil
                }
                config.lastDetectedVersion = status.version
                config.lastCheckedAt = Date()
                save(config)
            }
        }
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    // MARK: Analysis

    func isAnalyzing(_ meetingId: String) -> Bool { runningAnalyses.contains(meetingId) }

    func analysisError(for meetingId: String) -> String? { analysisErrors[meetingId] }

    func dismissAnalysisError(for meetingId: String) { analysisErrors[meetingId] = nil }

    /// Prepares the prompt, asks for consent when the provider is remote, then runs.
    func analyze(meetingId: String, previousMeetingIds: [String] = []) {
        guard !isAnalyzing(meetingId), !consentQueue.contains(where: { $0.analysisMeetingId == meetingId }) else { return }
        let kind = selectedProvider
        let config = configuration(for: kind)
        let service = MeetingAnalysisService(database: database)
        let prepared: MeetingAnalysisService.PreparedPrompt
        do {
            prepared = try service.prepare(meetingId: meetingId, previousMeetingIds: previousMeetingIds,
                                           model: config.model, effort: config.effort, timeout: config.timeoutSeconds)
        } catch {
            analysisErrors[meetingId] = error.localizedDescription
            return
        }
        analysisErrors[meetingId] = nil
        let remote = kind.sendsDataToRemoteService(model: config.model)
        if remote && !consentSkipped.contains(kind) {
            consentQueue.append(ConsentRequest(
                provider: kind, model: config.model, summary: prepared.sharedSummary,
                characterCount: prepared.characterCount,
                onConfirm: { [weak self] in
                    self?.startAnalysis(meetingId: meetingId, kind: kind, config: config, prepared: prepared, consent: true)
                },
                analysisMeetingId: meetingId))
        } else {
            // Standing consent for a remote provider counts as given; local providers need none.
            startAnalysis(meetingId: meetingId, kind: kind, config: config, prepared: prepared, consent: remote)
        }
    }

    func cancelAnalysis(_ meetingId: String) {
        tasks[meetingId]?.cancel()
    }

    private func startAnalysis(meetingId: String, kind: AIProviderKind, config: AIProviderConfiguration,
                               prepared: MeetingAnalysisService.PreparedPrompt, consent: Bool) {
        guard !isAnalyzing(meetingId) else { return }
        analysisErrors[meetingId] = nil
        runningAnalyses.insert(meetingId)
        let service = MeetingAnalysisService(database: database)
        let provider = providerFor(kind)
        tasks[meetingId] = Task { [weak self] in
            do {
                try await service.run(meetingId: meetingId, provider: provider,
                                      configuration: config, prepared: prepared, consentGiven: consent)
            } catch {
                if !Task.isCancelled, !Self.isCancellation(error) {
                    self?.analysisErrors[meetingId] = error.localizedDescription
                }
            }
            self?.runningAnalyses.remove(meetingId)
            self?.tasks[meetingId] = nil
        }
    }

    // MARK: Chat

    /// Local retrieval always; LLM answer only after consent for remote providers.
    func ask(question: String, scope: SearchScope, useAI: Bool, semantic: SemanticQuery? = nil,
             configuration: AIProviderConfiguration? = nil) async -> MeetingChatService.Answer? {
        await reply(question: question, scope: scope, useAI: useAI, semantic: semantic, configuration: configuration).answer
    }

    func reply(question: String, scope: SearchScope, useAI: Bool, semantic: SemanticQuery? = nil,
               configuration: AIProviderConfiguration? = nil) async -> ChatReply {
        let chat = MeetingChatService(database: database)
        let config = (configuration ?? self.configuration(for: selectedProvider)).compatibleEffortConfiguration
        let kind = config.provider
        guard let retrieval = try? chat.retrieve(question: question, scope: scope, model: config.model,
                                                 effort: config.effort, timeout: config.timeoutSeconds,
                                                 semantic: semantic) else { return ChatReply() }
        guard useAI else { return ChatReply(answer: chat.localAnswer(question: question, retrieval: retrieval)) }
        let remote = kind.sendsDataToRemoteService(model: config.model)
        if remote && !consentSkipped.contains(kind) {
            let confirmed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                consentQueue.append(ConsentRequest(
                    provider: kind, model: config.model, summary: retrieval.sharedSummary,
                    characterCount: retrieval.context.reduce(0) { $0 + $1.text.count } + question.count,
                    onConfirm: { continuation.resume(returning: true) },
                    onDecline: { continuation.resume(returning: false) }))
            }
            guard confirmed else { return ChatReply(answer: chat.localAnswer(question: question, retrieval: retrieval)) }
        }
        do {
            return ChatReply(answer: try await chat.answer(question: question, retrieval: retrieval,
                                                           provider: providerFor(kind), configuration: config,
                                                           consentGiven: remote))
        } catch {
            let cancelled = Task.isCancelled || Self.isCancellation(error)
            return ChatReply(answer: chat.localAnswer(question: question, retrieval: retrieval),
                             aiError: cancelled ? nil : error.localizedDescription)
        }
    }

    /// `remember` stops asking for this provider until re-enabled in its card.
    func confirmConsent(remember: Bool = false) {
        guard let id = consentQueue.first?.id else { return }
        confirmConsent(id, remember: remember)
    }

    func confirmConsent(_ id: UUID, remember: Bool = false) {
        guard let request = takeConsent(id) else { return }
        guard remember else {
            request.onConfirm()
            return
        }
        setAsksConsent(false, for: request.provider)
        let sameProvider = consentQueue.filter { $0.provider == request.provider }
        consentQueue.removeAll { $0.provider == request.provider }
        request.onConfirm()
        for queued in sameProvider { queued.onConfirm() }
    }

    func declineConsent() {
        guard let id = consentQueue.first?.id else { return }
        declineConsent(id)
    }

    func declineConsent(_ id: UUID) {
        takeConsent(id)?.onDecline()
    }

    private func takeConsent(_ id: UUID) -> ConsentRequest? {
        guard let index = consentQueue.firstIndex(where: { $0.id == id }) else { return nil }
        return consentQueue.remove(at: index)
    }
}
