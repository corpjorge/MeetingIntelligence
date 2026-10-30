import MeetingCore
import AVKit
import SwiftUI

struct ChatMessage: Identifiable {
    var id = UUID().uuidString
    let question: String
    var answer: MeetingChatService.Answer?
    var isLoading = true
    var aiError: String?
}

/// Question answering over one meeting or many (local retrieval + optional AI).
/// Finished questions are stored in the library database, per thread.
struct ChatPanel: View {
    let scope: SearchScope
    let thread: ChatThread
    var onOpen: (String, Double) -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var useAI = true
    @State private var confirmClear = false
    @State private var historyError: String?
    @State private var historyGeneration = 0

    var body: some View {
        VStack(spacing: DS.Space.none) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        if messages.isEmpty {
                            EmptyStateView(systemImage: "bubble.left.and.text.bubble.right", title: "Pregunta sobre tus reuniones",
                                           message: (env.settings.semanticSearch ? "La búsqueda es local, por palabras y por significado." : "La búsqueda es local, por palabras (FTS5).")
                                               + " Si activas la IA, solo se le envían los extractos encontrados y debe citarlos.")
                        }
                        ForEach(messages) { message in
                            messageView(message).id(message.id)
                        }
                    }
                    .padding(DS.Space.xxl)
                    .frame(maxWidth: DS.Layout.chatMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                // Start of the newest message: its question stays in view above a long answer.
                .onChange(of: messages.count) { if let last = messages.last { proxy.scrollTo(last.id, anchor: .top) } }
            }
            if let historyError {
                InlineBanner(tone: .warning, systemImage: "exclamationmark.triangle", title: historyError)
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.bottom, DS.Space.s)
            }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.m) {
                    Toggle(isOn: $useAI) { Label("IA", systemImage: "sparkles") }
                        .toggleStyle(.switch).controlSize(.small)
                        .help("Desactívalo para ver solo los resultados de la búsqueda local")
                        .fixedSize()
                    if useAI {
                        AIProviderControls(showsEffort: false)
                    } else {
                        Text("Solo búsqueda local · no se envía a ninguna IA")
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                    }
                    Spacer(minLength: DS.Space.none)
                }
                HStack(spacing: DS.Space.m) {
                    ZStack(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Ej.: ¿Qué compromisos asumió Carlos?")
                                .font(DS.Font.body).foregroundStyle(DS.Color.textTertiary)
                                .padding(.top, DS.Space.xs)
                                .padding(.leading, DS.Space.xs)
                                .allowsHitTesting(false)
                        }
                        ChatTextInput(text: $draft, onSubmit: send)
                    }
                    .frame(height: DS.Layout.editorMinHeight)
                    .help("Enter para enviar · Mayús + Enter para una nueva línea. Corrección ortográfica de macOS activada.")
                    Button("Preguntar", action: send).buttonStyle(.dsPrimary)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                    IconButton(systemImage: "trash", help: "Borrar el historial de este chat") { confirmClear = true }
                        .disabled(messages.isEmpty || messages.contains(where: \.isLoading))
                }
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.m)
            .background(DS.Color.surface)
            .overlay(alignment: .top) { Rectangle().fill(DS.Color.border).frame(height: DS.Layout.hairline) }
        }
        .remoteConsentSheet(env.ai)
        .confirmationDialog("¿Borrar el historial de este chat?", isPresented: $confirmClear) {
            Button("Borrar historial", role: .destructive, action: clearHistory)
        } message: {
            Text("Se eliminan las preguntas y respuestas guardadas. Las reuniones no cambian.")
        }
        .task(id: thread) { loadHistory() }
        .task { if env.ai.statuses.isEmpty { await env.ai.refreshStatuses() } }
    }

    private func loadHistory() {
        do {
            messages = try env.database.chatHistory(thread).map {
                ChatMessage(id: $0.id, question: $0.question, answer: $0.answer, isLoading: false)
            }
            historyError = nil
        } catch {
            messages = []
            historyError = "No se pudo cargar el historial: \(error.localizedDescription)"
        }
    }

    private func clearHistory() {
        do {
            try env.database.clearChatHistory(thread)
            historyGeneration += 1
            messages = []
            historyError = nil
        } catch {
            historyError = "No se pudo borrar el historial: \(error.localizedDescription)"
        }
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.count >= 3 else { return }
        draft = ""
        let message = ChatMessage(question: question)
        messages.append(message)
        let scope = scope, thread = thread, useAI = useAI, generation = historyGeneration
        // Freeze the visible selection before the asynchronous semantic lookup.
        let configuration = env.ai.configuration(for: env.ai.selectedProvider)
        Task {
            let semantic = await env.semantic.query(for: question)
            let reply = await env.ai.reply(question: question, scope: scope, useAI: useAI, semantic: semantic,
                                           configuration: configuration)
            guard generation == historyGeneration else { return }
            if let i = messages.firstIndex(where: { $0.id == message.id }) {
                messages[i].answer = reply.answer
                messages[i].aiError = reply.aiError
                messages[i].isLoading = false
            }
            let scopeIds: [String]? = if case .meetings(let ids) = scope { ids } else { nil }
            do {
                try env.database.appendChatMessage(
                    ChatHistoryMessage(id: message.id, question: question, answer: reply.answer, scopeMeetingIds: scopeIds),
                    thread: thread)
            } catch {
                historyError = "La respuesta no se guardó en el historial: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Spacer()
                Text(message.question).font(DS.Font.body)
                    .textSelection(.enabled)
                    .padding(DS.Space.m)
                    .background(DS.Color.accentSoft, in: RoundedRectangle(cornerRadius: DS.Radius.m))
            }
            if message.isLoading {
                HStack { ProgressView().controlSize(.small); Text("Buscando…").font(DS.Font.callout) }
            } else if message.answer == nil {
                Label("No se pudo completar la búsqueda local.", systemImage: "exclamationmark.triangle")
                    .font(DS.Font.callout).foregroundStyle(DS.Color.warning)
            } else if let answer = message.answer {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    if let aiError = message.aiError {
                        InlineBanner(tone: .warning, systemImage: "exclamationmark.triangle",
                                     title: "La IA no respondió; se muestran los resultados de la búsqueda local",
                                     message: aiError)
                    }
                    if let text = answer.text {
                        HStack(spacing: DS.Space.s) {
                            StatusPill(text: "Respuesta de IA", tone: .ai, systemImage: "sparkles")
                            if let provider = answer.provider {
                                Text("\(provider.displayName)\(answer.model.map { " · \($0)" } ?? "")")
                                    .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                            }
                        }
                        Text(Self.formatted(text)).font(DS.Font.reading).textSelection(.enabled)
                        if !answer.citations.isEmpty {
                            Text("Fuentes").font(DS.Font.captionEmphasis).foregroundStyle(DS.Color.textSecondary)
                            ForEach(answer.citations) { citation($0) }
                        } else if !answer.notFound {
                            Label("La respuesta no citó extractos verificables: trátala como no confirmada.", systemImage: "exclamationmark.triangle")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.warning)
                        }
                    } else if answer.excerpts.isEmpty {
                        Text("No encontré información sobre esto en las reuniones seleccionadas.").font(DS.Font.body)
                    } else {
                        Text("Resultados de búsqueda local (\(answer.excerpts.count))").font(DS.Font.captionEmphasis)
                            .foregroundStyle(DS.Color.textSecondary)
                        ForEach(answer.excerpts.prefix(12)) { citation($0) }
                    }
                }
            }
        }
    }

    /// AI answers use inline Markdown (bold, lists as text). Links are removed: the answer is
    /// derived from untrusted transcript text and must not open URLs.
    static func formatted(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in attributed.runs where run.link != nil { attributed[run.range].link = nil }
        return attributed
    }

    private func citation(_ c: MeetingChatService.Citation) -> some View {
        Button { onOpen(c.meetingId, c.startTime) } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("\(c.reference) · \(c.meetingTitle) · \(Timecode.hms(c.startTime)) · \(c.speakerName)")
                    .font(DS.Font.mono).foregroundStyle(DS.Color.accent)
                Text(c.text).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary).lineLimit(3)
            }
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}

