import GRDB
import MeetingCore
import SwiftUI

@Observable
final class DashboardModel {
    var rows: [MeetingSummaryRow] = []
    var openItems: [AnalysisItem] = []
    var meetingTitles: [String: String] = [:]
    var latestAnalyses: [(analysis: AIAnalysis, meetingTitle: String)] = []
    var loaded = false

    /// Persist completion without replacing the item's text or evidence.
    func setCompleted(_ id: String, completed: Bool, in database: AppDatabase) async throws {
        try await database.writer.write { db in
            guard var item = try AnalysisItem.fetchOne(db, key: id) else {
                throw AppDatabaseError.notFound("compromiso")
            }
            guard item.category == .commitment || item.category == .actionItem else {
                throw AppDatabaseError.invalidOperation("Este elemento no es una tarea ni un compromiso.")
            }
            item.completedAt = completed ? (item.completedAt ?? Date()) : nil
            try item.update(db)
        }
    }

    func observe(_ db: AppDatabase) async {
        async let rowsTask: Void = observeRows(db)
        async let itemsTask: Void = observeItems(db)
        _ = await (rowsTask, itemsTask)
    }

    private func observeRows(_ db: AppDatabase) async {
        do {
            for try await rows in db.observeMeetingRows() {
                self.rows = rows
                loaded = true
            }
        } catch {}
    }

