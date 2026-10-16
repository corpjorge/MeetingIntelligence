import GRDB
import MeetingCore
import SwiftUI

struct IntelligenceView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case chat = "Chat entre reuniones", providers = "Proveedores", history = "Historial"
        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @State private var pane: Pane = .chat
    @State private var scopeMeetings: Set<String> = []
    @State private var showScopePicker = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Inteligencia").font(DS.Font.display)
                    Text("Consultas con evidencia sobre tus reuniones. La búsqueda es local; la IA es opcional.")
                        .font(DS.Font.body).foregroundStyle(DS.Color.textSecondary)
                }
                Picker("Vista", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.xl)

            switch pane {
            case .chat:
                VStack(spacing: 0) {
                    HStack(spacing: DS.Space.m) {
                        Label(scopeMeetings.isEmpty ? "Todas las reuniones" : "\(scopeMeetings.count) reuniones seleccionadas",
                              systemImage: "rectangle.stack")
                            .font(DS.Font.callout)
                        Button("Elegir reuniones…") { showScopePicker = true }.buttonStyle(.ds(.ghost, size: .small))
                        if !scopeMeetings.isEmpty {
                            Button("Todas") { scopeMeetings = [] }.buttonStyle(.ds(.ghost, size: .small))
                        }
                        Spacer()
                        providerPicker
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.s)
                    Divider()
                    ChatPanel(scope: scopeMeetings.isEmpty ? .allMeetings : .meetings(Array(scopeMeetings))) { meetingId, _ in
                        router.openMeeting(meetingId, tab: .transcript)
                    }
                }
            case .providers:
                ProvidersPane()
            case .history:
                AnalysisHistoryPane()
            }
        }
        .background(DS.Color.background)
        .sheet(isPresented: $showScopePicker) {
            PreviousMeetingsPicker(excluding: "", selection: $scopeMeetings)
        }
        .task { if env.ai.statuses.isEmpty { await env.ai.refreshStatuses() } }
    }

    private var providerPicker: some View {
        @Bindable var ai = env.ai
        return HStack(spacing: DS.Space.s) {
            Picker("Proveedor", selection: $ai.selectedProvider) {
                ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            .frame(width: 220)
            if let status = env.ai.statuses[env.ai.selectedProvider] { ProviderStatusPill(status: status) }
        }
    }
}

