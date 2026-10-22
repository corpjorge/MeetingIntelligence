public import Foundation
public import GRDB

public enum AIProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCode
    case codex
    case antigravity
    case copilotCLI
    case ollama

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code CLI"
        case .codex: "OpenAI Codex CLI"
        case .antigravity: "Google Antigravity CLI"
        case .copilotCLI: "GitHub Copilot CLI"
        case .ollama: "Ollama (local)"
        }
    }

    /// Whether meeting content leaves this Mac when the provider runs.
    /// CLIs run locally but send prompts to their vendor's cloud models.
    public var sendsDataToRemoteService: Bool {
        switch self {
        case .claudeCode, .codex, .antigravity, .copilotCLI: true
        case .ollama: false
        }
    }
}

public enum AnalysisStatus: String, Codable, Sendable {
    case running
    case succeeded
    /// Output arrived but failed schema validation; raw output is kept.
    case invalidOutput
    case failed
    case cancelled
}

/// One provider execution. The raw output is retained verbatim for audit.
public struct AIAnalysis: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var meetingId: String
    public var provider: AIProviderKind
    public var model: String?
    /// Reasoning effort requested from the provider (nil = provider default).
    public var effort: String?
    public var providerVersion: String?
    public var promptVersion: String
    /// Human-readable description of exactly what was shared with the provider.
    public var sharedContentSummary: String
    public var status: AnalysisStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var durationSeconds: Double?
    public var executiveSummary: String?
    public var technicalSummary: String?
    public var rawOutput: String?
    public var errorMessage: String?

    public init(
        id: String = UUID().uuidString,
        meetingId: String,
        provider: AIProviderKind,
        model: String?,
        effort: String? = nil,
        providerVersion: String? = nil,
        promptVersion: String,
        sharedContentSummary: String,
        status: AnalysisStatus = .running,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        durationSeconds: Double? = nil,
        executiveSummary: String? = nil,
        technicalSummary: String? = nil,
        rawOutput: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.meetingId = meetingId
        self.provider = provider
        self.model = model
        self.effort = effort
        self.providerVersion = providerVersion
        self.promptVersion = promptVersion
        self.sharedContentSummary = sharedContentSummary
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
        self.executiveSummary = executiveSummary
        self.technicalSummary = technicalSummary
        self.rawOutput = rawOutput
        self.errorMessage = errorMessage
    }
}

extension AIAnalysis: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "aiAnalysis"
    public static let items = hasMany(AnalysisItem.self)
}

/// Categories of structured findings. `Decision`, `ActionItem` and `MeetingTopic`
/// are views over this single evidence-bearing table (see TECHNICAL_DECISIONS.md).
public enum AnalysisCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case agreement
    case decision
    case technicalDecision
    case commitment
    case actionItem
    case dateMention
    case openQuestion
    case risk
    case functionalRequirement
    case nonFunctionalRequirement
    case technicalDependency
    case contradiction
    case changeFromPrevious
    case clarificationNeeded
    case topic
    case recommendation

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .agreement: "Acuerdos"
        case .decision: "Decisiones"
        case .technicalDecision: "Decisiones técnicas"
        case .commitment: "Compromisos"
        case .actionItem: "Tareas pendientes"
        case .dateMention: "Fechas mencionadas"
        case .openQuestion: "Preguntas sin responder"
        case .risk: "Riesgos"
        case .functionalRequirement: "Requerimientos funcionales"
        case .nonFunctionalRequirement: "Requerimientos no funcionales"
        case .technicalDependency: "Dependencias técnicas"
        case .contradiction: "Contradicciones"
        case .changeFromPrevious: "Cambios respecto a reuniones anteriores"
        case .clarificationNeeded: "Requieren aclaración"
        case .topic: "Temas"
        case .recommendation: "Recomendaciones de la IA"
        }
    }
}

/// Epistemic nature of an item — the UI never mixes these silently.
public enum StatementNature: String, Codable, Sendable, CaseIterable {
    /// Explicitly stated during the meeting (must carry evidence).
    case fact
    /// The model's reading of what was said.
    case interpretation
    /// The model's own suggestion; never presented as something said.
    case recommendation
}