    private func observeItems(_ db: AppDatabase) async {
        let observation = ValueObservation.tracking { db -> ([AnalysisItem], [(AIAnalysis, String)], [String: String]) in
            let meetings = try Meeting.fetchAll(db)
            let titles = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.title) })
            let dates = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.displayDate) })
            let succeeded = AnalysisStatus.succeeded.rawValue
            let latest = try String.fetchAll(db, sql: """
                SELECT a.id FROM aiAnalysis a WHERE a.status = ? AND a.startedAt =
                  (SELECT MAX(b.startedAt) FROM aiAnalysis b WHERE b.meetingId = a.meetingId AND b.status = ?)
                """, arguments: [succeeded, succeeded])
            let items = try AnalysisItem
                .filter([AnalysisCategory.actionItem.rawValue, AnalysisCategory.commitment.rawValue].contains(Column("category")))
                .filter(Column("completedAt") == nil)
                .filter(latest.contains(Column("analysisId")))
                .fetchAll(db)
            let analyses = try AIAnalysis.filter(Column("status") == succeeded)
                .order(Column("startedAt").desc).limit(4).fetchAll(db)
            return (DashboardModel.orderedOpenItems(items, meetingDates: dates),
                    analyses.map { ($0, titles[$0.meetingId] ?? "") }, titles)
        }
        do {
            for try await (items, analyses, titles) in observation.values(in: db.reader) {
                openItems = items
                meetingTitles = titles
                latestAnalyses = analyses
            }
        } catch {}
    }

    nonisolated static func orderedOpenItems(_ items: [AnalysisItem], meetingDates: [String: Date]) -> [AnalysisItem] {
        items.sorted { lhs, rhs in
            let left = meetingDates[lhs.meetingId] ?? .distantPast
            let right = meetingDates[rhs.meetingId] ?? .distantPast
            if left != right { return left > right }
            if lhs.meetingId != rhs.meetingId { return lhs.meetingId < rhs.meetingId }
            if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
            return lhs.id < rhs.id
        }
    }
}

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @State private var model = DashboardModel()
    @State private var showsOpenCommitments = false

    var body: some View {
        PageScaffold(title: greeting, subtitle: subtitle) {
            Button { router.section = .meetings; router.isImporting = true } label: {
                Label("Importar", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.dsSecondary)
            Button { router.section = .recording } label: {
                Label("Nueva grabación", systemImage: "record.circle")
            }
            .buttonStyle(.ds(.recording))
        } content: {
            CallSuggestionBanner()
            if !env.models.allReady {
                ModelSetupBanner()
            }
            if !env.recoveredMeetings.isEmpty {
                InlineBanner(tone: .warning, systemImage: "arrow.uturn.backward.circle",
                             title: "Se recuperaron grabaciones interrumpidas",
                             message: "La aplicación se cerró mientras grababa. El audio escrito se conservó; revisa y procesa estas reuniones.") {
                    Button("Ver") { router.openMeeting(env.recoveredMeetings[0]) }.buttonStyle(.ds(.secondary, size: .small))
                }
            }
            metrics
            recentMeetings
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.xl) {
                    pendingItems.frame(minWidth: DS.Layout.dashboardColumnMinWidth, maxWidth: .infinity)
                    latestAnalyses.frame(minWidth: DS.Layout.dashboardColumnMinWidth, maxWidth: .infinity)
                }
                VStack(spacing: DS.Space.xl) {
                    pendingItems
                    latestAnalyses
                }
            }
        }
        .task { await model.observe(env.database) }
        .sheet(isPresented: $showsOpenCommitments) {
            OpenCommitmentsView(model: model, onSetCompleted: { item, completed in
                try await model.setCompleted(item.id, completed: completed, in: env.database)
            }) { item in
                showsOpenCommitments = false
                router.openMeeting(item.meetingId, tab: .tasks)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = env.settings.localUserName.split(separator: " ").first.map(String.init) ?? ""
        let base = hour < 12 ? "Buenos días" : (hour < 19 ? "Buenas tardes" : "Buenas noches")
        return name.isEmpty ? base : "\(base), \(name)"
    }

    private var subtitle: String {
        let pending = model.rows.filter { $0.meeting.status == .recorded || $0.meeting.status == .interrupted }.count
        return pending > 0 ? "\(pending) reunión(es) pendientes de procesar" : "Todo procesado localmente en este Mac"
    }

    private var metrics: some View {
        let ready = model.rows.filter { $0.meeting.status == .ready }
        let totalSeconds = model.rows.reduce(0) { $0 + $1.meeting.durationSeconds }
        return HStack(spacing: DS.Space.m) {
            MetricTile(title: "Reuniones", value: "\(model.rows.count)", caption: "\(ready.count) transcritas", systemImage: "rectangle.stack")
            MetricTile(title: "Tiempo grabado", value: Timecode.humanDuration(totalSeconds), caption: "audio local", systemImage: "waveform")
            Button { showsOpenCommitments = true } label: {
                MetricTile(title: "Compromisos abiertos", value: "\(model.openItems.count)",
                           caption: "Ver todos con su reunión", systemImage: "checklist")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ver todos los compromisos abiertos")
        }
    }

    private var recentMeetings: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Reuniones recientes") {
                Button("Ver todas") { router.section = .meetings }.buttonStyle(.ds(.ghost, size: .small))
            }
            SurfaceCard(padding: DS.Space.xs) {
                if !model.loaded {
                    LoadingStateView(message: "Cargando biblioteca…")
                } else if model.rows.isEmpty {
                    EmptyStateView(systemImage: "waveform.badge.plus", title: "Aún no hay reuniones",
                                   message: "Graba una llamada de cualquier app (Teams, Zoom, Meet…) o importa un archivo de audio para empezar.") {
                        Button("Importar audio") { router.section = .meetings; router.isImporting = true }.buttonStyle(.dsSecondary)
                    }
                } else {
                    VStack(spacing: DS.Space.none) {
                        ForEach(model.rows.prefix(6)) { row in
                            Button { router.openMeeting(row.id) } label: { MeetingRowView(row: row, compact: true) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var pendingItems: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Compromisos pendientes") {
                Button("Ver todos") { showsOpenCommitments = true }
                    .buttonStyle(.ds(.ghost, size: .small))
            }
            SurfaceCard(padding: DS.Space.m) {
                if model.openItems.isEmpty {
                    Text("Sin compromisos abiertos. Aparecerán al analizar reuniones con un proveedor de IA.")
                        .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(model.openItems.prefix(8)) { item in
                            Button { router.openMeeting(item.meetingId, tab: .tasks) } label: {
                                HStack(alignment: .top, spacing: DS.Space.s) {
                                    Image(systemName: "circle").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                                        .padding(.top, DS.Space.xxs)
                                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                        Text(item.text).font(DS.Font.callout).foregroundStyle(DS.Color.textPrimary).lineLimit(2)
                                        Text(model.meetingTitles[item.meetingId] ?? "Reunión")
                                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary).lineLimit(1)
                                        Text([item.ownerName, item.dueText].compactMap { $0 }.joined(separator: " · "))
                                            .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var latestAnalyses: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Últimos análisis")
            SurfaceCard(padding: DS.Space.m) {
                if model.latestAnalyses.isEmpty {
                    Text("Todavía no hay análisis de IA.").font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(model.latestAnalyses, id: \.analysis.id) { entry in
                            Button { router.openMeeting(entry.analysis.meetingId, tab: .summary) } label: {
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(entry.meetingTitle).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                                    Text(entry.analysis.executiveSummary ?? "").font(DS.Font.caption)
                                        .foregroundStyle(DS.Color.textSecondary).lineLimit(2)
                                    Text("\(entry.analysis.provider.displayName) · \(entry.analysis.startedAt.formatted(.relative(presentation: .named)))")
                                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct ModelSetupBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // Both models count: after Parakeet is ready the diarization models are still being prepared.
        if env.models.allReady {
            InlineBanner(tone: .success, systemImage: "checkmark.circle.fill", title: "Modelos locales listos",
                         message: "Parakeet Ultra y la diarización están descargados. Todo funciona sin conexión.") {
                EmptyView()
            }
        } else if let step = env.models.preparingStep {
            InlineBanner(tone: .info, systemImage: "arrow.down.circle",
                         title: "Preparando modelos locales",
                         message: "\(step.model) · \(step.text)\(step.fraction.map { " · \(Int($0 * 100))%" } ?? "")") {
                ProgressView().controlSize(.small)
            }
        } else if let failure = env.models.failure {
            InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill",
                         title: "\(failure.model) no está disponible", message: failure.message) {
                Button("Reintentar") { Task { await env.models.prepareAll() } }.buttonStyle(.ds(.secondary, size: .small))
            }
        } else {
            InlineBanner(tone: .warning, systemImage: "cpu",
                         title: "Descarga los modelos locales",
                         message: "Parakeet Ultra (~630 MB) y la diarización se descargan una sola vez y se ejecutan en el Neural Engine. Después todo funciona sin conexión.") {
                Button("Descargar") { Task { await env.models.prepareAll() } }.buttonStyle(.ds(.primary, size: .small))
            }
        }
    }
}
