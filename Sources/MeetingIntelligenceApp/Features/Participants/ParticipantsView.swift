import AppKit
import GRDB
import MeetingAudio
import MeetingCore
import MeetingSpeech
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ParticipantsModel {
    var participants: [Participant] = []
    var profiles: [String: SpeakerProfile] = [:]
    var sampleCounts: [String: Int] = [:]
    var meetingCounts: [String: Int] = [:]
    var loaded = false

    func observe(_ db: AppDatabase) async {
        let observation = ValueObservation.tracking { db -> ([Participant], [SpeakerProfile], [String: Int], [String: Int]) in
            let participants = try Participant.order(Column("displayName").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
            let profiles = try SpeakerProfile.fetchAll(db)
            let samples = try Row.fetchAll(db, sql: "SELECT profileId, COUNT(*) AS n FROM voiceSample GROUP BY profileId")
                .reduce(into: [String: Int]()) { $0[$1["profileId"]] = $1["n"] }
            let meetings = try Row.fetchAll(db, sql: """
                SELECT participantId, COUNT(DISTINCT meetingId) AS n FROM transcriptSegment
                WHERE participantId IS NOT NULL GROUP BY participantId
                """).reduce(into: [String: Int]()) { $0[$1["participantId"]] = $1["n"] }
            return (participants, profiles, samples, meetings)
        }
        do {
            for try await (participants, profiles, samples, meetings) in observation.values(in: db.reader) {
                self.participants = participants
                self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.participantId, $0) })
                self.sampleCounts = samples
                self.meetingCounts = meetings
                loaded = true
            }
        } catch {}
    }
}

struct ParticipantsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = ParticipantsModel()
    @State private var selection: String?
    @State private var showNew = false
    @State private var calibration: SpeakerCalibration?
    @State private var calibrationLoaded = false

    var body: some View {
        // Plain HStack, not HSplitView: a nested NSSplitView inside the
        // NavigationSplitView detail shifts the app sidebar and adds a titlebar band.
        HStack(spacing: 0) {
            list.frame(width: DS.Layout.listColumnWidth)
            Rectangle().fill(DS.Color.border).frame(width: DS.Layout.hairline)
            Group {
                if let id = selection, let participant = model.participants.first(where: { $0.id == id }) {
                    ParticipantDetailView(participant: participant, profile: model.profiles[id],
                                          sampleCount: model.profiles[id].flatMap { model.sampleCounts[$0.id] } ?? 0,
                                          others: model.participants.filter { $0.id != id },
                                          onDeleted: { selection = nil })
                        .id(id)
                } else {
                    EmptyStateView(systemImage: "person.crop.circle", title: "Selecciona un participante",
                                   message: "Gestiona nombres, perfiles de voz autorizados y el historial de reuniones.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.Color.background)
        }
        .task { await model.observe(env.database) }
        .task(id: model.sampleCounts) {
            calibration = try? await env.recognizer.calibration()
            calibrationLoaded = true
        }
        .sheet(isPresented: $showNew) {
            NewParticipantSheet { name in
                let p = Participant(displayName: name)
                try? env.database.save(participant: p)
                selection = p.id
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Participantes").font(DS.Font.title)
                Spacer()
                IconButton(systemImage: "plus", help: "Nuevo participante") { showNew = true }
            }
            .padding(DS.Space.l)
            calibrationCard.padding(.horizontal, DS.Space.l).padding(.bottom, DS.Space.m)
            if model.loaded && model.participants.isEmpty {
                EmptyStateView(systemImage: "person.2", title: "Sin participantes",
                               message: "Crea participantes o asígnalos desde la pestaña Participantes de una reunión.")
            }
            List(selection: $selection) {
                ForEach(model.participants) { p in
                    HStack(spacing: DS.Space.m) {
                        SpeakerAvatar(name: p.displayName, colorIndex: StableHash.index(p.id))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: DS.Space.xs) {
                                Text(p.displayName).font(DS.Font.bodyEmphasis)
                                if p.isLocalUser { StatusPill(text: "Yo", tone: .accent) }
                            }
                            Text("\(model.meetingCounts[p.id] ?? 0) reuniones")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                        }
                        Spacer()
                        if let profile = model.profiles[p.id] {
                            Image(systemName: profile.status == .active ? "waveform.badge.checkmark" : "waveform.slash")
                                .foregroundStyle(profile.status == .active ? DS.Color.success : DS.Color.textTertiary)
                                .help(profile.status == .active ? "Perfil de voz activo" : "Consentimiento revocado")
                        }
                    }
                    .padding(.vertical, DS.Space.xxs)
                    .tag(p.id)
                }
            }
            .listStyle(.inset)
        }
        .background(DS.Color.surface)
    }

    @ViewBuilder
    private var calibrationCard: some View {
        if calibrationLoaded {
            if let calibration {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Label("Reconocimiento calibrado", systemImage: "checkmark.shield").font(DS.Font.captionEmphasis)
                        .foregroundStyle(calibration.hasOverlap ? DS.Color.warning : DS.Color.success)
                    Text("Umbral \(String(format: "%.2f", calibration.acceptThreshold)) · margen \(String(format: "%.2f", calibration.requiredMargin)) · \(calibration.genuineCount) pares propios / \(calibration.impostorCount) ajenos")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    if calibration.hasOverlap {
                        Text("Algunas voces se parecen: habrá más sugerencias que asignaciones automáticas.")
                            .font(DS.Font.caption).foregroundStyle(DS.Color.warning)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Label("Sin calibrar: solo sugerencias", systemImage: "shield").font(DS.Font.captionEmphasis)
                        .foregroundStyle(DS.Color.textSecondary)
                    Text("Se necesitan al menos 2 personas con 2 muestras autorizadas cada una para asignar identidades automáticamente.")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                }
            }
        }
    }
}

