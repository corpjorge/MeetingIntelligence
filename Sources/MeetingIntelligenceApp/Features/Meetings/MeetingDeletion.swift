import AppKit
import MeetingCore
import OSLog

/// Confirmation and deletion of one meeting, shared by the list and the detail view.
/// Everything attached to the meeting is removed; the database file is compacted afterwards
/// so the freed space is returned to the disk.
enum MeetingDeletion {
    nonisolated private static let logger = Logger(subsystem: "dev.meetingintelligence", category: "library")

    /// Returns true when the meeting was deleted.
    @discardableResult
    static func confirmAndDelete(_ meeting: Meeting, env: AppEnvironment, beforeDeleting: () -> Void = {}) -> Bool {
        let current = (try? env.database.meeting(id: meeting.id)) ?? meeting
        guard !isRecording(current, recordingMeetingId: env.recording.meeting?.id) else {
            let alert = NSAlert()
            alert.messageText = "No se puede eliminar “\(meeting.title)” mientras se graba"
            alert.informativeText = "Detén y guarda la grabación antes de eliminar la reunión."
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }
        let summary = (try? env.database.deletionSummary(meetingId: meeting.id, paths: env.paths))
            ?? MeetingDeletionSummary(fileBytes: 0, voiceSamples: 0, chatMessages: 0)
        let alert = NSAlert()
        alert.messageText = "¿Eliminar “\(meeting.title)”?"
        alert.informativeText = informativeText(summary)
        alert.alertStyle = .warning
        var voiceSamplesBox: NSButton?
        if summary.voiceSamples > 0 {
            let box = NSButton(checkboxWithTitle: summary.voiceSamples == 1
                               ? "Borrar también la muestra de voz tomada de esta reunión"
                               : "Borrar también las \(summary.voiceSamples) muestras de voz tomadas de esta reunión",
                               target: nil, action: nil)
            box.state = NSControl.StateValue.off
            alert.accessoryView = box
            voiceSamplesBox = box
        }
        alert.addButton(withTitle: "Eliminar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        beforeDeleting()
        env.processing.cancel(meeting.id)
        do {
            try env.database.deleteMeeting(id: meeting.id, paths: env.paths,
                                           includeVoiceSamples: voiceSamplesBox?.state == NSControl.StateValue.on)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        let database = env.database
        Task.detached(priority: .utility) {
            do { try database.compactStorage() } catch {
                logger.error("Compaction after delete failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    static func isRecording(_ meeting: Meeting, recordingMeetingId: String?) -> Bool {
        meeting.status == .recording || meeting.id == recordingMeetingId
    }

    static func informativeText(_ summary: MeetingDeletionSummary) -> String {
        let size = ByteCountFormatter.string(fromByteCount: summary.fileBytes, countStyle: .file)
        var parts = ["Se eliminan el audio (\(size)), la transcripción, los hablantes, los análisis y su índice de búsqueda."]
        if summary.chatMessages == 1 {
            parts.append("También se borra 1 mensaje del chat que la usa.")
        } else if summary.chatMessages > 1 {
            parts.append("También se borran \(summary.chatMessages) mensajes del chat que la usan.")
        }
        if summary.voiceSamples > 0 {
            parts.append("Las muestras de voz se conservan en el perfil del participante salvo que marques la casilla.")
        }
        parts.append("Esta acción no se puede deshacer.")
        return parts.joined(separator: " ")
    }
}
