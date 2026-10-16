import GRDB
import MeetingCore
import SwiftUI

/// Run-analysis bar shared by Summary / Decisions / Tasks.
struct AnalysisRunBar: View {
    let meetingId: String
    let hasTranscript: Bool
    @Environment(AppEnvironment.self) private var env
    @State private var comparePrevious: Set<String> = []
    @State private var showCompare = false

    var body: some View {
        @Bindable var ai = env.ai
        HStack(spacing: DS.Space.m) {
            Picker("Proveedor", selection: $ai.selectedProvider) {
                ForEach(AIProviderKind.allCases) { kind in
                    Text(kind.displayName + (kind.sendsDataToRemoteService ? " · nube" : " · local")).tag(kind)
                }
            }
            .frame(width: 280)
            if let status = env.ai.statuses[env.ai.selectedProvider] {
                ProviderStatusPill(status: status)
            }
            Button { showCompare = true } label: {
                Label(comparePrevious.isEmpty ? "Comparar con…" : "\(comparePrevious.count) reunión(es) previas", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.ds(.ghost, size: .small))
            .help("Incluir decisiones verificadas de reuniones anteriores para detectar cambios")
            Spacer()
            if env.ai.isAnalyzing(meetingId) {
                ProgressView().controlSize(.small)
                Text("Analizando…").font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                Button("Cancelar") { env.ai.cancelAnalysis(meetingId) }.buttonStyle(.ds(.ghost, size: .small))
            } else {
                Button {
                    env.ai.analyze(meetingId: meetingId, previousMeetingIds: Array(comparePrevious))
                } label: {
                    Label("Analizar reunión", systemImage: "sparkles")
                }
                .buttonStyle(.dsPrimary)
                .disabled(!hasTranscript)
            }
        }
        .task { if env.ai.statuses.isEmpty { await env.ai.refreshStatuses() } }
        .sheet(isPresented: $showCompare) {
            PreviousMeetingsPicker(excluding: meetingId, selection: $comparePrevious)
        }
    }
}

struct ProviderStatusPill: View {
    let status: ProviderStatus

    var body: some View {
        if !status.installed {
            StatusPill(text: "No instalado", tone: .danger)
        } else if status.authenticated == false {
            StatusPill(text: "Sin sesión", tone: .warning).help(status.authDetail ?? "")
        } else {
            StatusPill(text: status.version.map { "v\($0.split(separator: " ").first ?? "")" } ?? "Disponible", tone: .success)
                .help(status.authDetail ?? "")
        }
    }
}

struct PreviousMeetingsPicker: View {
    let excluding: String
    @Binding var selection: Set<String>
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [MeetingSummaryRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Comparar con reuniones anteriores").font(DS.Font.title)
            Text("Solo se incluyen decisiones y compromisos con evidencia verificada de reuniones ya analizadas.")
                .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            List(rows.filter { $0.id != excluding && $0.meeting.status == .ready }) { row in
                Toggle(isOn: Binding(get: { selection.contains(row.id) },
                                     set: { if $0 { selection.insert(row.id) } else { selection.remove(row.id) } })) {
                    VStack(alignment: .leading) {
                        Text(row.meeting.title).font(DS.Font.bodyEmphasis)
                        Text(row.meeting.displayDate.formatted(date: .abbreviated, time: .shortened)).font(DS.Font.caption)
                    }
                }
            }
            .frame(height: 320)
            HStack { Spacer(); Button("Listo") { dismiss() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction) }
        }
        .padding(DS.Space.xl)
        .frame(width: 480)
        .task { rows = (try? env.database.meetingRows()) ?? [] }
    }
}