struct ProvidersPane: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack {
                    InlineBanner(tone: .info, systemImage: "lock.shield",
                                 title: "Ejecutar un CLI en tu Mac no significa que el modelo sea local",
                                 message: "Claude Code, Codex y Antigravity envían el texto a la nube de su proveedor; la app te pedirá confirmación cada vez. Ollama procesa todo en este Mac. Los agentes se ejecutan sin herramientas ni permisos de sistema.")
                }
                HStack {
                    Spacer()
                    Button {
                        Task { await env.ai.refreshStatuses() }
                    } label: { Label("Volver a detectar", systemImage: "arrow.clockwise") }
                    .buttonStyle(.dsSecondary)
                    .disabled(env.ai.isDetecting)
                    if env.ai.isDetecting { ProgressView().controlSize(.small) }
                }
                ForEach(AIProviderKind.allCases) { kind in
                    ProviderCard(kind: kind)
                }
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.bottom, DS.Space.xxl)
            .frame(maxWidth: DS.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct ProviderCard: View {
    let kind: AIProviderKind
    @Environment(AppEnvironment.self) private var env
    @State private var config: AIProviderConfiguration?

    var body: some View {
        let status = env.ai.statuses[kind]
        SurfaceCard {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: kind.sendsDataToRemoteService ? "cloud" : "desktopcomputer")
                        .frame(width: 30, height: 30)
                        .background(DS.Color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.s))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.displayName).font(DS.Font.headline)
                        Text(kind.sendsDataToRemoteService ? "Modelo en la nube del proveedor" : "Modelo local")
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    }
                    Spacer()
                    if let status { ProviderStatusPill(status: status) } else { ProgressView().controlSize(.small) }
                    if env.ai.selectedProvider == kind {
                        StatusPill(text: "Seleccionado", tone: .accent, systemImage: "checkmark")
                    } else {
                        Button("Usar") { env.ai.selectedProvider = kind }.buttonStyle(.ds(.secondary, size: .small))
                    }
                }
                if let status {
                    if let path = status.executablePath { KeyValueRow(key: "Ubicación", value: path, monospaced: true) }
                    if let version = status.version { KeyValueRow(key: "Versión", value: version) }
                    if let detail = status.authDetail { KeyValueRow(key: "Sesión", value: detail) }
                    ForEach(status.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    }
                }
                if let binding = configBinding {
                    HStack(spacing: DS.Space.m) {
                        if let models = status?.models, !models.isEmpty {
                            Picker("Modelo", selection: Binding(get: { binding.wrappedValue.model ?? "" },
                                                                set: { binding.wrappedValue.model = $0.isEmpty ? nil : $0; save() })) {
                                Text("Predeterminado").tag("")
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                            .frame(maxWidth: 320)
                        } else {
                            TextField("Modelo (vacío = predeterminado)", text: Binding(
                                get: { binding.wrappedValue.model ?? "" },
                                set: { binding.wrappedValue.model = $0.isEmpty ? nil : $0 }))
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                                .onSubmit(save)
                        }
                        Stepper("Tiempo límite: \(Int(binding.wrappedValue.timeoutSeconds)) s",
                                value: Binding(get: { binding.wrappedValue.timeoutSeconds },
                                               set: { binding.wrappedValue.timeoutSeconds = $0; save() }),
                                in: 60...1800, step: 60)
                    }
                    if kind == .ollama {
                        TextField("Endpoint local", text: Binding(get: { binding.wrappedValue.endpoint ?? OllamaProvider.defaultEndpoint },
                                                                  set: { binding.wrappedValue.endpoint = $0 }))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 320).onSubmit(save)
                    } else {
                        TextField("Ruta del ejecutable (vacío = detección automática)", text: Binding(
                            get: { binding.wrappedValue.executablePath ?? "" },
                            set: { binding.wrappedValue.executablePath = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder).onSubmit(save)
                    }
                }
            }
        }
        .onAppear { config = env.ai.configuration(for: kind) }
    }

    private var configBinding: Binding<AIProviderConfiguration>? {
        guard config != nil else { return nil }
        return Binding(get: { config! }, set: { config = $0 })
    }

    private func save() {
        if let config { env.ai.save(config) }
    }
}

struct AnalysisHistoryPane: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @State private var rows: [(AIAnalysis, String)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if rows.isEmpty {
                    EmptyStateView(systemImage: "clock.arrow.circlepath", title: "Sin ejecuciones",
                                   message: "Cada análisis registra proveedor, modelo, duración, qué se compartió y la salida original.")
                }
                ForEach(rows, id: \.0.id) { analysis, title in
                    Button { router.openMeeting(analysis.meetingId, tab: .summary) } label: {
                        SurfaceCard(padding: DS.Space.m) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(title).font(DS.Font.bodyEmphasis)
                                    Text("\(analysis.provider.displayName)\(analysis.model.map { " · \($0)" } ?? "")\(analysis.providerVersion.map { " · \($0)" } ?? "")")
                                        .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                                    Text(analysis.sharedContentSummary).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(2)
                                    if let error = analysis.errorMessage {
                                        Text(error).font(DS.Font.caption).foregroundStyle(DS.Color.danger).lineLimit(2)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                                    StatusPill(text: analysis.status.rawValue,
                                               tone: analysis.status == .succeeded ? .success : (analysis.status == .running ? .accent : .danger))
                                    Text(analysis.startedAt.formatted(date: .abbreviated, time: .shortened)).font(DS.Font.caption)
                                    if let d = analysis.durationSeconds { Text(String(format: "%.1f s", d)).font(DS.Font.mono) }
                                }
                                .foregroundStyle(DS.Color.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.bottom, DS.Space.xxl)
            .frame(maxWidth: DS.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            let observation = ValueObservation.tracking { db -> [(AIAnalysis, String)] in
                let titles = Dictionary(uniqueKeysWithValues: try Meeting.fetchAll(db).map { ($0.id, $0.title) })
                return try AIAnalysis.order(Column("startedAt").desc).limit(200).fetchAll(db).map { ($0, titles[$0.meetingId] ?? "") }
            }
            do {
                for try await value in observation.values(in: env.database.reader) { rows = value }
            } catch {}
        }
    }
}
