import MeetingCore
import SwiftUI

struct TranscriptTab: View {
    let model: MeetingDetailModel
    let meetingId: String
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var followPlayback = true
    @State private var saveError: (segmentId: String, message: String)?
    @State private var actionError: String?

    private var segments: [TranscriptSegment] {
        guard let detail = model.detail else { return [] }
        return detail.segments.filter { env.settings.showProbableEcho || $0.attribution != .probableEcho }
    }

    private var matches: Set<String> {
        let q = TextNormalization.comparable(query)
        guard q.count >= 2 else { return [] }
        return Set(segments.filter { TextNormalization.comparable($0.displayText).contains(q) }.map(\.id))
    }

    private var activeId: String? {
        guard model.player.isPlaying || model.player.currentTime > 0 else { return nil }
        let t = model.player.currentTime
        return segments.last(where: { $0.startTime <= t + 0.05 })?.id
    }

    private var controls: some View {
        @Bindable var settings = env.settings
        return HStack(spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Color.textTertiary)
                TextField("Buscar en la transcripción", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Text("\(matches.count)").font(DS.Font.mono).foregroundStyle(DS.Color.textSecondary)
                }
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: DS.Layout.Control.searchFieldCompactHeight)
            .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.s).strokeBorder(DS.Color.border))
            .frame(minWidth: DS.Layout.Control.searchFieldMinWidth, maxWidth: DS.Layout.Control.searchFieldMaxWidth)
            Toggle("Seguir el audio", isOn: $followPlayback).toggleStyle(.checkbox).font(DS.Font.callout).fixedSize()
            Toggle("Mostrar eco probable", isOn: $settings.showProbableEcho).toggleStyle(.checkbox).font(DS.Font.callout)
                .fixedSize()
        }
    }

    var body: some View {
        VStack(spacing: DS.Space.none) {
            // Legend drops to its own line when the pills would squeeze the search field.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.m) {
                    controls
                    Spacer()
                    legend.fixedSize()
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack(spacing: DS.Space.m) { controls; Spacer() }
                    legend.fixedSize()
                }
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.m)

            if let actionError {
                InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill", title: actionError) {
                    IconButton(systemImage: "xmark", help: "Cerrar") { self.actionError = nil }
                }
                .padding(.horizontal, DS.Space.xxl)
                .padding(.bottom, DS.Space.m)
            }

            if segments.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.Space.none) {
                            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                                let previous = index > 0 ? segments[index - 1] : nil
                                SegmentRow(
                                    segment: segment,
                                    speakerName: model.detail?.speakerName(for: segment) ?? "",
                                    colorIndex: model.colorIndex(for: segment),
                                    showSpeaker: previous == nil || previous?.meetingSpeakerId != segment.meetingSpeakerId
                                        || previous?.participantId != segment.participantId
                                        || segment.startTime - (previous?.endTime ?? 0) > 30,
                                    isActive: activeId == segment.id,
                                    isMatch: matches.contains(segment.id),
                                    query: query,
                                    isEditing: model.editingSegmentId == segment.id,
                                    draft: model.segmentDrafts[segment.id],
                                    saveError: saveError?.segmentId == segment.id ? saveError?.message : nil,
                                    onSeek: { model.player.seek(to: segment.startTime, play: true) },
                                    onEdit: { beginEditing(segment) },
                                    onSave: { text in save(segment, text: text) },
                                    onCancel: { cancelEditing(segment) },
                                    onRevert: { revert(segment) })
                                .id(segment.id)
                            }
                        }
                        .padding(.horizontal, DS.Space.xxl)
                        .padding(.bottom, DS.Space.xxl)
                        .frame(maxWidth: DS.Layout.transcriptMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: activeId) { _, id in
                        guard followPlayback, model.player.isPlaying, let id, model.editingSegmentId == nil else { return }
                        withAnimation(DS.Motion.standard) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: query) {
                        if let first = segments.first(where: { matches.contains($0.id) }) {
                            withAnimation(DS.Motion.standard) { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        let detail = model.detail
        let edited = detail?.segments.filter { $0.editedText != nil }.count ?? 0
        let uncertain = detail?.segments.filter { $0.attribution == .uncertain }.count ?? 0
        let echo = detail?.segments.filter { $0.attribution == .probableEcho }.count ?? 0
        let lowConfidence = segments.filter(\.isLowConfidence).count
        return HStack(spacing: DS.Space.s) {
            if lowConfidence > 0 {
                StatusPill(text: "\(lowConfidence) por revisar", tone: .warning, systemImage: "exclamationmark.triangle")
                    .help("Fragmentos en los que el reconocimiento de voz tuvo poca confianza. Edítalos para confirmarlos.")
            }
            if edited > 0 { StatusPill(text: "\(edited) editados", tone: .accent, systemImage: "pencil") }
            if uncertain > 0 { StatusPill(text: "\(uncertain) atribución incierta", tone: .warning, systemImage: "questionmark") }
            if echo > 0 { StatusPill(text: "\(echo) eco probable", tone: .neutral, systemImage: "speaker.wave.2") }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let status = model.detail?.meeting.status
        if env.processing.isBusy(meetingId) {
            LoadingStateView(message: env.processing.progress(for: meetingId)?.message ?? "En cola para procesar…",
                             progress: env.processing.progress(for: meetingId)?.fraction)
        } else if status == .recording || env.recording.meeting?.id == meetingId {
            EmptyStateView(systemImage: "record.circle", title: "Grabación en curso",
                           message: "Podrás procesar la reunión cuando termine la grabación.")
        } else if status == .ready {
            EmptyStateView(systemImage: "waveform.slash", title: "Sin voz detectada",
                           message: "Parakeet Ultra no encontró habla en las pistas de esta reunión.")
        } else {
            EmptyStateView(systemImage: "text.bubble", title: "Aún no hay transcripción",
                           message: "Procesa la reunión para transcribirla localmente con Parakeet Ultra.") {
                Button("Procesar ahora") { env.processing.enqueue(meetingId) }.buttonStyle(.dsPrimary)
            }
        }
    }

    private func beginEditing(_ segment: TranscriptSegment) {
        if saveError?.segmentId != segment.id { saveError = nil }
        model.beginEditing(segment)
    }

    private func save(_ segment: TranscriptSegment, text: String) {
        do {
            try env.database.editSegmentText(segmentId: segment.id, newText: text)
        } catch {
            saveError = (segment.id, error.localizedDescription)
            return
        }
        saveError = nil
        model.discardDraft(segment.id)
        env.semantic.schedule()
    }

    private func cancelEditing(_ segment: TranscriptSegment) {
        if saveError?.segmentId == segment.id { saveError = nil }
        model.discardDraft(segment.id)
    }

    private func revert(_ segment: TranscriptSegment) {
        do {
            try env.database.revertSegmentText(segmentId: segment.id)
            actionError = nil
        } catch {
            actionError = "No se pudo restaurar el texto original: \(error.localizedDescription)"
        }
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let speakerName: String
    let colorIndex: Int?
    let showSpeaker: Bool
    let isActive: Bool
    let isMatch: Bool
    let query: String
    let isEditing: Bool
    var draft: SegmentDraft? = nil
    var saveError: String? = nil
    let onSeek: () -> Void
    let onEdit: () -> Void
    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onRevert: () -> Void

    @State private var hovering = false

    private var isUnknown: Bool {
        segment.participantId == nil && segment.attribution != .localUserTrack
    }

    private var hasUnsavedDraft: Bool {
        guard let draft else { return false }
        return draft.text.trimmingCharacters(in: .whitespacesAndNewlines) != segment.displayText
    }

    private let gutter = DS.Layout.timecodeGutter

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if showSpeaker {
                HStack(spacing: DS.Space.s) {
                    SpeakerAvatar(name: speakerName, colorIndex: colorIndex, size: DS.Size.avatarSmall, isUnknown: isUnknown && colorIndex == nil)
                    Text(speakerName).font(DS.Font.bodyEmphasis)
                        .foregroundStyle(colorIndex.map(DS.Color.speaker) ?? DS.Color.textSecondary)
                    badges
                }
                .padding(.leading, gutter + DS.Space.m)
                .padding(.top, DS.Space.s)
            }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                Button(action: onSeek) {
                    Text(Timecode.hms(segment.startTime))
                        .font(DS.Font.mono)
                        .foregroundStyle(isActive ? DS.Color.accent : DS.Color.textTertiary)
                        .frame(width: gutter, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Reproducir desde aquí")
                if isEditing, let draft {
                    editor(draft)
                } else {
                    Text(highlighted)
                        .font(DS.Font.reading)
                        .foregroundStyle(segment.attribution == .probableEcho ? DS.Color.textTertiary : DS.Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !showSpeaker { badges }
                    if hasUnsavedDraft {
                        StatusPill(text: "borrador sin guardar", tone: .warning, systemImage: "pencil.circle")
                            .help("Este fragmento tiene cambios sin guardar. Usa Editar texto para continuar.")
                    }
                    actions.opacity(hovering ? 1 : 0)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
        .padding(.horizontal, DS.Space.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(isActive ? DS.Color.accentSoft : (isMatch ? DS.Color.searchMatch : (hovering ? DS.Color.hover : .clear))))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reproducir desde aquí", action: onSeek)
            Button("Editar texto", action: onEdit)
            if segment.editedText != nil { Button("Restaurar texto original", action: onRevert) }
            Button("Copiar con timestamp") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[\(Timecode.hms(segment.startTime))] \(speakerName): \(segment.displayText)", forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Timecode.hms(segment.startTime)), \(speakerName): \(segment.displayText)")
    }

    @ViewBuilder
    private var badges: some View {
        switch segment.attribution {
        case .uncertain: StatusPill(text: "incierto", tone: .warning).help("Voces superpuestas o atribución ambigua")
        case .probableEcho: StatusPill(text: "eco probable", tone: .neutral).help("El micrófono captó audio remoto")
        case .recognized:
            StatusPill(text: "reconocido", tone: .success)
                .help(segment.speakerConfidence.map { "Similitud de voz \(String(format: "%.2f", $0))" } ?? "")
        default: EmptyView()
        }
        if segment.isLowConfidence, let confidence = segment.asrConfidence {
            StatusPill(text: "revisar", tone: .warning, systemImage: "exclamationmark.triangle")
                .help("Confianza del reconocimiento \(String(format: "%.2f", confidence)): puede contener errores o haber salido en otro idioma")
        }
        if segment.editedText != nil {
            StatusPill(text: "editado", tone: .accent, systemImage: "pencil")
                .help("Texto original (ASR): \(segment.vocabularyText ?? segment.asrText)")
        } else if segment.vocabularyText != nil {
            StatusPill(text: "diccionario", tone: .info).help("Original: \(segment.asrText)")
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Space.none) {
            IconButton(systemImage: "pencil", help: "Editar texto", action: onEdit)
            if segment.editedText != nil {
                IconButton(systemImage: "arrow.uturn.backward", help: "Restaurar texto original", action: onRevert)
            }
        }
    }

    private func editor(_ draft: SegmentDraft) -> some View {
        @Bindable var draft = draft
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            TextEditor(text: $draft.text)
                .font(DS.Font.reading)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.s)
                .frame(minHeight: DS.Layout.editorMinHeight)
                .background(DS.Color.surface, in: RoundedRectangle(cornerRadius: DS.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.s).strokeBorder(DS.Color.accent))
            if let saveError {
                InlineBanner(tone: .danger, systemImage: "exclamationmark.triangle.fill",
                             title: "No se pudo guardar el cambio", message: saveError)
            }
            HStack {
                Text("Original: \(segment.asrText)").font(DS.Font.caption).foregroundStyle(DS.Color.textTertiary).lineLimit(2)
                Spacer()
                Button("Cancelar", action: onCancel).buttonStyle(.ds(.ghost, size: .small)).keyboardShortcut(.escape, modifiers: [])
                Button("Guardar") { onSave(draft.text) }.buttonStyle(.ds(.primary, size: .small)).keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var highlighted: AttributedString {
        var text = AttributedString(segment.displayText)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return text }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text[searchRange].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = DS.Color.searchMatchHighlight
            searchRange = range.upperBound..<text.endIndex
        }
        return text
    }
}