struct SummaryTab: View {
    let model: MeetingDetailModel
    let meetingId: String
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                AnalysisRunBar(meetingId: meetingId, hasTranscript: !(model.detail?.segments.isEmpty ?? true))
                if let error = env.ai.lastError {
                    InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill", title: "El análisis falló", message: error) {
                        IconButton(systemImage: "xmark", help: "Cerrar") { env.ai.dismissError() }
                    }
                }
                if let analysis = model.latestAnalysis {
                    AIProvenance(analysis: analysis)
                    if let summary = analysis.executiveSummary {
                        summaryCard("Resumen ejecutivo", summary)
                    }
                    if let technical = analysis.technicalSummary, !technical.isEmpty {
                        summaryCard("Resumen técnico", technical)
                    }
                    let grouped = Dictionary(grouping: model.latestItems, by: \.category)
                    let shown: [AnalysisCategory] = [.agreement, .dateMention, .openQuestion, .risk, .functionalRequirement,
                                                     .nonFunctionalRequirement, .technicalDependency, .contradiction,
                                                     .changeFromPrevious, .clarificationNeeded, .topic, .recommendation]
                    ForEach(shown) { category in
                        if let items = grouped[category], !items.isEmpty {
                            ItemsSection(category: category, items: items, model: model)
                        }
                    }
                    if model.analyses.count > 1 {
                        AnalysisHistory(analyses: model.analyses)
                    }
                } else if let failed = model.analyses.first {
                    InlineBanner(tone: .warning, systemImage: "exclamationmark.triangle",
                                 title: "El último análisis no se completó (\(failed.status.rawValue))",
                                 message: failed.errorMessage)
                } else {
                    EmptyStateView(systemImage: "sparkles", title: "Sin análisis todavía",
                                   message: "Elige un proveedor y analiza la reunión. Cada hallazgo incluirá la cita exacta y su timestamp; lo que no tenga evidencia se marca como “Información no confirmada”.")
                }
            }
            .padding(DS.Space.xxl)
            .frame(maxWidth: DS.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: Binding(get: { env.ai.pendingConsent }, set: { if $0 == nil { env.ai.declineConsent() } })) { request in
            RemoteConsentSheet(request: request)
        }
    }

    private func summaryCard(_ title: String, _ text: String) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    Text(title).font(DS.Font.headline)
                    StatusPill(text: "Generado por IA", tone: .ai, systemImage: "sparkles")
                }
                Text(text).font(DS.Font.reading).foregroundStyle(DS.Color.textPrimary).textSelection(.enabled)
            }
        }
    }
}

struct AIProvenance: View {
    let analysis: AIAnalysis

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "info.circle").foregroundStyle(DS.Color.textTertiary)
            Text("\(analysis.provider.displayName)\(analysis.model.map { " · \($0)" } ?? "") · \(analysis.startedAt.formatted(date: .abbreviated, time: .shortened))\(analysis.durationSeconds.map { String(format: " · %.0f s", $0) } ?? "") · prompt \(analysis.promptVersion)")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
        }
        .help(analysis.sharedContentSummary)
    }
}

struct AnalysisHistory: View {
    let analyses: [AIAnalysis]

    var body: some View {
        DisclosureGroup("Historial de ejecuciones (\(analyses.count))") {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(analyses) { a in
                    HStack {
                        Text(a.startedAt.formatted(date: .abbreviated, time: .shortened)).font(DS.Font.mono)
                        Text("\(a.provider.displayName)\(a.model.map { " · \($0)" } ?? "")").font(DS.Font.caption)
                        StatusPill(text: a.status.rawValue, tone: a.status == .succeeded ? .success : (a.status == .running ? .accent : .danger))
                        if let error = a.errorMessage { Text(error).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1) }
                    }
                }
            }
        }
        .font(DS.Font.callout)
    }
}

struct ItemsSection: View {
    let category: AnalysisCategory
    let items: [AnalysisItem]
    let model: MeetingDetailModel
    var showsCompletion = false
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: category.displayName, subtitle: "\(items.count)")
            SurfaceCard(padding: DS.Space.xs) {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        ItemRow(item: item, showsCompletion: showsCompletion,
                                onSeek: { t in model.player.seek(to: t, play: true) },
                                onToggle: { toggle(item) })
                        if item.id != items.last?.id { Divider().padding(.leading, DS.Space.l) }
                    }
                }
            }
        }
    }

    private func toggle(_ item: AnalysisItem) {
        try? env.database.writer.write { db in
            var updated = item
            updated.completedAt = item.completedAt == nil ? Date() : nil
            try updated.update(db)
        }
    }
}

