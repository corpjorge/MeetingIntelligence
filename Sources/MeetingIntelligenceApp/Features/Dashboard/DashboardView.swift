import GRDB
import MeetingCore
import SwiftUI

@Observable
final class DashboardModel {
    var rows: [MeetingSummaryRow] = []
    var openItems: [AnalysisItem] = []
    var latestAnalyses: [(analysis: AIAnalysis, meetingTitle: String)] = []
    var loaded = false

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
        let observation = ValueObservation.tracking { db -> ([AnalysisItem], [(AIAnalysis, String)]) in
            let items = try AnalysisItem
                .filter([AnalysisCategory.actionItem.rawValue, AnalysisCategory.commitment.rawValue].contains(Column("category")))
                .filter(Column("completedAt") == nil)
                .order(Column("evidenceStartTime"))
                .limit(8)
                .fetchAll(db)
            let analyses = try AIAnalysis.filter(Column("status") == AnalysisStatus.succeeded.rawValue)
                .order(Column("startedAt").desc).limit(4).fetchAll(db)
            let titles = try Dictionary(uniqueKeysWithValues: Meeting.fetchAll(db).map { ($0.id, $0.title) })
            return (items, analyses.map { ($0, titles[$0.meetingId] ?? "") })
        }
        do {
            for try await (items, analyses) in observation.values(in: db.reader) {
                openItems = items
                latestAnalyses = analyses
            }
        } catch {}
    }
}

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @State private var model = DashboardModel()

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
                    pendingItems.frame(minWidth: 300, maxWidth: .infinity)
                    latestAnalyses.frame(minWidth: 300, maxWidth: .infinity)
                }
                VStack(spacing: DS.Space.xl) {
                    pendingItems
                    latestAnalyses
                }
            }
        }
        .task { await model.observe(env.database) }
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
            MetricTile(title: "Compromisos abiertos", value: "\(model.openItems.count)", caption: "de análisis con evidencia", systemImage: "checklist")
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
                    VStack(spacing: 0) {
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
            SectionHeader(title: "Compromisos pendientes")
            SurfaceCard(padding: DS.Space.m) {
                if model.openItems.isEmpty {
                    Text("Sin compromisos abiertos. Aparecerán al analizar reuniones con un proveedor de IA.")
                        .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(model.openItems) { item in
                            Button { router.openMeeting(item.meetingId, tab: .tasks) } label: {
                                HStack(alignment: .top, spacing: DS.Space.s) {
                                    Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(DS.Color.textTertiary)
                                        .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                        Text(item.text).font(DS.Font.callout).foregroundStyle(DS.Color.textPrimary).lineLimit(2)
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
        switch env.models.asrStatus {
        case .preparing(let text, let fraction):
            InlineBanner(tone: .info, systemImage: "arrow.down.circle",
                         title: "Preparando modelos locales",
                         message: "\(text)\(fraction.map { " · \(Int($0 * 100))%" } ?? "")") {
                ProgressView().controlSize(.small)
            }
        case .failed(let message):
            InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill",
                         title: "Parakeet Ultra no está disponible", message: message) {
                Button("Reintentar") { Task { await env.models.prepareAll() } }.buttonStyle(.ds(.secondary, size: .small))
            }
        default:
            InlineBanner(tone: .warning, systemImage: "cpu",
                         title: "Descarga los modelos locales",
                         message: "Parakeet Ultra (~630 MB) y la diarización se descargan una sola vez y se ejecutan en el Neural Engine. Después todo funciona sin conexión.") {
                Button("Descargar") { Task { await env.models.prepareAll() } }.buttonStyle(.ds(.primary, size: .small))
            }
        }
    }
}
