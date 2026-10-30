import AppKit
import MeetingCore
import MeetingSpeech
import SwiftUI

/// Identity management for the diarized speakers of one meeting.
struct SpeakersTab: View {
    let model: MeetingDetailModel
    let meetingId: String
    @Environment(AppEnvironment.self) private var env
    @State private var newParticipantFor: MeetingSpeaker?
    @State private var message: (tone: Tone, text: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                InlineBanner(tone: .info, systemImage: "person.badge.shield.checkmark",
                             title: "Las identidades nunca se inventan",
                             message: "Un nombre solo aparece si lo asignas tú o si un perfil de voz autorizado supera el umbral calibrado. Los demás hablantes se muestran como desconocidos.")
                if let message {
                    InlineBanner(tone: message.tone, systemImage: "info.circle", title: message.text) {
                        IconButton(systemImage: "xmark", help: "Cerrar") { self.message = nil }
                    }
                }
                if let detail = model.detail, !detail.speakers.isEmpty {
                    ForEach(detail.speakers) { speaker in
                        speakerCard(speaker, detail: detail)
                    }
                } else {
                    EmptyStateView(systemImage: "person.2.slash", title: "Sin hablantes todavía",
                                   message: "La diarización identifica las intervenciones al procesar la reunión.")
                }
            }
            .padding(DS.Space.xxl)
            .frame(maxWidth: DS.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $newParticipantFor) { speaker in
            NewParticipantSheet { name in
                let participant = Participant(displayName: name)
                try? env.database.save(participant: participant)
                try? env.database.assignSpeaker(meetingSpeakerId: speaker.id, participantId: participant.id)
            }
        }
    }

    private func speakerCard(_ speaker: MeetingSpeaker, detail: MeetingDetail) -> some View {
        let participant = speaker.participantId.flatMap { pid in model.allParticipants.first { $0.id == pid } }
        let history = model.assignments.filter { $0.meetingSpeakerId == speaker.id }
        let latest = history.first { $0.supersededAt == nil }
        let index = detail.speakers.firstIndex(where: { $0.id == speaker.id })
        let segmentCount = detail.segments.filter { $0.meetingSpeakerId == speaker.id }.count
        let otherSpeakers = detail.speakers.filter { $0.id != speaker.id && $0.source == speaker.source }

        return SurfaceCard {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    SpeakerAvatar(name: participant?.displayName ?? speaker.defaultLabel,
                                  colorIndex: participant.map { StableHash.index($0.id) } ?? index, size: DS.Size.avatarMedium,
                                  isUnknown: participant == nil)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        HStack(spacing: DS.Space.s) {
                            Text(participant?.displayName ?? "Participante desconocido").font(DS.Font.headline)
                            Text(speaker.defaultLabel).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                        }
                        Text("\(speaker.source == .localMicrophone ? "Micrófono local" : (speaker.source == .remoteSystemAudio ? "Audio remoto" : "Audio importado")) · \(Timecode.humanDuration(speaker.totalSpeechSeconds)) de voz · \(segmentCount) intervenciones")
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    }
                    Spacer()
                    identityMenu(speaker, others: otherSpeakers)
                }

                if let latest {
                    decisionView(latest, speaker: speaker)
                }

                if history.count > 1 {
                    DisclosureGroup("Historial de identificación (\(history.count))") {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            ForEach(history) { entry in
                                HStack(spacing: DS.Space.s) {
                                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(DS.Font.mono).foregroundStyle(DS.Color.textTertiary)
                                    Text(describe(entry)).font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                                    if entry.supersededAt != nil { Text("(reemplazado)").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary) }
                                }
                            }
                        }
                        .padding(.top, DS.Space.xs)
                    }
                    .font(DS.Font.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func decisionView(_ entry: SpeakerAssignment, speaker: MeetingSpeaker) -> some View {
        let candidate = entry.participantId.flatMap { pid in model.allParticipants.first { $0.id == pid } }
        switch entry.decision {
        case .suggested:
            InlineBanner(tone: .warning, systemImage: "questionmark.circle",
                         title: "¿Es \(candidate?.displayName ?? "esta persona")? (sugerencia, no aplicada)",
                         message: scoreText(entry)) {
                HStack {
                    Button("Confirmar") {
                        if let pid = entry.participantId { try? env.database.assignSpeaker(meetingSpeakerId: speaker.id, participantId: pid) }
                    }
                    .buttonStyle(.ds(.primary, size: .small))
                    Button("No es") { try? env.database.assignSpeaker(meetingSpeakerId: speaker.id, participantId: nil) }
                        .buttonStyle(.ds(.secondary, size: .small))
                }
            }
        case .accepted where entry.method == .automaticRecognition:
            Label("Reconocido automáticamente · \(scoreText(entry))", systemImage: "checkmark.seal")
                .font(DS.Font.caption).foregroundStyle(DS.Color.success)
        case .accepted where entry.method == .localUserTrack:
            Label(entry.note ?? "Pista del micrófono asignada al usuario local", systemImage: "mic")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
        case .unknown where entry.method == .automaticRecognition:
            Label("Sin coincidencia suficiente con perfiles registrados · \(entry.note ?? "")", systemImage: "person.fill.questionmark")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
        default:
            EmptyView()
        }
    }

    private func identityMenu(_ speaker: MeetingSpeaker, others: [MeetingSpeaker]) -> some View {
        Menu {
            Section("Asignar a") {
                ForEach(model.allParticipants) { p in
                    Button(p.displayName + (p.isLocalUser ? " (yo)" : "")) {
                        try? env.database.assignSpeaker(meetingSpeakerId: speaker.id, participantId: p.id)
                    }
                }
                Button("Nuevo participante…") { newParticipantFor = speaker }
            }
            if speaker.participantId != nil {
                Button("Marcar como desconocido") { try? env.database.assignSpeaker(meetingSpeakerId: speaker.id, participantId: nil) }
            }
            if !others.isEmpty {
                Section("Es la misma persona que") {
                    ForEach(others) { other in
                        Button("Fusionar en \(name(of: other))") { try? env.database.mergeSpeakers(speaker.id, into: other.id) }
                    }
                }
            }
            Button("Separar (restaurar intervenciones originales)") { try? env.database.splitSpeaker(speaker.id) }
            if let pid = speaker.participantId, speaker.embeddingCiphertext != nil {
                Divider()
                Button("Usar como muestra de voz validada") { addSample(speaker, participantId: pid) }
            }
        } label: {
            Label("Identidad", systemImage: "person.crop.circle.badge.checkmark")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func name(of speaker: MeetingSpeaker) -> String {
        speaker.participantId.flatMap { pid in model.allParticipants.first { $0.id == pid }?.displayName } ?? speaker.defaultLabel
    }

    private func addSample(_ speaker: MeetingSpeaker, participantId: String) {
        Task {
            do {
                try await env.recognizer.addValidatedSample(meetingSpeakerId: speaker.id, participantId: participantId)
                message = (.success, "Muestra de voz añadida al perfil.")
            } catch EnrollmentError.consentRequired {
                message = (.warning, "Esta persona no tiene un perfil de voz con consentimiento. Créalo en Participantes antes de añadir muestras.")
            } catch {
                message = (.danger, error.localizedDescription)
            }
        }
    }

    private func scoreText(_ entry: SpeakerAssignment) -> String {
        var parts: [String] = []
        if let s = entry.similarity { parts.append("similitud \(String(format: "%.2f", s))") }
        if let t = entry.threshold { parts.append("umbral \(String(format: "%.2f", t))") }
        if let m = entry.margin { parts.append("margen \(String(format: "%.2f", m))") }
        if let note = entry.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private func describe(_ entry: SpeakerAssignment) -> String {
        let who = entry.participantId.flatMap { pid in model.allParticipants.first { $0.id == pid }?.displayName } ?? "desconocido"
        let method: String = switch entry.method {
        case .automaticRecognition: "Reconocimiento"
        case .manual: "Manual"
        case .localUserTrack: "Pista local"
        case .merge: "Fusión"
        case .split: "Separación"
        }
        return "\(method): \(Self.decisionLabel(entry.decision)) → \(who)"
    }

    static func decisionLabel(_ decision: AssignmentDecision) -> String {
        switch decision {
        case .accepted: "aceptada"
        case .suggested: "sugerida"
        case .rejected: "rechazada"
        case .unknown: "sin coincidencia"
        }
    }
}

struct NewParticipantSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Nuevo participante").font(DS.Font.title)
            TextField("Nombre", text: $name).textFieldStyle(.roundedBorder)
            Text("Asignar un nombre no crea un perfil biométrico. Los perfiles de voz requieren consentimiento explícito.")
                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(.dsSecondary).keyboardShortcut(.cancelAction)
                Button("Crear y asignar") { onCreate(name.trimmingCharacters(in: .whitespaces)); dismiss() }
                    .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Layout.Sheet.s)
    }
}
