import MeetingCore
import SwiftUI

/// Floating notice for a new version (and for the result of the last update) above the detail column.
struct AppUpdateBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        AppUpdateBannerContent(updates: env.updates)
    }
}

struct AppUpdateBannerContent: View {
    let updates: AppUpdateController

    var body: some View {
        Group {
            if let done = updates.completedUpdate {
                card {
                    InlineBanner(tone: done.succeeded ? .success : .warning,
                                 systemImage: done.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                 title: done.succeeded ? "Se actualizó a la versión \(done.version)"
                                                       : "La actualización a la versión \(done.version) no se completó",
                                 message: completedMessage(succeeded: done.succeeded)) {
                        IconButton(systemImage: "xmark", help: "Cerrar") { updates.dismissCompletedUpdate() }
                    }
                }
            } else if let release = updates.bannerRelease {
                card {
                    InlineBanner(tone: .info, systemImage: "arrow.down.circle.fill", title: title(release),
                                 message: "Tienes la \(updates.currentVersion). Se descarga desde GitHub y se verifica antes de instalar.") {
                        HStack(spacing: DS.Space.s) {
                            Button("Ver novedades") { updates.isSheetPresented = true }
                                .buttonStyle(.ds(.ghost, size: .small))
                            switch updates.phase {
                            case .available, .failed:
                                Button("Actualizar") {
                                    updates.isSheetPresented = true
                                    // Where the app cannot be replaced, the sheet explains why and links to GitHub.
                                    if updates.installLocationProblem == nil { updates.download() }
                                }
                                    .buttonStyle(.ds(.primary, size: .small))
                            case .ready:
                                Button("Reiniciar e instalar") { updates.installAndRelaunch() }
                                    .buttonStyle(.ds(.primary, size: .small))
                                    .disabled(updates.installBlockedReason != nil)
                                    .help(updates.installBlockedReason ?? "")
                            default:
                                EmptyView()
                            }
                            IconButton(systemImage: "xmark", help: "Ahora no") { updates.dismissBanner() }
                        }
                    }
                }
            }
        }
        .animation(DS.Motion.emphasized, value: updates.bannerRelease?.id)
    }

    private func completedMessage(succeeded: Bool) -> String? {
        if !succeeded {
            return "Sigues en la versión \(updates.currentVersion). Puedes intentarlo de nuevo desde Ajustes › General."
        }
        return updates.permissionsResetOnUpdate
            ? "Si macOS vuelve a pedir los permisos de micrófono y de audio del sistema, concédelos para seguir grabando."
            : nil
    }

    private func title(_ release: AppRelease) -> String {
        switch updates.phase {
        case .downloading(let fraction?): "Descargando la versión \(release.versionString)… \(Int(fraction * 100)) %"
        case .downloading: "Descargando la versión \(release.versionString)…"
        case .ready: "La versión \(release.versionString) está lista para instalar"
        case .failed: "No se pudo actualizar a la versión \(release.versionString)"
        default: "Hay una versión nueva: \(release.versionString)"
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: DS.Layout.bannerMaxWidth)
            .background(DS.Color.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.m))
            .elevation(.overlay)
            .padding(.top, DS.Space.l)
            .padding(.horizontal, DS.Space.l)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct AppUpdateSheet: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        AppUpdatePanel(updates: env.updates)
            .interactiveDismissDisabled(env.updates.phase == .installing)
    }
}

/// Release notes, download progress and the install button. Standalone so it can be rendered in snapshots.
struct AppUpdatePanel: View {
    let updates: AppUpdateController

    /// A release is on offer (not up to date, not checking).
    private var offered: AppRelease? {
        updates.phase == .upToDate || updates.phase == .checking ? nil : updates.release
    }

