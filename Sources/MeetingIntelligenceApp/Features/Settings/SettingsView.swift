import AppKit
import MeetingAudio
import MeetingCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AudioSettings().tabItem { Label("Audio", systemImage: "waveform") }
            TranscriptionSettings().tabItem { Label("Transcripción", systemImage: "text.bubble") }
            ModelSettings().tabItem { Label("Modelos", systemImage: "cpu") }
            AISettings().tabItem { Label("IA", systemImage: "sparkles") }
            PrivacySettings().tabItem { Label("Privacidad", systemImage: "lock.shield") }
            MCPSettings().tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .frame(width: 680, height: 560)
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(DS.Color.background)
    }
}

struct GeneralSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var name = ""

    var body: some View {
        @Bindable var settings = env.settings
        SettingsPage {
            Section("Usuario local") {
                TextField("Tu nombre", text: $name)
                    .onSubmit(saveName)
                Text("El micrófono de este Mac se atribuye a este nombre cuando solo hablas tú.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                Button("Guardar nombre", action: saveName).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section("Idioma") {
                Picker("Idioma principal de las reuniones", selection: $settings.language) {
                    Text("Español (Colombia)").tag("es-CO")
                    Text("Español (España)").tag("es-ES")
                    Text("Español (México)").tag("es-MX")
                    Text("English").tag("en-US")
                }
                Text("Parakeet Ultra es multilingüe: los términos en inglés se transcriben aunque el idioma principal sea español.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
            Section("Grabación") {
                Toggle("Pedir confirmación de consentimiento antes de grabar", isOn: $settings.requireConsentConfirmation)
                Toggle("Procesar automáticamente al terminar o importar", isOn: $settings.autoProcessAfterRecording)
            }
        }
        .onAppear { name = (try? env.database.localUser()?.displayName) ?? env.settings.localUserName }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        env.settings.localUserName = trimmed
        _ = try? env.database.setLocalUserName(trimmed)
    }
}

struct AudioSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        SettingsPage {
            Section("Captura remota") {
                Picker("Fuente predeterminada", selection: $settings.defaultRemoteTarget) {
                    Text("Solo Microsoft Teams").tag(RemoteCaptureTarget.teams)
                    Text("Todo el sistema").tag(RemoteCaptureTarget.systemWide)
                    Text("Ninguna (solo micrófono)").tag(RemoteCaptureTarget.none)
                }
                Text("Teams se captura con Core Audio Process Taps (macOS 14.2+) sin bots ni modificar Teams. Requiere el permiso “Grabación de audio del sistema”.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
            Section("Micrófono") {
                Toggle("Cancelación de eco de Apple (Voice Processing)", isOn: $settings.microphoneVoiceProcessing)
                Text("Útil si usas altavoces. Puede alterar ligeramente el timbre de tu voz. Con audífonos no es necesaria.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                if let input = AudioDevices.defaultInput() {
                    LabeledContent("Entrada actual", value: "\(input.name) (\(input.transport.rawValue))")
                }
                if let output = AudioDevices.defaultOutput() {
                    LabeledContent("Salida actual", value: "\(output.name)\(output.isLikelySpeakers ? " · riesgo de eco" : "")")
                }
                LabeledContent("Permiso de micrófono", value: RecordingSession.microphonePermissionGranted() ? "Concedido" : "No concedido")
                Button("Abrir Privacidad › Micrófono") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                Button("Abrir Privacidad › Grabación de pantalla y audio del sistema") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }
}

struct TranscriptionSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var terms: [VocabularyTerm] = []
    @State private var canonical = ""
    @State private var variants = ""

    var body: some View {
        @Bindable var settings = env.settings
        SettingsPage {
            Section("Durante la grabación") {
                Toggle("Transcripción provisional en vivo", isOn: $settings.liveTranscription)
                Text("Usa Parakeet Ultra en ventanas deslizantes (FluidAudio). Es aproximada y no reemplaza la transcripción definitiva.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
            Section("Hablantes") {
                Toggle("Diarizar (separar hablantes)", isOn: $settings.diarize)
                Toggle("Detectar varias personas cerca de mi micrófono", isOn: $settings.detectMultipleLocalSpeakers)
                Text("Si se detecta más de una voz en el micrófono, no se atribuye todo automáticamente a ti.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                Toggle("Marcar eco del micrófono (voces remotas captadas por altavoces)", isOn: $settings.flagEcho)
                Picker("Sensibilidad a turnos cortos", selection: $settings.diarizationStepRatio) {
                    Text("Alta (recomendada para llamadas)").tag(0.1)
                    Text("Estándar").tag(0.2)
                }
                Text("Se aplica al reiniciar la aplicación.").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
            Section("Diccionario personalizado") {
                Text("Corrige nombres propios y términos técnicos. El texto original de Parakeet Ultra se conserva siempre.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                HStack {
                    TextField("Forma correcta (ej. Katty)", text: $canonical)
                    TextField("Variantes separadas por coma (ej. Cati, Katy)", text: $variants)
                    Button("Añadir") { add() }.disabled(canonical.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(terms) { term in
                    HStack {
                        Text(term.canonical).font(DS.Font.bodyEmphasis)
                        Text(term.variants.joined(separator: ", ")).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        Spacer()
                        Button(role: .destructive) { try? env.database.deleteTerm(id: term.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Text("Los cambios se aplican al procesar o reprocesar reuniones.").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
        }
        .task {
            do { for try await value in env.database.observeVocabulary() { terms = value } } catch {}
        }
    }

    private func add() {
        let list = variants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try? env.database.save(term: VocabularyTerm(canonical: canonical.trimmingCharacters(in: .whitespaces), variants: list))
        canonical = ""
        variants = ""
    }
}

struct ModelSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SettingsPage {
            Section("Transcripción") {
                LabeledContent("Motor", value: env.models.asrDescriptor.displayName)
                LabeledContent("Modelo", value: env.models.asrDescriptor.modelIdentifier)
                LabeledContent("Estado", value: describe(env.models.asrStatus))
                LabeledContent("Ubicación") {
                    Button(env.models.asrCacheDirectory.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([env.models.asrCacheDirectory])
                    }.buttonStyle(.link)
                }
                Text("Parakeet Ultra se ejecuta en el Apple Neural Engine con Core ML. No se sustituye por otro modelo si no está disponible.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
            Section("Diarización") {
                LabeledContent("Modelo", value: "pyannote community segmentación + WeSpeaker + VBx (FluidAudio)")
                LabeledContent("Estado", value: describe(env.models.diarizationStatus))
            }
            Section {
                Button("Descargar / verificar modelos") { Task { await env.models.prepareAll() } }
                    .disabled({ if case .preparing = env.models.asrStatus { return true } else { return false } }())
            }
        }
        .task { await env.models.refresh() }
    }

    private func describe(_ status: ModelStatusModel.Status) -> String {
        switch status {
        case .unknown: "Comprobando…"
        case .notDownloaded: "No descargado"
        case .preparing(let text, let f): "\(text)\(f.map { " \(Int($0 * 100))%" } ?? "")"
        case .ready: "Listo (en caché local)"
        case .failed(let message): "Error: \(message)"
        }
    }
}

struct AISettings: View {
    var body: some View {
        ScrollView { ProvidersPane().padding(.top, DS.Space.l) }
            .background(DS.Color.background)
    }
}

struct PrivacySettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var librarySize: Int64 = 0

    var body: some View {
        @Bindable var settings = env.settings
        SettingsPage {
            Section("Conservación de audio") {
                Picker("Eliminar el audio de reuniones transcritas después de", selection: Binding(
                    get: { settings.audioRetentionDays ?? 0 }, set: { settings.audioRetentionDays = $0 == 0 ? nil : $0 })) {
                    Text("Nunca").tag(0)
                    Text("7 días").tag(7)
                    Text("30 días").tag(30)
                    Text("90 días").tag(90)
                }
                Text("La transcripción, los hablantes y los análisis se conservan. Se aplica al iniciar la app.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
            Section("Perfiles de voz") {
                Text("Los perfiles biométricos requieren consentimiento, se cifran con AES-GCM (clave en el Llavero), nunca salen de este Mac y pueden revocarse por persona en Participantes.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
            Section("Almacenamiento") {
                LabeledContent("Biblioteca") {
                    Button(env.paths.root.path) { NSWorkspace.shared.activateFileViewerSelecting([env.paths.root]) }.buttonStyle(.link)
                }
                LabeledContent("Tamaño", value: ByteCountFormatter.string(fromByteCount: librarySize, countStyle: .file))
                Text("Directorios con permisos solo para tu usuario (0700). Protección en reposo: FileVault. Los datos borrados se sobrescriben (SQLite secure_delete).")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
            Section("Proveedores externos") {
                Text("Nada se envía automáticamente. Antes de usar un proveedor en la nube se muestra exactamente qué se compartirá. Nunca se envían audio ni datos biométricos.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            }
        }
        .task { librarySize = Self.directorySize(env.paths.root) }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

struct MCPSettings: View {
    @Environment(AppEnvironment.self) private var env
    @State private var policy = MCPAccessPolicy()
    @State private var copied = false

    private var serverPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/meeting-intelligence-mcp").path
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "<ruta>/meeting-intelligence-mcp"
    }

    var body: some View {
        SettingsPage {
            Section("Acceso") {
                Toggle("Permitir que clientes MCP locales consulten reuniones", isOn: Binding(
                    get: { policy.enabled }, set: { policy.enabled = $0; save() }))
                Toggle("Incluir correos de participantes", isOn: Binding(
                    get: { policy.exposeEmails }, set: { policy.exposeEmails = $0; save() }))
                    .disabled(!policy.enabled)
                Text("Herramientas de solo lectura: list_meetings, get_meeting, get_transcript, get_participants, search_meetings, get_decisions, get_action_items, compare_meetings. Nunca se exponen audio ni perfiles de voz.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                Text("Ten en cuenta que el cliente (Claude Code, Codex…) enviará lo que consulte a su modelo en la nube.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.warning)
            }
            Section("Configurar clientes") {
                commandRow("Claude Code", "claude mcp add --scope user meeting-intelligence -- \"\(serverPath)\"")
                commandRow("Codex", "codex mcp add meeting-intelligence -- \"\(serverPath)\"")
                Text("Transporte stdio. Protocolos MCP 2026-07-28 y 2025-11-25/06-18/03-26.")
                    .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
            }
        }
        .onAppear { policy = MCPAccessPolicy.load(from: env.paths) }
    }

    private func commandRow(_ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title).font(DS.Font.captionEmphasis)
            HStack {
                Text(command).font(DS.Font.mono).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
        }
    }

    private func save() {
        policy.updatedAt = Date()
        try? policy.save(to: env.paths)
    }
}