struct ParticipantDetailView: View {
    let participant: Participant
    let profile: SpeakerProfile?
    let sampleCount: Int
    let others: [Participant]
    let onDeleted: () -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var draft: Participant
    @State private var samples: [VoiceSample] = []
    @State private var meetings: [Meeting] = []
    @State private var showEnroll = false
    @State private var message: (tone: Tone, text: String)?

    init(participant: Participant, profile: SpeakerProfile?, sampleCount: Int, others: [Participant], onDeleted: @escaping () -> Void) {
        self.participant = participant
        self.profile = profile
        self.sampleCount = sampleCount
        self.others = others
        self.onDeleted = onDeleted
        _draft = State(initialValue: participant)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                HStack(spacing: DS.Space.l) {
                    SpeakerAvatar(name: participant.displayName, colorIndex: StableHash.index(participant.id), size: 52)
                    VStack(alignment: .leading) {
                        Text(participant.displayName).font(DS.Font.display)
                        Text(participant.isLocalUser ? "Usuario local (micrófono de este Mac)" : "Participante")
                            .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    }
                    Spacer()
                    Menu {
                        if !others.isEmpty {
                            Section("Fusionar duplicado en…") {
                                ForEach(others) { other in
                                    Button(other.displayName) { merge(into: other) }
                                }
                            }
                        }
                        Divider()
                        Button("Eliminar participante…", role: .destructive) { confirmDelete() }
                    } label: { Label("Acciones", systemImage: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if let message {
                    InlineBanner(tone: message.tone, systemImage: "info.circle", title: message.text) {
                        IconButton(systemImage: "xmark", help: "Cerrar") { self.message = nil }
                    }
                }
                infoCard
                profileCard
                historyCard
            }
            .padding(DS.Space.xxl)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .task(id: sampleCount) { load() }
        .sheet(isPresented: $showEnroll) {
            EnrollmentSheet(participant: participant, existingProfile: profile) { result in message = result }
        }
    }

    private func load() {
        if let profile { samples = (try? env.database.samples(profileId: profile.id)) ?? [] } else { samples = [] }
        meetings = (try? env.database.reader.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT DISTINCT m.* FROM meeting m JOIN transcriptSegment s ON s.meetingId = m.id
                WHERE s.participantId = ? ORDER BY m.createdAt DESC
                """, arguments: [participant.id])
        }) ?? []
    }

    private var infoCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Datos").font(DS.Font.headline)
                TextField("Nombre", text: $draft.displayName).textFieldStyle(.roundedBorder)
                TextField("Correo (opcional)", text: Binding(get: { draft.email ?? "" }, set: { draft.email = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField("Rol (opcional)", text: Binding(get: { draft.role ?? "" }, set: { draft.role = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                Toggle("Soy yo (usuario local del micrófono)", isOn: $draft.isLocalUser)
                HStack {
                    Spacer()
                    Button("Guardar cambios") {
                        try? env.database.save(participant: draft)
                        if draft.isLocalUser { env.settings.localUserName = draft.displayName }
                        message = (.success, "Cambios guardados.")
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(draft == participant || draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var profileCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack {
                    Text("Perfil de voz").font(DS.Font.headline)
                    if let profile {
                        StatusPill(text: profile.status == .active ? "Activo" : "Revocado",
                                   tone: profile.status == .active ? .success : .neutral)
                    }
                    Spacer()
                    Button { showEnroll = true } label: {
                        Label(profile?.status == .active ? "Añadir muestra" : "Registrar voz", systemImage: "waveform.badge.plus")
                    }
                    .buttonStyle(.dsSecondary)
                }
                if let profile {
                    KeyValueRow(key: "Consentimiento", value: profile.consentStatement)
                    KeyValueRow(key: "Registrado", value: profile.consentRecordedAt.formatted(date: .abbreviated, time: .shortened))
                    KeyValueRow(key: "Conservación", value: profile.retentionDays.map { "\($0) días sin uso" } ?? "Hasta que se elimine")
                    if let last = profile.lastMatchedAt {
                        KeyValueRow(key: "Último reconocimiento", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    Divider()
                    Text("Muestras (\(samples.count))").font(DS.Font.captionEmphasis).foregroundStyle(DS.Color.textSecondary)
                    ForEach(samples) { sample in
                        HStack {
                            Image(systemName: sample.origin == .enrollment ? "mic" : "text.bubble").foregroundStyle(DS.Color.textTertiary)
                            Text(sample.origin == .enrollment ? "Grabación de registro" : "Validada desde una reunión").font(DS.Font.callout)
                            Text("\(String(format: "%.0f", sample.durationSeconds)) s · \(sample.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                            Spacer()
                            IconButton(systemImage: "trash", help: "Eliminar muestra") {
                                try? env.database.deleteSample(id: sample.id)
                                load()
                            }
                        }
                    }
                    HStack {
                        if profile.status == .active {
                            Button("Revocar consentimiento") { revoke() }.buttonStyle(.dsSecondary)
                        }
                        Button("Eliminar perfil de voz") { deleteProfile() }.buttonStyle(.dsDestructive)
                    }
                    Text("Las huellas de voz se cifran con AES-GCM (clave en el Llavero), nunca se exportan, no se envían a proveedores de IA ni se exponen por MCP.")
                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                } else {
                    Text("Sin perfil biométrico. Para reconocer a esta persona en reuniones futuras, registra muestras de voz con su autorización.")
                        .font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
            }
        }
    }

    private var historyCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Reuniones (\(meetings.count))").font(DS.Font.headline)
                if meetings.isEmpty {
                    Text("Aún no aparece en ninguna transcripción.").font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                }
                ForEach(meetings) { meeting in
                    Button { router.openMeeting(meeting.id) } label: {
                        HStack {
                            Text(meeting.title).font(DS.Font.callout)
                            Spacer()
                            Text(meeting.displayDate.formatted(date: .abbreviated, time: .omitted)).font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                let merges = (try? env.database.participantMergeEvents()) ?? []
                if let merge = merges.first(where: { $0.newValue == participant.id }) {
                    Divider()
                    HStack {
                        Text("Incluye a un participante fusionado el \(merge.createdAt.formatted(date: .abbreviated, time: .shortened)).")
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        Spacer()
                        Button("Separar") {
                            try? env.database.undoParticipantMerge(eventId: merge.id)
                            message = (.success, "Participante separado. Las muestras de voz fusionadas permanecen en este perfil.")
                        }
                        .buttonStyle(.ds(.secondary, size: .small))
                    }
                }
            }
        }
    }

    @Environment(AppRouter.self) private var router

    private func merge(into other: Participant) {
        let alert = NSAlert()
        alert.messageText = "¿Fusionar “\(participant.displayName)” en “\(other.displayName)”?"
        alert.informativeText = "Todas sus intervenciones, asignaciones y muestras de voz pasarán a \(other.displayName). Podrás separarlos después."
        alert.addButton(withTitle: "Fusionar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try env.database.mergeParticipants(participant.id, into: other.id)
            onDeleted()
        } catch {
            message = (.danger, error.localizedDescription)
        }
    }

    private func revoke() {
        try? env.database.revokeProfile(participantId: participant.id)
        message = (.success, "Consentimiento revocado: se eliminaron las huellas de voz.")
        load()
    }

    private func deleteProfile() {
        let alert = NSAlert()
        alert.messageText = "¿Eliminar el perfil de voz?"
        alert.informativeText = "Se borrarán todas las muestras y huellas de voz de \(participant.displayName). Las transcripciones no cambian."
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? env.database.deleteProfile(participantId: participant.id)
        load()
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "¿Eliminar a \(participant.displayName)?"
        alert.informativeText = "Sus intervenciones pasarán a “Participante desconocido” y se borrará su perfil de voz."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? env.database.deleteParticipant(id: participant.id)
        onDeleted()
    }
}

/// Consent-first voice enrollment: record with the microphone or import a file.
struct EnrollmentSheet: View {
    let participant: Participant
    let existingProfile: SpeakerProfile?
    let onFinish: ((tone: Tone, text: String)) -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var consent = false
    @State private var statement = ""
    @State private var retentionDays: Int?
    @State private var phase: Phase = .idle
    @State private var session: RecordingSession?
    @State private var elapsed: Double = 0
    @State private var level = AudioLevel.silence
    @State private var showImporter = false

    enum Phase: Equatable { case idle, recording, processing, failed(String) }

    static let readingText = """
    Hoy revisamos el estado del proyecto. El equipo de backend terminó el servicio de viabilidad inicial y \
    expuso el indicador de ingresos validados en el response del endpoint. Para la próxima semana debemos \
    validar los campos con el área de riesgo, actualizar la documentación del API y coordinar el despliegue en \
    Kubernetes. Si surge algún bloqueo, lo escalamos en la reunión del viernes.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Registrar voz de \(participant.displayName)").font(DS.Font.title)
            InlineBanner(tone: .info, systemImage: "hand.raised",
                         title: "Requiere autorización explícita",
                         message: "La huella de voz es un dato biométrico. Se guarda cifrada solo en este Mac y puede revocarse o eliminarse en cualquier momento.")
            Toggle(isOn: $consent) {
                Text("\(participant.displayName) autorizó expresamente el registro de su voz para identificarle en reuniones.")
                    .font(DS.Font.callout)
            }
            .toggleStyle(.checkbox)
            TextField("Detalle del consentimiento (cómo y cuándo se otorgó)", text: $statement).textFieldStyle(.roundedBorder)
            Picker("Conservación", selection: $retentionDays) {
                Text("Hasta que se elimine").tag(Int?.none)
                Text("90 días sin uso").tag(Int?.some(90))
                Text("180 días sin uso").tag(Int?.some(180))
                Text("365 días sin uso").tag(Int?.some(365))
            }
            Divider()
            switch phase {
            case .idle, .failed:
                Text("Pide a la persona que lea en voz alta (solo ella debe hablar, ~25 s):").font(DS.Font.callout)
                Text(Self.readingText).font(DS.Font.reading).padding(DS.Space.m)
                    .background(DS.Color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.m))
                if case .failed(let error) = phase {
                    InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill", title: error)
                }
            case .recording:
                HStack(spacing: DS.Space.m) {
                    RecordingDot()
                    Text(Timecode.compact(elapsed)).font(DS.Font.metric)
                    LevelMeterView(level: level.normalized)
                }
            case .processing:
                LoadingStateView(message: "Extrayendo la huella de voz localmente…")
            }
            HStack {
                Button("Importar archivo…") { showImporter = true }.buttonStyle(.dsGhost).disabled(!canStart)
                Spacer()
                Button("Cancelar") { cancel() }.buttonStyle(.dsSecondary)
                if phase == .recording {
                    Button("Terminar") { finishRecording() }.buttonStyle(.dsPrimary).disabled(elapsed < 10)
                } else {
                    Button("Grabar muestra") { startRecording() }.buttonStyle(.ds(.recording)).disabled(!canStart)
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 560)
        .onAppear { statement = existingProfile?.consentStatement ?? "Autorización verbal otorgada el \(Date().formatted(date: .long, time: .omitted))" }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { enroll(url: url, temporary: false) }
        }
    }

    private var canStart: Bool {
        consent && !statement.trimmingCharacters(in: .whitespaces).isEmpty && (phase == .idle || isFailed)
    }
    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    private func startRecording() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mi-enroll-\(UUID().uuidString)")
        Task {
            if !RecordingSession.microphonePermissionGranted() {
                guard await RecordingSession.requestMicrophonePermission() else {
                    phase = .failed(CaptureError.microphonePermissionDenied.localizedDescription); return
                }
            }
            let session = RecordingSession(configuration: RecordingConfiguration(directory: dir, remoteTarget: .none))
            do {
                try session.start()
                self.session = session
                phase = .recording
                Task {
                    for await event in session.events {
                        if case .level(_, let l) = event { level = l }
                    }
                }
                while phase == .recording {
                    elapsed = session.elapsed
                    try? await Task.sleep(for: .milliseconds(200))
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func finishRecording() {
        guard let session else { return }
        let result = session.stop()
        self.session = nil
        guard let url = result.tracks.first?.url else { phase = .failed("No se grabó audio."); return }
        enroll(url: url, temporary: true)
    }

    private func enroll(url: URL, temporary: Bool) {
        phase = .processing
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
                if temporary { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
            do {
                try await env.recognizer.enroll(participantId: participant.id, audioURL: url,
                                                consentStatement: statement, retentionDays: retentionDays)
                onFinish((.success, "Muestra de voz registrada para \(participant.displayName)."))
                dismiss()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        if let session {
            let result = session.stop()
            if let dir = result.tracks.first?.url.deletingLastPathComponent() { try? FileManager.default.removeItem(at: dir) }
        }
        dismiss()
    }
}