    private var canStartDownload: Bool {
        switch updates.phase {
        case .available, .failed: offered != nil
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            header
            if let release = offered {
                notes(release)
                status
            } else if case .failed(let message) = updates.phase {
                InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill",
                             title: "No se pudo buscar actualizaciones", message: message)
            }
            actions
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Layout.Sheet.xl)
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: headerIcon).font(DS.Font.headerIcon)
                .foregroundStyle(updates.phase == .upToDate ? DS.Color.success : DS.Color.accent)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(headerTitle).font(DS.Font.title)
                Text(headerSubtitle).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    private var headerIcon: String {
        switch updates.phase {
        case .upToDate: "checkmark.circle.fill"
        case .checking: "arrow.triangle.2.circlepath"
        default: "arrow.down.app.fill"
        }
    }

    private var headerTitle: String {
        if updates.phase == .checking { return "Buscando actualizaciones…" }
        if updates.phase == .upToDate { return "\(AppIdentity.displayName) está al día" }
        if let release = offered { return "Versión \(release.versionString) disponible" }
        return "Actualizaciones"
    }

    private var headerSubtitle: String {
        var parts = ["Tienes la versión \(updates.currentVersion)"]
        if let release = offered {
            parts.append(ByteCountFormatter.string(fromByteCount: release.archive.size, countStyle: .file))
            if let date = release.publishedAt { parts.append("publicada el \(date.formatted(date: .long, time: .omitted))") }
        }
        return parts.joined(separator: " · ")
    }

    private func notes(_ release: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if !release.highlights.isEmpty {
                SurfaceCard {
                    ScrollView {
                        Text(Self.attributed(release.highlights))
                            .font(DS.Font.body).foregroundStyle(DS.Color.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: DS.Layout.Sheet.listHeight)
                }
            }
            Link("Ver las notas completas en GitHub", destination: release.pageURL).font(DS.Font.callout)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updates.phase {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                Text("Descargando y verificando…").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
        case .ready:
            Label("Descargada y verificada: firma de la publicación, versión y firma de código.",
                  systemImage: "checkmark.seal.fill")
                .font(DS.Font.callout).foregroundStyle(DS.Color.success)
        case .installing:
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text("Instalando y reiniciando…").font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            }
        case .failed(let message):
            InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill",
                         title: "No se pudo actualizar", message: message)
        default:
            EmptyView()
        }
        if let problem = updates.installLocationProblem {
            InlineBanner(tone: .warning, systemImage: "folder.badge.questionmark",
                         title: "No se puede instalar desde aquí", message: problem)
        } else if updates.phase == .ready, let blocked = updates.installBlockedReason {
            InlineBanner(tone: .warning, systemImage: "pause.circle",
                         title: "Se podrá instalar al terminar", message: blocked)
        }
        if updates.permissionsResetOnUpdate {
            Text("La app no tiene firma de desarrollador: al abrir la versión nueva, macOS puede volver a pedir los permisos de micrófono y de audio del sistema.")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Space.s) {
            if canStartDownload {
                Button("Omitir esta versión") { updates.skipRelease() }.buttonStyle(.dsGhost)
            }
            Spacer()
            switch updates.phase {
            case .downloading:
                Button("Cancelar descarga") { updates.cancelDownload() }.buttonStyle(.dsSecondary)
            case .installing:
                EmptyView()
            default:
                Button(offered == nil ? "Cerrar" : "Más tarde") {
                    updates.isSheetPresented = false
                    if offered != nil { updates.dismissBanner() }
                }
                .buttonStyle(.dsSecondary).keyboardShortcut(.cancelAction)
            }
            primaryAction
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if canStartDownload, let release = offered {
            if updates.installLocationProblem != nil {
                Link("Descargar desde GitHub", destination: release.pageURL).buttonStyle(.dsPrimary)
            } else {
                Button("Descargar e instalar") { updates.download() }
                    .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
            }
        } else if updates.phase == .ready {
            Button("Reiniciar e instalar") { updates.installAndRelaunch() }
                .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                .disabled(updates.installBlockedReason != nil)
        } else if case .failed = updates.phase {
            Button("Reintentar") { Task { await updates.check(userInitiated: true) } }.buttonStyle(.dsPrimary)
        }
    }

    /// Inline Markdown (bold, code, links) of the release notes; line breaks are kept.
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Settings › General › Actualizaciones.
struct AppUpdateSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        let updates = env.updates
        Section("Actualizaciones") {
            if updates.isConfigured {
                Toggle("Buscar actualizaciones automáticamente", isOn: $settings.checkForAppUpdates)
                Text("Consulta los releases públicos de GitHub al abrir la app y una vez al día. No se envía nada de tus reuniones y nunca se instala nada sin que lo confirmes.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                HStack {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Versión \(updates.currentVersion)")
                        Text(statusText).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    }
                    Spacer()
                    Button("Buscar ahora") { Task { await updates.check(userInitiated: true) } }
                        .disabled(updates.phase == .checking || updates.phase == .installing)
                }
                if let skipped = settings.skippedAppVersion {
                    HStack {
                        Text("Omitiste la versión \(skipped).").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        Spacer()
                        Button("Volver a avisarme") { updates.unskip() }
                    }
                }
            } else {
                Text("Versión \(updates.currentVersion). Esta compilación no tiene configuradas las actualizaciones desde la app.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
        }
    }

    private var statusText: String {
        let updates = env.updates
        switch updates.phase {
        case .checking:
            return "Buscando…"
        case .available, .downloading, .ready, .failed:
            if let release = updates.release { return "Disponible: versión \(release.versionString)" }
        default:
            break
        }
        guard let last = updates.lastChecked else { return "Aún no se ha comprobado" }
        return "Al día · última comprobación \(last.formatted(.relative(presentation: .named)))"
    }
}