struct MeetingChatTab: View {
    let meetingId: String
    let model: MeetingDetailModel

    var body: some View {
        ChatPanel(scope: .meetings([meetingId]), thread: .meeting(meetingId)) { _, time in model.player.seek(to: time, play: true) }
    }
}

struct AudioTab: View {
    let model: MeetingDetailModel

    static func trackDetail(_ source: AudioSource) -> String {
        switch source {
        case .localMicrophone: "Tu voz"
        case .remoteSystemAudio: "Los demás participantes"
        case .imported: "Archivo de audio"
        }
    }

    var body: some View {
        @Bindable var player = model.player
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                if let error = model.player.loadError {
                    InlineBanner(tone: .warning, systemImage: "speaker.slash", title: "Audio", message: error)
                }
                if let player = model.player.videoPlayer {
                    MeetingVideoView(player: player)
                        .frame(height: DS.Layout.videoPlayerHeight)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m))
                    if let video = model.detail?.video {
                        Text("\(video.applicationName) · \(video.windowTitle)")
                            .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        if video.state == .interrupted {
                            Text("Video recuperado después de una interrupción; puede estar incompleto.")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.warning)
                        }
                    }
                }
                if model.player.isLoaded {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: DS.Space.l) {
                            Text(Timecode.compact(model.player.currentTime)).font(DS.Font.timer)
                        }
                    }
                }
                if let pauses = model.detail?.pauses, !pauses.isEmpty {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Label("Micrófono en pausa", systemImage: "mic.slash").font(DS.Font.headline)
                            ForEach(pauses) { pause in
                                Button { model.player.seek(to: pause.startTime) } label: {
                                    Text("\(Timecode.hms(pause.startTime)) – \(Timecode.hms(pause.endTime)) · \(Timecode.humanDuration(pause.endTime - pause.startTime))")
                                        .font(DS.Font.mono).foregroundStyle(DS.Color.accent)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("Durante estas pausas se grabó silencio en tu micrófono para mantener la sincronía; el audio remoto siguió grabándose.")
                                .font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                        }
                    }
                }
                SectionHeader(title: "Pistas", subtitle: "Las pistas se graban por separado y sincronizadas")
                ForEach(model.detail?.tracks ?? []) { track in
                    SurfaceCard {
                        HStack(alignment: .top, spacing: DS.Space.m) {
                            Image(systemName: track.source == .localMicrophone ? "mic.fill" : (track.source == .remoteSystemAudio ? "person.3.fill" : "doc.fill"))
                                .frame(width: DS.Size.iconTileSmall, height: DS.Size.iconTileSmall)
                                .background(DS.Color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.s))
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                HStack(spacing: DS.Space.s) {
                                    Text(track.source == .localMicrophone ? "Micrófono local" : (track.source == .remoteSystemAudio ? "Audio remoto" : "Audio importado"))
                                        .font(DS.Font.bodyEmphasis)
                                    Text(Self.trackDetail(track.source)).font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                                }
                                Text(track.captureDetail ?? "").font(DS.Font.caption).foregroundStyle(DS.Color.textSecondary)
                                HStack(spacing: DS.Space.m) {
                                    Text(Timecode.humanDuration(track.durationSeconds))
                                    Text("\(Int(track.sampleRate)) Hz · \(track.channelCount) canal(es)")
                                    Text(ByteCountFormatter.string(fromByteCount: track.fileSizeBytes, countStyle: .file))
                                    if let device = track.deviceName { Text(device) }
                                }
                                .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                            }
                            Spacer()
                            if model.player.availableSources.contains(track.source) {
                                Toggle("Silenciar", isOn: Binding(
                                    get: { player.mutedSources.contains(track.source) },
                                    set: { if $0 { player.mutedSources.insert(track.source) } else { player.mutedSources.remove(track.source) } }))
                                    .toggleStyle(.switch).controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(DS.Space.xxl)
            .frame(maxWidth: DS.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
