import AppKit
import MeetingAudio
import MeetingCore
import MeetingSpeech
import SwiftUI

/// A selectable remote source: any app (in a call, playing audio, or just open).
struct SourceAppOption: Identifiable, Hashable {
    var id: String { selector.groupKey }
    let selector: AudioAppSelector
    let bundlePath: String?
    let kind: ConversationAppKind
    let isolation: CaptureIsolation
    let usingInput: Bool
    let usingOutput: Bool
    let inCall: Bool

    var statusText: String {
        if inCall { return "En llamada" }
        if usingOutput { return "Reproduciendo audio" }
        return "Abierta"
    }

    /// Apps known to the audio system first, then other running apps (the tap
    /// waits until they play audio). This app and background agents are excluded.
    static func options(audioApps: [AppAudioActivity], activeCalls: [AppAudioActivity]) -> [SourceAppOption] {
        let callIDs = Set(activeCalls.map(\.id))
        var result: [SourceAppOption] = audioApps
            .filter { $0.kind != .system || ConversationAppCatalog.entry(forBundleID: $0.app.bundleIdentifier) != nil }
            .map {
                // WebKit's shared GPU process has no bundle of its own: show Safari's icon.
                let path = $0.bundlePath ?? ($0.app.groupKey == "com.apple.WebKit.GPU" ? "/Applications/Safari.app" : nil)
                return SourceAppOption(selector: $0.app, bundlePath: path, kind: $0.kind, isolation: $0.isolation,
                                       usingInput: $0.usingInput, usingOutput: $0.usingOutput, inCall: callIDs.contains($0.id))
            }
        var known = Set(result.map(\.id))
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let url = app.bundleURL, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.bundleIdentifier != AppIdentity.fallbackBundleIdentifier else { continue }
            let entry = ConversationAppCatalog.entry(forBundleID: app.bundleIdentifier)
            // Safari plays audio from the shared WebKit GPU process, not from Safari.app.
            let selector = app.bundleIdentifier == "com.apple.Safari"
                ? AudioAppSelector(groupKey: "com.apple.WebKit.GPU", bundleIdentifier: "com.apple.WebKit.GPU", name: "Safari / WebKit")
                : AudioAppSelector(groupKey: url.path, bundleIdentifier: app.bundleIdentifier,
                                   name: app.localizedName ?? url.deletingPathExtension().lastPathComponent)
            guard !known.contains(selector.groupKey) else { continue }
            known.insert(selector.groupKey)
            result.append(SourceAppOption(
                selector: selector, bundlePath: url.path, kind: entry?.kind ?? .other, isolation: entry?.isolation ?? .exact,
                usingInput: false, usingOutput: false, inCall: false))
        }
        return result.sorted { lhs, rhs in
            func rank(_ o: SourceAppOption) -> Int {
                (o.inCall ? 0 : 4) + (o.usingOutput ? 0 : 2) + (o.kind == .conferencing || o.kind == .browser ? 0 : 1)
            }
            return rank(lhs) != rank(rhs) ? rank(lhs) < rank(rhs)
                : lhs.selector.name.localizedCaseInsensitiveCompare(rhs.selector.name) == .orderedAscending
        }
    }
}

struct RecordingView: View {
    enum Source: Hashable {
        case app(AudioAppSelector)
        case systemWide
        case microphoneOnly
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @State private var title = ""
    @State private var source: Source?
    @State private var captureMicrophone = true
    @State private var consentConfirmed = false
    @State private var showAllApps = false
    @State private var output: AudioDeviceInfo?
    @State private var input: AudioDeviceInfo?

    private var recording: RecordingController { env.recording }

    private var options: [SourceAppOption] {
        SourceAppOption.options(audioApps: env.calls.audioApps, activeCalls: env.calls.activeCalls)
    }

