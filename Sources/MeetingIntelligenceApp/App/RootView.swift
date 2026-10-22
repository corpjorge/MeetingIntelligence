import MeetingCore
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: DS.Layout.sidebarMinWidth, ideal: DS.Layout.sidebarWidth, max: DS.Layout.sidebarMaxWidth)
        } detail: {
            Group {
                switch router.section {
                case .dashboard: DashboardView()
                case .meetings:
                    NavigationStack(path: $router.meetingPath) {
                        MeetingsView()
                            .navigationDestination(for: String.self) { MeetingDetailView(meetingId: $0) }
                    }
                case .recording: RecordingView()
                case .participants: ParticipantsView()
                case .intelligence: IntelligenceView()
                }
            }
            .background(DS.Color.background)
            .overlay(alignment: .top) { AppUpdateBanner() }
        }
        .overlay(alignment: .bottom) { ProcessingToast() }
        .sheet(isPresented: .constant(!env.settings.hasCompletedOnboarding)) {
            OnboardingView().environment(env)
        }
        .sheet(isPresented: Bindable(env.updates).isSheetPresented) {
            AppUpdateSheet().environment(env)
        }
        .task {
            env.calls.onAcceptStart = { app in
                router.preselectedRecordingApp = app
                router.section = .recording
            }
            await env.models.refresh()
            SnapshotDriver.runIfRequested(router: router, env: env)
        }
        .alert("Error de la biblioteca", isPresented: .constant(env.startupError != nil)) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text(env.startupError ?? "")
        }
    }
}

struct Sidebar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        VStack(spacing: DS.Space.none) {
            List(selection: $router.section) {
                Section {
                    ForEach(AppRouter.Section.allCases) { section in
                        Label {
                            HStack {
                                Text(section.title)
                                Spacer()
                                if section == .recording, env.recording.isActive {
                                    RecordingDot(size: DS.Size.dotS)
                                }
                            }
                        } icon: {
                            Image(systemName: section.systemImage)
                        }
                        .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)

            SidebarFooter()
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if env.recording.isActive {
                HStack(spacing: DS.Space.s) {
                    RecordingDot(size: DS.Size.dotM)
                    Text(env.recording.state == .paused ? "Pausado" : "Grabando")
                        .font(DS.Font.captionEmphasis).foregroundStyle(DS.Color.recording)
                    Spacer()
                    Text(Timecode.compact(env.recording.elapsed)).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary)
                }
            }
            HStack(spacing: DS.Space.s) {
                Circle().fill(env.models.allReady ? DS.Color.success : DS.Color.warning).frame(width: DS.Size.dotXS, height: DS.Size.dotXS)
                Text(env.models.allReady ? "Modelos listos" : "Modelos pendientes")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape").foregroundStyle(DS.Color.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Configuración")
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.border).frame(height: DS.Layout.hairline) }
    }
}

/// Floating progress for the active processing job (any screen).
struct ProcessingToast: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if let job = env.processing.active {
                HStack(spacing: DS.Space.m) {
                    ProgressView(value: job.progress?.fraction ?? 0)
                        .progressViewStyle(.circular).controlSize(.small)
                        .opacity(job.progress?.fraction == nil ? 0 : 1)
                        .overlay { if job.progress?.fraction == nil { ProgressView().controlSize(.small) } }
                    VStack(alignment: .leading, spacing: DS.Space.none) {
                        Text(job.progress?.stage.displayName ?? "Procesando")
                            .font(DS.Font.captionEmphasis).foregroundStyle(DS.Color.textPrimary)
                        Text(job.progress?.message ?? "Preparando…")
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    }
                    if let f = job.progress?.fraction {
                        Text("\(Int(f * 100))%").font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary)
                    }
                    Button("Ver") { router.openMeeting(job.meetingId) }.buttonStyle(.ds(.ghost, size: .small))
                    IconButton(systemImage: "xmark", help: "Cancelar procesamiento") {
                        env.processing.cancel(job.meetingId)
                    }
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous).strokeBorder(DS.Color.border))
                .elevation(.overlay)
                .padding(.bottom, DS.Space.l)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let error = env.processing.lastError {
                InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill",
                             title: "El procesamiento falló", message: error.message) {
                    HStack {
                        Button("Ver") { router.openMeeting(error.meetingId) }.buttonStyle(.ds(.ghost, size: .small))
                        IconButton(systemImage: "xmark", help: "Cerrar") { env.processing.dismissError() }
                    }
                }
                .frame(maxWidth: DS.Layout.toastMaxWidth)
                .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.m))
                .elevation(.overlay)
                .padding(.bottom, DS.Space.l)
            }
        }
        .animation(DS.Motion.emphasized, value: env.processing.active?.meetingId)
    }
}
