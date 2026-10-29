import AppKit
import GRDB
import MeetingCore
import MeetingMedia
import SwiftUI
import UniformTypeIdentifiers

enum MeetingDetailTab: String, CaseIterable, Identifiable, Hashable {
    case summary, transcript, participants, decisions, tasks, chat, audio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .summary: "Resumen"
        case .transcript: "Transcripción"
        case .participants: "Participantes"
        case .decisions: "Decisiones"
        case .tasks: "Tareas"
        case .chat: "Chat"
        case .audio: "Grabación"
        }
    }
    var icon: String {
        switch self {
        case .summary: "text.alignleft"
        case .transcript: "text.bubble"
        case .participants: "person.2"
        case .decisions: "checkmark.seal"
        case .tasks: "checklist"
        case .chat: "bubble.left.and.text.bubble.right"
        case .audio: "play.rectangle"
        }
    }
}

@Observable
final class MeetingDetailModel {
    var detail: MeetingDetail?
    var analyses: [AIAnalysis] = []
    var items: [AnalysisItem] = []
    var assignments: [SpeakerAssignment] = []
    var allParticipants: [Participant] = []
    var loaded = false
    let player = MeetingAudioPlayer()

    var latestAnalysis: AIAnalysis? { analyses.first { $0.status == .succeeded } }
    var latestItems: [AnalysisItem] {
        guard let id = latestAnalysis?.id else { return [] }
        return items.filter { $0.analysisId == id }
    }

    /// Stable color slot per speaker (order of appearance across sources).
    func colorIndex(for segment: TranscriptSegment) -> Int? {
        guard let detail else { return nil }
        if let pid = segment.participantId { return StableHash.index(pid) }
        if let sid = segment.meetingSpeakerId, let i = detail.speakers.firstIndex(where: { $0.id == sid }) { return i }
        return nil
    }

    func observe(_ db: AppDatabase, meetingId: String) async {
        let observation = ValueObservation.tracking { db -> (MeetingDetail?, [AIAnalysis], [AnalysisItem], [SpeakerAssignment], [Participant]) in
            (try AppDatabase.fetchDetail(db, id: meetingId),
             try AIAnalysis.filter(Column("meetingId") == meetingId).order(Column("startedAt").desc).fetchAll(db),
             try AnalysisItem.filter(Column("meetingId") == meetingId).order(Column("orderIndex")).fetchAll(db),
             try SpeakerAssignment.filter(Column("meetingId") == meetingId).order(Column("createdAt").desc).fetchAll(db),
             try Participant.order(Column("displayName")).fetchAll(db))
        }
        do {
            for try await (detail, analyses, items, assignments, participants) in observation.values(in: db.reader) {
                self.detail = detail
                self.analyses = analyses
                self.items = items
                self.assignments = assignments
                self.allParticipants = participants
                loaded = true
            }
        } catch {}
    }
}