    var body: some View {
        PageScaffold(title: recording.isActive ? (recording.meeting?.title ?? "Grabando") : "Nueva grabación",
                     subtitle: recording.isActive ? nil
                        : "Graba conversaciones de cualquier app (Teams, Zoom, Meet, Slack…) sin bots: tu micrófono y el audio remoto en pistas separadas") {
            EmptyView()
        } content: {
            if recording.isActive {
                liveView
            } else {
                setupView
            }
        }
        .task { refreshDevices() }
        .onAppear {
            if title.isEmpty { title = defaultTitle(app: nil) }
            applyDefaultSource()
        }
        .onChange(of: router.preselectedRecordingApp) { applyDefaultSource() }
        .onChange(of: env.calls.activeCalls.map(\.id)) { if source == nil { applyDefaultSource() } }
    }

    private func defaultTitle(app: String?) -> String {
        let date = Date().formatted(.dateTime.day().month(.wide).hour().minute())
        return app.map { "Llamada de \($0) · \(date)" } ?? "Reunión \(date)"
    }

    private func applyDefaultSource() {
        if let preselected = router.preselectedRecordingApp {
            source = .app(preselected)
            title = defaultTitle(app: preselected.name)
            router.preselectedRecordingApp = nil
            return
        }
        guard source == nil else { return }
        switch env.settings.defaultCaptureMode {
        case .callApp:
            if let call = env.calls.activeCalls.first {
                source = .app(call.app)
                title = defaultTitle(app: call.app.name)
            }
        case .systemWide: source = .systemWide
        case .microphoneOnly: source = .microphoneOnly
        }
    }

    private func refreshDevices() {
        output = AudioDevices.defaultOutput()
        input = AudioDevices.defaultInput()
    }

    private var selectedOption: SourceAppOption? {
        guard case .app(let selector) = source else { return nil }
        return options.first { $0.selector.matches(groupKey: selector.groupKey) }
    }

    // MARK: Setup