public enum EvidenceStatus: String, Codable, Sendable {
    /// Evidence segment exists and the quote was found in its text.
    case verified
    /// Missing or unverifiable evidence → shown as "Información no confirmada".
    case unconfirmed
}

public struct AnalysisItem: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var analysisId: String
    public var meetingId: String
    public var category: AnalysisCategory
    public var nature: StatementNature
    public var text: String
    public var ownerName: String?
    public var ownerParticipantId: String?
    public var dueText: String?
    public var evidenceSegmentId: String?
    public var evidenceQuote: String?
    public var evidenceStartTime: Double?
    public var evidenceSpeakerName: String?
    public var evidenceStatus: EvidenceStatus
    public var orderIndex: Int
    /// User-tracked completion for action items / commitments.
    public var completedAt: Date?

    public init(
        id: String = UUID().uuidString,
        analysisId: String,
        meetingId: String,
        category: AnalysisCategory,
        nature: StatementNature,
        text: String,
        ownerName: String? = nil,
        ownerParticipantId: String? = nil,
        dueText: String? = nil,
        evidenceSegmentId: String? = nil,
        evidenceQuote: String? = nil,
        evidenceStartTime: Double? = nil,
        evidenceSpeakerName: String? = nil,
        evidenceStatus: EvidenceStatus,
        orderIndex: Int,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.analysisId = analysisId
        self.meetingId = meetingId
        self.category = category
        self.nature = nature
        self.text = text
        self.ownerName = ownerName
        self.ownerParticipantId = ownerParticipantId
        self.dueText = dueText
        self.evidenceSegmentId = evidenceSegmentId
        self.evidenceQuote = evidenceQuote
        self.evidenceStartTime = evidenceStartTime
        self.evidenceSpeakerName = evidenceSpeakerName
        self.evidenceStatus = evidenceStatus
        self.orderIndex = orderIndex
        self.completedAt = completedAt
    }
}

extension AnalysisItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "analysisItem"
    public static let analysis = belongsTo(AIAnalysis.self)
}

/// Named views required by the domain model.
public typealias Decision = AnalysisItem
public typealias ActionItem = AnalysisItem
public typealias MeetingTopic = AnalysisItem

/// Per-provider settings. Remote providers require an explicit consent timestamp
/// before any meeting content is sent.
public struct AIProviderConfiguration: Codable, Sendable, Identifiable, Hashable {
    public var id: String { provider.rawValue }
    public var provider: AIProviderKind
    public var isEnabled: Bool
    public var executablePath: String?
    public var model: String?
    /// Reasoning effort level (provider-specific value; nil = provider default).
    public var effort: String?
    public var timeoutSeconds: Double
    public var remoteSharingConsentAt: Date?
    public var lastDetectedVersion: String?
    public var lastCheckedAt: Date?
    /// Ollama endpoint (local only).
    public var endpoint: String?

    public init(
        provider: AIProviderKind,
        isEnabled: Bool = false,
        executablePath: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        timeoutSeconds: Double = 300,
        remoteSharingConsentAt: Date? = nil,
        lastDetectedVersion: String? = nil,
        lastCheckedAt: Date? = nil,
        endpoint: String? = nil
    ) {
        self.provider = provider
        self.isEnabled = isEnabled
        self.executablePath = executablePath
        self.model = model
        self.effort = effort
        self.timeoutSeconds = timeoutSeconds
        self.remoteSharingConsentAt = remoteSharingConsentAt
        self.lastDetectedVersion = lastDetectedVersion
        self.lastCheckedAt = lastCheckedAt
        self.endpoint = endpoint
    }

    enum CodingKeys: String, CodingKey {
        case provider, isEnabled, executablePath, model, effort, timeoutSeconds
        case remoteSharingConsentAt, lastDetectedVersion, lastCheckedAt, endpoint
    }
}

extension AIProviderConfiguration: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "aiProviderConfiguration"
}
