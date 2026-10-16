import MeetingAudio
import MeetingCore
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class MeetingsModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Todas", pending = "Sin procesar", ready = "Transcritas", failed = "Con error"
        var id: String { rawValue }
    }
    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Más recientes", oldest = "Más antiguas", longest = "Más largas", title = "Título"
        var id: String { rawValue }
    }

    var rows: [MeetingSummaryRow] = []
    var loaded = false
    var query = ""
    var filter: Filter = .all
    var sort: Sort = .newest
    var contentHits: [SearchHit] = []
    var importError: String?
    var importing = false

    var visibleRows: [MeetingSummaryRow] {
        var result = rows.filter { row in
            switch filter {
            case .all: true
            case .pending: [.recorded, .interrupted].contains(row.meeting.status)
            case .ready: row.meeting.status == .ready
            case .failed: row.meeting.status == .failed
            }
        }
        let q = TextNormalization.comparable(query)
        if !q.isEmpty {
            result = result.filter { TextNormalization.comparable($0.meeting.title).contains(q) }
        }
        switch sort {
        case .newest: result.sort { $0.meeting.displayDate > $1.meeting.displayDate }
        case .oldest: result.sort { $0.meeting.displayDate < $1.meeting.displayDate }
        case .longest: result.sort { $0.meeting.durationSeconds > $1.meeting.durationSeconds }
        case .title: result.sort { $0.meeting.title.localizedCaseInsensitiveCompare($1.meeting.title) == .orderedAscending }
        }
        return result
    }

    func observe(_ db: AppDatabase) async {
        do {
            for try await rows in db.observeMeetingRows() {
                self.rows = rows
                loaded = true
            }
        } catch {}
    }

    func searchContent(_ db: AppDatabase) {
        let q = query
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { contentHits = []; return }
        contentHits = (try? SearchService(reader: db.reader).search(q, limit: 30)) ?? []
    }
}

struct MeetingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @State private var model = MeetingsModel()
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        @Bindable var router = router
        PageScaffold(title: "Reuniones", subtitle: "\(model.rows.count) en la biblioteca local") {
            Button { router.isImporting = true } label: { Label("Importar audio", systemImage: "square.and.arrow.down") }
                .buttonStyle(.dsSecondary)
                .disabled(model.importing)
            Button { router.section = .recording } label: { Label("Grabar", systemImage: "record.circle") }
                .buttonStyle(.ds(.recording))
        } content: {
            toolbar
            if model.importing {
                InlineBanner(tone: .info, systemImage: "square.and.arrow.down", title: "Importando audio…") {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = model.importError {
                InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill", title: "No se pudo importar", message: error) {
                    IconButton(systemImage: "xmark", help: "Cerrar") { model.importError = nil }
                }
            }
            if !model.contentHits.isEmpty {
                contentResults
            }
            list
        }
        .fileImporter(isPresented: $router.isImporting,
                      allowedContentTypes: [.audio, .movie, .mpeg4Movie, .mpeg4Audio, .mp3, .wav],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(fileURL)
                    }
                }
                importFiles(urls)
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: DS.Radius.l).strokeBorder(DS.Color.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(DS.Color.accentSoft)
                    .overlay(Label("Suelta para importar", systemImage: "square.and.arrow.down").font(DS.Font.headline))
                    .padding(DS.Space.l)
                    .allowsHitTesting(false)
            }
        }
        .task { await model.observe(env.database) }
        .onChange(of: model.query) { model.searchContent(env.database) }
    }

    private var toolbar: some View {
        @Bindable var model = model
        return HStack(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Color.textTertiary)
                TextField("Buscar por título o contenido de las transcripciones", text: $model.query)
                    .textFieldStyle(.plain).font(DS.Font.body)
                if !model.query.isEmpty {
                    IconButton(systemImage: "xmark.circle.fill", help: "Limpiar búsqueda") { model.query = "" }
                }
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: 32)
            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.s).strokeBorder(DS.Color.border))

            Picker("Estado", selection: $model.filter) {
                ForEach(MeetingsModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
            .labelsHidden()

            Menu {
                Picker("Ordenar", selection: $model.sort) {
                    ForEach(MeetingsModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label(model.sort.rawValue, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var contentResults: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "En las transcripciones", subtitle: "\(model.contentHits.count) coincidencias (búsqueda local FTS5)")
            SurfaceCard(padding: DS.Space.xs) {
                VStack(spacing: 0) {
                    ForEach(model.contentHits.prefix(8)) { hit in
                        Button { router.openMeeting(hit.meetingId, tab: .transcript) } label: {
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                HStack {
                                    Text(hit.meetingTitle).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.textPrimary)
                                    Text("· \(Timecode.hms(hit.startTime)) · \(hit.speakerName)")
                                        .font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary)
                                }
                                HighlightedSnippet(snippet: hit.snippet).lineLimit(2)
                            }
                            .padding(DS.Space.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .hoverHighlight()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        let rows = model.visibleRows
        SurfaceCard(padding: DS.Space.xs) {
            if !model.loaded {
                LoadingStateView(message: "Cargando reuniones…")
            } else if model.rows.isEmpty {
                EmptyStateView(systemImage: "rectangle.stack.badge.plus", title: "Tu biblioteca está vacía",
                               message: "Importa una grabación (WAV, M4A, MP3 o MP4) o arrástrala aquí. También puedes grabar una llamada de Teams.") {
                    Button("Importar audio") { router.isImporting = true }.buttonStyle(.dsPrimary)
                }
            } else if rows.isEmpty {
                EmptyStateView(systemImage: "line.3.horizontal.decrease.circle", title: "Sin resultados",
                               message: "Ninguna reunión coincide con los filtros actuales.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        NavigationLink(value: row.id) { MeetingRowView(row: row) }
                            .buttonStyle(.plain)
                            .contextMenu { rowMenu(row) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: MeetingSummaryRow) -> some View {
        Button("Abrir") { router.openMeeting(row.id) }
        Button(row.meeting.status == .ready ? "Volver a procesar" : "Procesar") { env.processing.enqueue(row.id) }
            .disabled(env.processing.isBusy(row.id))
        Divider()
        Button("Eliminar…", role: .destructive) { confirmDelete(row.meeting) }
    }

    private func confirmDelete(_ meeting: Meeting) {
        let alert = NSAlert()
        alert.messageText = "¿Eliminar “\(meeting.title)”?"
        alert.informativeText = "Se eliminarán el audio, la transcripción, los hablantes y los análisis de esta reunión. Esta acción no se puede deshacer."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            try? env.database.deleteMeeting(id: meeting.id, paths: env.paths)
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        model.importing = true
        model.importError = nil
        Task {
            for url in urls {
                do {
                    let meeting = try await env.importer.importAudio(at: url, language: env.settings.language)
                    if env.models.asrStatus == .ready || env.settings.autoProcessAfterRecording {
                        env.processing.enqueue(meeting.id)
                    }
                } catch {
                    model.importError = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            model.importing = false
        }
    }
}