    private var setupView: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            CallSuggestionBanner()
            if case .failed(let message) = recording.state {
                InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill", title: "No se pudo iniciar", message: message) {
                    IconButton(systemImage: "xmark", help: "Cerrar") { recording.dismissFailure() }
                }
            }
            if let id = recording.lastFinishedMeetingId {
                InlineBanner(tone: .success, systemImage: "checkmark.circle.fill", title: "Grabación guardada",
                             message: env.settings.autoProcessAfterRecording ? "Se está procesando localmente." : nil) {
                    Button("Abrir") { router.openMeeting(id) }.buttonStyle(.ds(.secondary, size: .small))
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Título").font(DS.Font.captionEmphasis).foregroundStyle(DS.Color.textSecondary)
                        TextField("Título de la conversación", text: $title).textFieldStyle(.roundedBorder)
                    }
                    sourcePicker
                    Toggle(isOn: $captureMicrophone) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text("Grabar mi micrófono").font(DS.Font.body)
                            Text(input.map { "\($0.name)\($0.transport.isBluetooth ? " · Bluetooth" : "")" } ?? "Sin dispositivo de entrada")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(source == .microphoneOnly)
                }
            }
            deviceWarnings
            if env.settings.requireConsentConfirmation {
                Toggle(isOn: $consentConfirmed) {
                    Text("Confirmo que informé a los participantes y que la grabación cumple las políticas aplicables de consentimiento.")
                        .font(DS.Font.callout)
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Button { start() } label: {
                    Label("Iniciar grabación", systemImage: "record.circle.fill")
                }
                .buttonStyle(.ds(.recording, size: .large))
                .disabled(source == nil || (env.settings.requireConsentConfirmation && !consentConfirmed)
                          || recording.state == .starting)
                if recording.state == .starting { ProgressView().controlSize(.small) }
                Spacer()
                Button { refreshDevices() } label: { Label("Actualizar dispositivos", systemImage: "arrow.clockwise") }
                    .buttonStyle(.dsGhost)
            }
            Text("La grabación nunca empieza sola. Mientras grabas, verás un indicador rojo en la barra de menús. macOS pedirá los permisos de Micrófono y de Grabación de audio del sistema la primera vez.")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
        }
        .frame(maxWidth: DS.Layout.singleColumnMaxWidth, alignment: .leading)
    }

    private func start() {
        guard let source else { return }
        let target: RemoteCaptureTarget = switch source {
        case .app(let selector): .application(selector)
        case .systemWide: .systemWide
        case .microphoneOnly: .none
        }
        Task {
            await recording.start(title: title.isEmpty ? defaultTitle(app: nil) : title, target: target,
                                  captureMicrophone: source == .microphoneOnly ? true : captureMicrophone)
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("Audio remoto").font(DS.Font.captionEmphasis).foregroundStyle(DS.Color.textSecondary)
                Spacer()
                if env.calls.activeCalls.isEmpty {
                    Text("Ninguna llamada detectada").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
            let visible = showAllApps ? options : Array(options.prefix(6))
            VStack(spacing: DS.Space.none) {
                ForEach(visible) { option in
                    sourceRow(selected: isSelected(option),
                              icon: AnyView(AppIcon(path: option.bundlePath)),
                              title: option.selector.name, subtitle: option.statusText,
                              badge: option.inCall ? ("En llamada", Tone.recording)
                                  : (option.isolation == .shared ? ("Audio compartido", Tone.warning) : nil)) {
                        source = .app(option.selector)
                        if title.hasPrefix("Reunión ") || title.hasPrefix("Llamada de ") { title = defaultTitle(app: option.selector.name) }
                    }
                }
                if options.count > 6 {
                    Button(showAllApps ? "Mostrar menos" : "Mostrar todas las apps (\(options.count))") { showAllApps.toggle() }
                        .buttonStyle(.ds(.ghost, size: .small))
                        .padding(.vertical, DS.Space.xs)
                }
                Divider().padding(.vertical, DS.Space.xs)
                sourceRow(selected: source == .systemWide, icon: AnyView(Image(systemName: "speaker.wave.3").frame(width: DS.Size.appIcon)),
                          title: "Todo el sistema", subtitle: "Cualquier app excepto esta (si la app no se puede aislar)",
                          badge: nil) { source = .systemWide }
                sourceRow(selected: source == .microphoneOnly, icon: AnyView(Image(systemName: "mic").frame(width: DS.Size.appIcon)),
                          title: "Ninguno (solo micrófono)", subtitle: "Conversaciones presenciales", badge: nil) {
                    source = .microphoneOnly
                }
            }
            sourceHelp
        }
    }

    private func isSelected(_ option: SourceAppOption) -> Bool {
        if case .app(let selector) = source { return selector.groupKey == option.id }
        return false
    }

    private func sourceRow(selected: Bool, icon: AnyView, title: String, subtitle: String,
                           badge: (String, Tone)?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? DS.Color.accent : DS.Color.textTertiary)
                icon
                VStack(alignment: .leading, spacing: DS.Space.xxxs) {
                    Text(title).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                    Text(subtitle).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(1)
                }
                Spacer()
                if let badge { StatusPill(text: badge.0, tone: badge.1) }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs + DS.Space.xxxs)
            .contentShape(Rectangle())
            .hoverHighlight(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var sourceHelp: some View {
        switch source {
        case .app(let selector):
            if let option = selectedOption, option.isolation == .shared {
                Label("\(selector.name) reproduce el audio desde un proceso compartido: se grabará todo lo que suene en \(selector.name) (por ejemplo, otras pestañas). Cierra lo que no sea la llamada.",
                      systemImage: "exclamationmark.triangle")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.warning)
            } else if selectedOption?.usingOutput != true {
                Label("\(selector.name) no está reproduciendo audio ahora. La pista remota empezará en cuanto lo haga (se mantiene sincronizada).",
                      systemImage: "info.circle")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            } else {
                Label("Se capturará solo el audio de \(selector.name).", systemImage: "checkmark.circle")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.success)
            }
        case .systemWide:
            Label("Se capturará el audio de TODAS las aplicaciones (excepto esta).", systemImage: "exclamationmark.triangle")
                .font(DS.Font.caption).foregroundStyle(DS.Color.warning)
        case .microphoneOnly, nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var deviceWarnings: some View {
        if captureMicrophone, source != .microphoneOnly, let output, output.isLikelySpeakers, !env.settings.microphoneVoiceProcessing {
            InlineBanner(tone: .warning, systemImage: "speaker.wave.2",
                         title: "Riesgo de eco: el audio sale por \(output.dataSourceName ?? output.name)",
                         message: "El micrófono puede captar las voces remotas. Usa audífonos o activa la cancelación de eco en Ajustes › Audio. Los fragmentos de eco se marcarán como “eco probable”.")
        }
        if captureMicrophone, let input, input.transport.isBluetooth {
            InlineBanner(tone: .info, systemImage: "airpods",
                         title: "Micrófono Bluetooth (\(input.name))",
                         message: "En llamadas, los audífonos Bluetooth usan un perfil de banda estrecha; la transcripción puede ser menos precisa.")
        }
    }

    // MARK: Live

    private var remoteName: String { recording.recordingApp?.name ?? "remoto" }

    private var liveView: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            if let ended = env.calls.endSuggestion {
                InlineBanner(tone: .warning, systemImage: "phone.down",
                             title: "Parece que la llamada de \(ended.name) terminó",
                             message: "\(ended.name) dejó de usar el micrófono. ¿Detener y guardar?") {
                    HStack {
                        Button("Seguir grabando") { env.calls.keepRecording() }.buttonStyle(.ds(.secondary, size: .small))
                        Button("Detener y guardar") { env.calls.stopRecordingFromSuggestion() }.buttonStyle(.ds(.recording, size: .small))
                    }
                }
            }
            SurfaceCard(padding: DS.Space.xl, elevation: .raised) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack(spacing: DS.Space.m) {
                        if recording.state == .paused {
                            Image(systemName: "pause.circle.fill").foregroundStyle(DS.Color.warning)
                            Text("En pausa").font(DS.Font.headline).foregroundStyle(DS.Color.warning)
                        } else {
                            RecordingDot(size: DS.Size.dotL)
                            Text("Grabando").font(DS.Font.headline).foregroundStyle(DS.Color.recording)
                        }
                        Spacer()
                        if let scope = recording.scope { ScopeBadge(scope: scope, appName: recording.recordingApp?.name) }
                    }
                    Text(Timecode.compact(recording.elapsed)).font(DS.Font.timer).foregroundStyle(DS.Color.textPrimary)
                    meter(recording.microphonePaused ? "Micrófono (en pausa)" : "Micrófono local", systemImage: recording.microphonePaused ? "mic.slash.fill" : "mic.fill",
                          level: recording.micLevel, tint: DS.Color.success,
                          enabled: recording.capturesMicrophone && !recording.microphonePaused)
                    meter("Audio \(remoteName)", systemImage: "person.3.fill", level: recording.remoteLevel, tint: DS.Color.info,
                          enabled: recording.scope != .microphoneOnly)
                    HStack(spacing: DS.Space.m) {
                        Button {
                            recording.state == .paused ? recording.resume() : recording.pause()
                        } label: {
                            Label(recording.state == .paused ? "Reanudar" : "Pausar todo",
                                  systemImage: recording.state == .paused ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(.ds(.secondary, size: .large))
                        if recording.capturesMicrophone {
                            Button { recording.toggleMicrophonePause() } label: {
                                Label(recording.microphonePaused ? "Reactivar mi micrófono" : "Pausar mi micrófono",
                                      systemImage: recording.microphonePaused ? "mic.fill" : "mic.slash")
                            }
                            .buttonStyle(.ds(.secondary, size: .large))
                            .help("Deja de grabar tu micrófono sin detener la grabación (⌃⌘M). Se guarda como pausa. Silenciarte en la llamada no lo pausa.")
                        }
                        Button { recording.stop() } label: { Label("Detener y guardar", systemImage: "stop.fill") }
                            .buttonStyle(.ds(.recording, size: .large))
                            .disabled(recording.state == .stopping)
                    }
                }
            }
            if recording.showsMuteReminder {
                CallMuteReminderBanner(appName: recording.recordingApp?.name,
                                       onPauseMicrophone: { recording.pauseMicrophone() },
                                       onDismiss: { recording.dismissMuteReminder() })
            }
            if !recording.remoteProcesses.isEmpty {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Procesos de \(remoteName) capturados").font(DS.Font.headline)
                        ForEach(recording.remoteProcesses) { p in
                            HStack {
                                Circle().fill(p.isRunningOutput ? DS.Color.success : DS.Color.border).frame(width: DS.Size.dotS, height: DS.Size.dotS)
                                Text(p.displayName).font(DS.Font.callout)
                                Text(p.bundleID ?? "").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                            }
                        }
                    }
                }
            }
            ForEach(recording.warnings, id: \.self) { warning in
                InlineBanner(tone: warning.isCritical ? .danger : .warning,
                             systemImage: warning.isCritical ? "exclamationmark.octagon" : "exclamationmark.triangle",
                             title: warning.message)
            }
            livePanel
        }
        .frame(maxWidth: DS.Layout.singleColumnMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private var livePanel: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack {
                    Text("Transcripción en vivo").font(DS.Font.headline)
                    StatusPill(text: "Provisional", tone: .warning, systemImage: "hourglass")
                    Spacer()
                }
                Text("Texto aproximado (Parakeet Ultra en ventanas de 11 s). La transcripción definitiva, con hablantes, se genera al detener la grabación.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                if !env.settings.liveTranscription {
                    Text("Desactivada en Ajustes › Transcripción.").font(DS.Font.callout).foregroundStyle(DS.Color.textTertiary)
                } else if let status = recording.liveStatus {
                    Text(status).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                } else if recording.liveText.isEmpty {
                    Text("Esperando voz…").font(DS.Font.callout).foregroundStyle(DS.Color.textTertiary)
                }
                ForEach([AudioSource.remoteSystemAudio, .localMicrophone], id: \.self) { source in
                    if let update = recording.liveText[source], !(update.confirmed.isEmpty && update.volatile.isEmpty) {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Label(source == .localMicrophone ? "Micrófono (tú)" : "Audio \(remoteName)",
                                  systemImage: source == .localMicrophone ? "mic.fill" : "person.3.fill")
                                .font(DS.Font.captionEmphasis).foregroundStyle(DS.Color.textSecondary)
                            Text(liveAttributed(update))
                                .font(DS.Font.reading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func liveAttributed(_ update: LiveTranscriptUpdate) -> AttributedString {
        var confirmed = AttributedString(String(update.confirmed.suffix(600)))
        confirmed.foregroundColor = DS.Color.textPrimary
        guard !update.volatile.isEmpty else { return confirmed }
        var volatile = AttributedString(" " + update.volatile)
        volatile.foregroundColor = DS.Color.textTertiary
        return confirmed + volatile
    }

    private func meter(_ label: String, systemImage: String, level: AudioLevel, tint: Color, enabled: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            Label(label, systemImage: systemImage).font(DS.Font.callout).frame(width: DS.Layout.Control.meterLabelWidth, alignment: .leading).lineLimit(1)
            LevelMeterView(level: enabled ? level.normalized : 0, tint: tint)
            Text(enabled ? String(format: "%.0f dB", max(-60, level.rmsDB)) : "—")
                .font(DS.Font.mono).foregroundStyle(DS.Color.textTertiary).frame(width: DS.Layout.Control.meterCompactWidth, alignment: .trailing)
        }
        .opacity(enabled ? 1 : DS.Opacity.disabled)
    }
}

/// App icon from its bundle path (generic icon when unknown).
struct AppIcon: View {
    let path: String?
    var size: CGFloat = DS.Size.appIcon

    var body: some View {
        Group {
            if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(DS.Color.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension AudioAppSelector {
    func matches(groupKey: String) -> Bool { self.groupKey == groupKey }
}