struct ItemRow: View {
    let item: AnalysisItem
    var showsCompletion = false
    let onSeek: (Double) -> Void
    var onToggle: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            if showsCompletion {
                Button(action: onToggle) {
                    Image(systemName: item.completedAt == nil ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(item.completedAt == nil ? DS.Color.textTertiary : DS.Color.success)
                }
                .buttonStyle(.plain)
                .help(item.completedAt == nil ? "Marcar como completada" : "Marcar como pendiente")
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(item.text).font(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                    .strikethrough(item.completedAt != nil, color: DS.Color.textTertiary)
                HStack(spacing: DS.Space.s) {
                    natureBadge
                    if let owner = item.ownerName { Label(owner, systemImage: "person").font(DS.Font.caption) }
                    if let due = item.dueText { Label(due, systemImage: "calendar").font(DS.Font.caption) }
                }
                .foregroundStyle(DS.Color.textSecondary)
                evidence
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Space.m)
    }

    @ViewBuilder
    private var natureBadge: some View {
        switch item.nature {
        case .fact: StatusPill(text: "Dicho en la reunión", tone: .neutral)
        case .interpretation: StatusPill(text: "Interpretación de la IA", tone: .ai)
        case .recommendation: StatusPill(text: "Recomendación de la IA", tone: .ai, systemImage: "lightbulb")
        }
    }

    @ViewBuilder
    private var evidence: some View {
        if item.evidenceStatus == .verified, let start = item.evidenceStartTime {
            Button { onSeek(start) } label: {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Rectangle().fill(DS.Color.accent.opacity(0.5)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Timecode.hms(start)) · \(item.evidenceSpeakerName ?? "")")
                            .font(DS.Font.mono).foregroundStyle(DS.Color.accent)
                        if let quote = item.evidenceQuote {
                            Text("“\(quote)”").font(DS.Font.callout).italic().foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .help("Escuchar la evidencia")
        } else {
            Label("Información no confirmada", systemImage: "exclamationmark.triangle")
                .font(DS.Font.caption).foregroundStyle(DS.Color.warning)
                .help(item.evidenceQuote.map { "Cita propuesta por la IA no encontrada en la transcripción: “\($0)”" }
                      ?? "La IA no aportó evidencia.")
        }
    }
}

struct AnalysisItemsTab: View {
    enum Mode { case decisions, tasks }
    let model: MeetingDetailModel
    let meetingId: String
    let mode: Mode
    @Environment(AppEnvironment.self) private var env

    private var categories: [AnalysisCategory] {
        mode == .decisions ? [.decision, .technicalDecision, .agreement] : [.actionItem, .commitment]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                AnalysisRunBar(meetingId: meetingId, hasTranscript: !(model.detail?.segments.isEmpty ?? true))
                let grouped = Dictionary(grouping: model.latestItems, by: \.category)
                let any = categories.contains { !(grouped[$0] ?? []).isEmpty }
                if any {
                    ForEach(categories) { category in
                        if let items = grouped[category], !items.isEmpty {
                            ItemsSection(category: category, items: items, model: model, showsCompletion: mode == .tasks)
                        }
                    }
                } else {
                    EmptyStateView(systemImage: mode == .decisions ? "checkmark.seal" : "checklist",
                                   title: model.latestAnalysis == nil ? "Sin análisis todavía" : "No se encontraron \(mode == .decisions ? "decisiones" : "tareas")",
                                   message: model.latestAnalysis == nil
                                       ? "Analiza la reunión para extraer \(mode == .decisions ? "decisiones" : "tareas y compromisos") con evidencia."
                                       : "El análisis no encontró elementos con evidencia en la transcripción.")
                }
            }
            .padding(DS.Space.xxl)
            .frame(maxWidth: DS.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: Binding(get: { env.ai.pendingConsent }, set: { if $0 == nil { env.ai.declineConsent() } })) { request in
            RemoteConsentSheet(request: request)
        }
    }
}

/// Explicit confirmation before meeting content leaves the Mac.
struct RemoteConsentSheet: View {
    let request: AIController.ConsentRequest
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "icloud.and.arrow.up").font(.system(size: 24)).foregroundStyle(DS.Color.warning)
                VStack(alignment: .leading) {
                    Text("Enviar a \(request.provider.displayName)").font(DS.Font.title)
                    Text("El CLI se ejecuta en tu Mac, pero el modelo procesa los datos en la nube del proveedor.")
                        .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("Qué se compartirá").font(DS.Font.headline)
                    Text(request.summary).font(DS.Font.body).fixedSize(horizontal: false, vertical: true)
                    Text("≈ \(request.characterCount.formatted()) caracteres").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
            Text("La IA se ejecuta sin herramientas ni permisos de sistema; el texto de la reunión se trata como datos no confiables.")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            HStack {
                Spacer()
                Button("Cancelar") { env.ai.declineConsent() }.buttonStyle(.dsSecondary).keyboardShortcut(.cancelAction)
                Button("Compartir y analizar") { env.ai.confirmConsent() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 520)
    }
}
