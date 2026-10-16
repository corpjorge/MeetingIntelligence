import MeetingCore
import SwiftUI

struct MeetingRowView: View {
    @Environment(AppEnvironment.self) private var env
    let row: MeetingSummaryRow
    var compact = false

    var body: some View {
        HStack(spacing: DS.Space.m) {
            DateBadge(date: row.meeting.displayDate)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(row.meeting.title).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.textPrimary).lineLimit(1)
                HStack(spacing: DS.Space.s) {
                    Text(row.meeting.displayDate.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text(Timecode.humanDuration(row.meeting.durationSeconds))
                    if row.speakerCount > 0 {
                        Text("·")
                        Text("\(row.speakerCount) hablantes")
                    }
                    if row.openActionItems > 0, !compact {
                        Text("·")
                        Text("\(row.openActionItems) pendientes")
                    }
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textTertiary)
                .lineLimit(1)
                .fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: DS.Space.m)
            if !compact { ScopeBadge(meeting: row.meeting) }
            MeetingStatusPill(meeting: row.meeting, busy: env.processing.isBusy(row.id))
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s + 2)
        .contentShape(Rectangle())
        .hoverHighlight()
        .accessibilityElement(children: .combine)
    }
}

struct DateBadge: View {
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Color.accent)
            Text(date.formatted(.dateTime.day())).font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.Color.textPrimary)
        }
        .frame(width: 38, height: 38)
        .background(DS.Color.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
    }
}

struct MeetingStatusPill: View {
    let meeting: Meeting
    var busy = false

    var body: some View {
        if busy {
            StatusPill(text: "Procesando", tone: .accent, systemImage: "gearshape.2")
        } else {
            switch meeting.status {
            case .recording: StatusPill(text: "Grabando", tone: .recording, systemImage: "record.circle")
            case .recorded: StatusPill(text: "Sin procesar", tone: .neutral)
            case .interrupted: StatusPill(text: "Interrumpida", tone: .warning, systemImage: "exclamationmark.triangle")
            case .processing: StatusPill(text: "Procesando", tone: .accent)
            case .ready: StatusPill(text: "Transcrita", tone: .success, systemImage: "checkmark")
            case .failed: StatusPill(text: "Error", tone: .danger, systemImage: "xmark")
            }
        }
    }
}

struct ScopeBadge: View {
    let scope: CaptureScope
    var appName: String?

    init(scope: CaptureScope, appName: String? = nil) {
        self.scope = scope
        self.appName = appName
    }

    init(meeting: Meeting) {
        self.init(scope: meeting.captureScope, appName: meeting.sourceAppName)
    }

    var body: some View {
        switch scope {
        case .teamsProcesses: StatusPill(text: "Teams", tone: .info, systemImage: "person.3")
        case .applicationProcesses: StatusPill(text: appName ?? "Aplicación", tone: .info, systemImage: "person.3")
        case .systemWide: StatusPill(text: "Todo el sistema", tone: .warning, systemImage: "speaker.wave.3")
        case .microphoneOnly: StatusPill(text: "Solo micrófono", tone: .neutral, systemImage: "mic")
        case .importedFile: StatusPill(text: "Importada", tone: .neutral, systemImage: "doc")
        }
    }
}
