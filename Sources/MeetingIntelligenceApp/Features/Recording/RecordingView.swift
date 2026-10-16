import MeetingAudio
import MeetingCore
import MeetingSpeech
import SwiftUI

struct RecordingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @State private var title = ""
    @State private var target: RemoteCaptureTarget = .teams
    @State private var captureMicrophone = true
    @State private var consentConfirmed = false
    @State private var teamsProcesses: [AudioProcessInfo] = []
    @State private var output: AudioDeviceInfo?
    @State private var input: AudioDeviceInfo?

    private var recording: RecordingController { env.recording }

    var body: some View {
        PageScaffold(title: recording.isActive ? (recording.meeting?.title ?? "Grabando") : "Nueva grabación",
                     subtitle: recording.isActive ? nil : "Graba una llamada de Microsoft Teams sin bots: micrófono y audio remoto en pistas separadas") {
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
            target = env.settings.defaultRemoteTarget
            if title.isEmpty { title = defaultTitle }
        }
    }

    private var defaultTitle: String {
        "Reunión \(Date().formatted(.dateTime.day().month(.wide).hour().minute()))"
    }

    private func refreshDevices() {
        teamsProcesses = AudioProcessCatalog.teamsProcesses()
        output = AudioDevices.defaultOutput()
        input = AudioDevices.defaultInput()
    }

    // MARK: Setup

    private var setupView: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
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
                        TextField("Título de la reunión", text: $title).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Audio remoto").font(DS.Font.captionEmphasis).foregroundStyle(DS.Color.textSecondary)
                        Picker("Audio remoto", selection: $target) {
                            Text("Solo Microsoft Teams").tag(RemoteCaptureTarget.teams)
                            Text("Todo el sistema").tag(RemoteCaptureTarget.systemWide)
                            Text("Ninguno").tag(RemoteCaptureTarget.none)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        remoteTargetHelp
                    }
                    Toggle(isOn: $captureMicrophone) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Grabar mi micrófono").font(DS.Font.body)
                            Text(input.map { "\($0.name)\($0.transport.isBluetooth ? " · Bluetooth" : "")" } ?? "Sin dispositivo de entrada")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                    .toggleStyle(.switch)
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
                Button {
                    Task {
                        await recording.start(title: title.isEmpty ? defaultTitle : title, target: target,
                                              captureMicrophone: captureMicrophone)
                    }
                } label: {
                    Label("Iniciar grabación", systemImage: "record.circle.fill")
                }
                .buttonStyle(.ds(.recording, size: .large))
                .disabled((env.settings.requireConsentConfirmation && !consentConfirmed)
                          || (!captureMicrophone && target == .none) || recording.state == .starting)
                if recording.state == .starting { ProgressView().controlSize(.small) }
                Spacer()
                Button { refreshDevices() } label: { Label("Actualizar dispositivos", systemImage: "arrow.clockwise") }
                    .buttonStyle(.dsGhost)
            }
            Text("La grabación nunca empieza sola. Mientras grabas, verás un indicador rojo en la barra de menús. macOS pedirá los permisos de Micrófono y de Grabación de audio del sistema la primera vez.")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    @ViewBuilder
    private var remoteTargetHelp: some View {
        switch target {
        case .teams:
            if teamsProcesses.isEmpty {
                Label("Teams no está reproduciendo audio ahora. La pista remota empezará en cuanto Teams emita sonido (se mantiene sincronizada).",
                      systemImage: "info.circle")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            } else {
                Label("Se capturarán solo \(teamsProcesses.count) procesos de Microsoft Teams: \(Set(teamsProcesses.compactMap(\.bundleID)).sorted().joined(separator: ", "))",
                      systemImage: "checkmark.circle")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.success)
            }
        case .systemWide:
            Label("Se capturará el audio de TODAS las aplicaciones (excepto esta). Úsalo solo si Teams no se puede aislar.",
                  systemImage: "exclamationmark.triangle")
                .font(DS.Font.caption).foregroundStyle(DS.Color.warning)
        case .none:
            Label("Solo se grabará el micrófono (reuniones presenciales).", systemImage: "mic")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
        }
    }

    @ViewBuilder
    private var deviceWarnings: some View {
        if captureMicrophone, target != .none, let output, output.isLikelySpeakers, !env.settings.microphoneVoiceProcessing {
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

    private var liveView: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            SurfaceCard(padding: DS.Space.xl, elevation: .raised) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack(spacing: DS.Space.m) {
                        if recording.state == .paused {
                            Image(systemName: "pause.circle.fill").foregroundStyle(DS.Color.warning)
                            Text("En pausa").font(DS.Font.headline).foregroundStyle(DS.Color.warning)
                        } else {
                            RecordingDot(size: 12)
                            Text("Grabando").font(DS.Font.headline).foregroundStyle(DS.Color.recording)
                        }
                        Spacer()
                        if let scope = recording.scope { ScopeBadge(scope: scope) }
                    }
                    Text(Timecode.compact(recording.elapsed)).font(DS.Font.timer).foregroundStyle(DS.Color.textPrimary)
                    meter("Micrófono local", systemImage: "mic.fill", level: recording.micLevel, tint: DS.Color.success,
                          enabled: recording.capturesMicrophone)
                    meter("Audio remoto (Teams)", systemImage: "person.3.fill", level: recording.remoteLevel, tint: DS.Color.info,
                          enabled: recording.scope != .microphoneOnly)
                    HStack(spacing: DS.Space.m) {
                        Button {
                            recording.state == .paused ? recording.resume() : recording.pause()
                        } label: {
                            Label(recording.state == .paused ? "Reanudar" : "Pausar",
                                  systemImage: recording.state == .paused ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(.ds(.secondary, size: .large))
                        Button { recording.stop() } label: { Label("Detener y guardar", systemImage: "stop.fill") }
                            .buttonStyle(.ds(.recording, size: .large))
                            .disabled(recording.state == .stopping)
                    }
                }
            }
            if !recording.remoteProcesses.isEmpty {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Procesos de Teams capturados").font(DS.Font.headline)
                        ForEach(recording.remoteProcesses) { p in
                            HStack {
                                Circle().fill(p.isRunningOutput ? DS.Color.success : DS.Color.border).frame(width: 7, height: 7)
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
        .frame(maxWidth: 680, alignment: .leading)
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
                            Label(source == .localMicrophone ? "Micrófono (tú)" : "Audio remoto",
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
            Label(label, systemImage: systemImage).font(DS.Font.callout).frame(width: 180, alignment: .leading)
            LevelMeterView(level: enabled ? level.normalized : 0, tint: tint)
            Text(enabled ? String(format: "%.0f dB", max(-60, level.rmsDB)) : "—")
                .font(DS.Font.mono).foregroundStyle(DS.Color.textTertiary).frame(width: 52, alignment: .trailing)
        }
        .opacity(enabled ? 1 : 0.5)
    }
}
