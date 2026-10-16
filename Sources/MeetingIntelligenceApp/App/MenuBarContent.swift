import AppKit
import MeetingCore
import SwiftUI

/// Always-visible recording indicator in the menu bar.
struct MenuBarLabel: View {
    let recording: RecordingController
    var callDetected = false

    var body: some View {
        if recording.isActive {
            Image(systemName: recording.state == .paused ? "pause.circle.fill" : "record.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red, .primary)
                .accessibilityLabel(recording.state == .paused ? "Grabación en pausa" : "Grabando")
        } else if callDetected {
            Image(systemName: "phone.connection")
                .accessibilityLabel("Llamada detectada")
        } else {
            Image(systemName: "waveform")
                .accessibilityLabel(AppIdentity.displayName)
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text(AppIdentity.displayName).font(DS.Font.headline)
                Spacer()
                if env.recording.isActive { RecordingDot(size: 8) }
            }
            if env.recording.isActive {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(env.recording.meeting?.title ?? "Grabación")
                        .font(DS.Font.bodyEmphasis).lineLimit(1)
                    Text(Timecode.compact(env.recording.elapsed)).font(DS.Font.metric)
                    HStack(spacing: DS.Space.s) {
                        Label("Mic", systemImage: "mic.fill").font(DS.Font.caption).frame(width: 52, alignment: .leading)
                        LevelMeterView(level: env.recording.micLevel.normalized)
                    }
                    HStack(spacing: DS.Space.s) {
                        Label("Remoto", systemImage: "speaker.wave.2.fill").font(DS.Font.caption).frame(width: 52, alignment: .leading)
                        LevelMeterView(level: env.recording.remoteLevel.normalized, tint: DS.Color.info)
                    }
                    if env.recording.capturesMicrophone {
                        Button(env.recording.microphonePaused ? "Reactivar mi micrófono" : "Pausar mi micrófono") {
                            env.recording.toggleMicrophonePause()
                        }
                        .buttonStyle(.ds(.ghost, size: .small))
                    }
                    if let ended = env.calls.endSuggestion {
                        Text("Parece que la llamada de \(ended.name) terminó.").font(DS.Font.caption)
                            .foregroundStyle(DS.Color.warning)
                    }
                    HStack {
                        Button(env.recording.state == .paused ? "Reanudar" : "Pausar") {
                            env.recording.state == .paused ? env.recording.resume() : env.recording.pause()
                        }
                        .buttonStyle(.ds(.secondary, size: .small))
                        Button("Detener y guardar") { env.recording.stop() }
                            .buttonStyle(.ds(.recording, size: .small))
                    }
                }
            } else {
                if let call = env.calls.activeCalls.first {
                    Label("\(call.app.name) está en una llamada", systemImage: "phone.connection")
                        .font(DS.Font.callout).foregroundStyle(DS.Color.recording)
                    Button("Preparar grabación de \(call.app.name)…") {
                        router.preselectedRecordingApp = call.app
                        router.section = .recording
                        showMainWindow()
                    }
                    .buttonStyle(.ds(.recording, size: .small))
                }
                Text("No se está grabando.").font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                Button {
                    router.section = .recording
                    showMainWindow()
                } label: {
                    Label("Nueva grabación…", systemImage: "record.circle")
                }
                .buttonStyle(.ds(.primary, size: .small))
            }
            Divider()
            Button("Abrir \(AppIdentity.displayName)") { showMainWindow() }.buttonStyle(.ds(.ghost, size: .small))
            Button("Salir") { NSApp.terminate(nil) }.buttonStyle(.ds(.ghost, size: .small))
        }
        .padding(DS.Space.l)
        .frame(width: 280)
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