struct MeetingDetailView: View {
    let meetingId: String
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @State private var model = MeetingDetailModel()
    @State private var tab: MeetingDetailTab = .transcript
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if let detail = model.detail {
                VStack(spacing: DS.Space.none) {
                    header(detail)
                        .padding(.horizontal, DS.Space.xxl)
                        .padding(.top, DS.Space.xl)
                    DSTabBar(tabs: MeetingDetailTab.allCases, selection: $tab, title: \.title, icon: \.icon)
                        .padding(.horizontal, DS.Space.xxl)
                        .padding(.top, DS.Space.l)
                    if env.mediaExport.isExporting {
                        HStack(spacing: DS.Space.m) {
                            ProgressView(value: env.mediaExport.progress)
                                .frame(maxWidth: DS.Layout.Control.progressBarMaxWidth)
                            Text("Exportando…").font(DS.Font.callout)
                            Button("Cancelar") { env.mediaExport.cancel() }.buttonStyle(.dsGhost)
                        }
                        .padding(DS.Space.m)
                    }
                    if let error = env.mediaExport.error {
                        InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle", title: "Exportación", message: error) {
                            IconButton(systemImage: "xmark", help: "Cerrar") { env.mediaExport.error = nil }
                        }
                        .padding(.horizontal, DS.Space.xl)
                    }
                    content(detail)
                    if model.player.isLoaded {
                        PlayerBar(player: model.player)
                    }
                }
            } else if model.loaded {
                EmptyStateView(systemImage: "questionmark.folder", title: "Reunión no encontrada",
                               message: "Es posible que se haya eliminado.")
            } else {
                LoadingStateView(message: "Cargando reunión…")
            }
        }
        .background(DS.Color.background)
        .task(id: meetingId) { await model.observe(env.database, meetingId: meetingId) }
        .task(id: model.detail) {
            if let detail = model.detail { await model.player.load(tracks: detail.tracks, paths: env.paths, video: detail.video) }
        }
        .onAppear {
            if let requested = router.requestedDetailTab { tab = requested; router.requestedDetailTab = nil }
        }
        .onChange(of: router.requestedDetailTab) { _, requested in
            if let requested { tab = requested; router.requestedDetailTab = nil }
        }
        .onDisappear { model.player.pause() }
        .toolbar { toolbar }
    }

    // MARK: Header

    private func header(_ detail: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                if editingTitle {
                    TextField("Título", text: $titleDraft)
                        .textFieldStyle(.plain).font(DS.Font.display)
                        .focused($titleFocused)
                        .onSubmit(commitTitle)
                        .onExitCommand { editingTitle = false }
                        .onChange(of: titleFocused) { _, focused in if !focused && editingTitle { commitTitle() } }
                    IconButton(systemImage: "checkmark", help: "Guardar el nombre", action: commitTitle)
                } else {
                    Text(detail.meeting.title).font(DS.Font.display).foregroundStyle(DS.Color.textPrimary)
                        .onTapGesture(count: 2) { beginEditingTitle(detail.meeting.title) }
                        .help("Doble clic para renombrar")
                    IconButton(systemImage: "pencil", help: "Renombrar la reunión") { beginEditingTitle(detail.meeting.title) }
                }
                Spacer()
                MeetingStatusPill(meeting: detail.meeting, busy: env.processing.isBusy(meetingId))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.m) { metadata(detail) }
                VStack(alignment: .leading, spacing: DS.Space.xs) { metadata(detail) }
            }
            .font(DS.Font.callout)
            .foregroundStyle(DS.Color.textSecondary)
            .labelStyle(.titleAndIcon)

            if let progress = env.processing.progress(for: meetingId) {
                HStack(spacing: DS.Space.m) {
                    if let f = progress.fraction { ProgressView(value: f).frame(maxWidth: DS.Layout.Control.progressBarMaxWidth) } else { ProgressView().controlSize(.small) }
                    Text(progress.message).font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
                    Button("Cancelar") { env.processing.cancel(meetingId) }.buttonStyle(.ds(.ghost, size: .small))
                }
                .padding(.top, DS.Space.xs)
            } else if env.processing.isBusy(meetingId) {
                Label("En cola para procesar", systemImage: "hourglass").font(DS.Font.callout).foregroundStyle(DS.Color.textSecondary)
            } else if let error = detail.meeting.lastError, detail.meeting.status != .ready {
                InlineBanner(tone: detail.meeting.status == .failed ? .danger : .warning,
                             systemImage: "exclamationmark.triangle.fill", title: "Atención", message: error) {
                    Button("Procesar") { env.processing.enqueue(meetingId) }.buttonStyle(.ds(.secondary, size: .small))
                }
            } else if detail.meeting.status == .recorded || detail.meeting.status == .interrupted {
                InlineBanner(tone: .info, systemImage: "waveform", title: "Audio listo para transcribir",
                             message: "Parakeet Ultra transcribirá localmente y la diarización separará a los hablantes.") {
                    Button("Procesar ahora") { env.processing.enqueue(meetingId) }.buttonStyle(.ds(.primary, size: .small))
                }
            }
        }
    }

    @ViewBuilder
    private func metadata(_ detail: MeetingDetail) -> some View {
        Label(detail.meeting.displayDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
            .lineLimit(1).fixedSize()
        Label(Timecode.humanDuration(detail.meeting.durationSeconds), systemImage: "clock").lineLimit(1).fixedSize()
        if !detail.speakers.isEmpty {
            Label("\(detail.speakers.count) hablantes", systemImage: "person.2").lineLimit(1).fixedSize()
        }
        ScopeBadge(meeting: detail.meeting)
        if let transcript = detail.transcripts.first(where: { $0.supersededAt == nil }) {
            Label("Parakeet Ultra · local", systemImage: "cpu").lineLimit(1).fixedSize().help(transcript.modelIdentifier)
        }
    }

    private func beginEditingTitle(_ current: String) {
        titleDraft = current
        editingTitle = true
        titleFocused = true
    }

    /// Empty names are ignored (keeps the previous one); every rename is a `CorrectionEvent`.
    private func commitTitle() {
        editingTitle = false
        do {
            try env.database.renameMeeting(id: meetingId, title: titleDraft)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ detail: MeetingDetail) -> some View {
        switch tab {
        case .summary: SummaryTab(model: model, meetingId: meetingId)
        case .transcript: TranscriptTab(model: model, meetingId: meetingId)
        case .participants: SpeakersTab(model: model, meetingId: meetingId)
        case .decisions: AnalysisItemsTab(model: model, meetingId: meetingId, mode: .decisions)
        case .tasks: AnalysisItemsTab(model: model, meetingId: meetingId, mode: .tasks)
        case .chat: MeetingChatTab(meetingId: meetingId, model: model)
        case .audio: AudioTab(model: model)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                env.processing.enqueue(meetingId)
            } label: {
                Label(model.detail?.meeting.status == .ready ? "Volver a procesar" : "Procesar", systemImage: "gearshape.2")
            }
            .disabled(env.processing.isBusy(meetingId) || model.detail?.tracks.isEmpty != false)
            .help("Transcribir con Parakeet Ultra y diarizar (local)")

            Menu {
                if let detail = model.detail {
                    ForEach(MediaExportFormat.allCases) { format in
                        Button(format.title) { env.mediaExport.begin(detail: detail, paths: env.paths, format: format) }
                            .disabled(env.mediaExport.isExporting || detail.tracks.isEmpty || detail.meeting.status == .recording
                                      || (format == .mp4 && (detail.video == nil || detail.video?.state == .recording || detail.video?.state == .failed)))
                    }
                }
                Divider()
                Menu("Transcripción y datos") {
                    ForEach(ExportFormat.allCases) { format in
                        Button(format.displayName) { export(format) }
                    }
                }
            } label: {
                Label("Exportar", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel("Exportar")
            .help("Exportar el audio, el video o la transcripción de esta reunión")
            .disabled(model.detail == nil)

            Menu {
                Button("Mostrar grabación en Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([env.paths.meetingDirectory(meetingId)])
                }
                Divider()
                Button("Eliminar reunión…", role: .destructive) { confirmDelete() }
            } label: {
                Label("Más", systemImage: "ellipsis.circle")
            }
        }
    }

    private func export(_ format: ExportFormat) {
        guard let meeting = model.detail?.meeting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingExporter.suggestedFileName(for: meeting, format: format)
        panel.directoryURL = env.paths.exportsDirectory
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var exporter = MeetingExporter(database: env.database)
            exporter.includeProbableEcho = env.settings.showProbableEcho
            try exporter.export(meetingId: meetingId, format: format, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func confirmDelete() {
        guard let meeting = model.detail?.meeting else { return }
        if MeetingDeletion.confirmAndDelete(meeting, env: env, beforeDeleting: { model.player.stop() }) {
            router.meetingPath = []
        }
    }
}

/// Compact transport bar shown under every tab except Audio.
struct PlayerBar: View {
    let player: MeetingAudioPlayer

    var body: some View {
        HStack(spacing: DS.Space.m) {
            IconButton(systemImage: "gobackward.10", help: "Retroceder 10 s") { player.skip(-10) }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(DS.Font.transportIcon)
                    .frame(width: DS.Size.playButton, height: DS.Size.playButton)
                    .background(DS.Color.accent, in: Circle())
                    .foregroundStyle(DS.Color.onAccent)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pausar" : "Reproducir")
            IconButton(systemImage: "goforward.10", help: "Avanzar 10 s") { player.skip(10) }
            Text(Timecode.compact(player.currentTime)).font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary)
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
                .controlSize(.small)
            Text(Timecode.compact(player.duration)).font(DS.Font.mono).foregroundStyle(DS.Color.textTertiary)
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button("\(r, format: .number.precision(.fractionLength(0...2)))×") { player.rate = Float(r) }
                }
            } label: {
                Text("\(Double(player.rate), format: .number.precision(.fractionLength(0...2)))×").font(DS.Font.mono)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.s)
        .background(DS.Color.surface)
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.border).frame(height: DS.Layout.hairline) }
    }
}
