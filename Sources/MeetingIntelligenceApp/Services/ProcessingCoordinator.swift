import Foundation
import MeetingCore
import MeetingSpeech
import OSLog

/// Serial queue of meetings to process, with real progress and cancellation.
@Observable
final class ProcessingCoordinator {
    struct ActiveJob: Equatable {
        var meetingId: String
        var progress: PipelineProgress?
        var startedAt: Date
    }

    struct Notice: Equatable {
        var meetingId: String?
        var title: String
        var message: String
    }

    private(set) var active: ActiveJob?
    private(set) var queue: [String] = []
    private(set) var lastError: (meetingId: String, message: String)?
    private(set) var lastCompleted: (meetingId: String, summary: String)?
    private(set) var notice: Notice?
    var blockedReason: String?
    private(set) var startSuspensions = 0
    /// Called after a meeting finished processing successfully.
    var onCompleted: ((String) -> Void)?

    private let processor: MeetingProcessor
    private let settings: AppSettings
    private let database: AppDatabase?
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "processing")

    init(processor: MeetingProcessor, settings: AppSettings, database: AppDatabase? = nil) {
        self.processor = processor
        self.settings = settings
        self.database = database
    }

    func isBusy(_ meetingId: String) -> Bool {
        active?.meetingId == meetingId || queue.contains(meetingId)
    }

    func progress(for meetingId: String) -> PipelineProgress? {
        active?.meetingId == meetingId ? active?.progress : nil
    }

    func enqueue(_ meetingId: String) {
        if let blockedReason {
            notice = Notice(meetingId: nil, title: "No se puede procesar", message: blockedReason)
            return
        }
        guard !isBusy(meetingId) else { return }
        queue.append(meetingId)
        startNextIfIdle()
    }

    func cancel(_ meetingId: String) {
        if active?.meetingId == meetingId {
            task?.cancel()
        } else {
            queue.removeAll { $0 == meetingId }
        }
    }

    func dismissError() { lastError = nil }

    func dismissNotice() { notice = nil }

    func suspendStarts() { startSuspensions += 1 }

    func resumeStarts() {
        startSuspensions = max(0, startSuspensions - 1)
        startNextIfIdle()
    }

    private func meetingExists(_ meetingId: String) -> Bool {
        guard let database else { return true }
        do {
            return try database.meeting(id: meetingId) != nil
        } catch {
            return true
        }
    }

    private func startNextIfIdle() {
        guard active == nil, startSuspensions == 0, !queue.isEmpty else { return }
        let meetingId = queue.removeFirst()
        active = ActiveJob(meetingId: meetingId, progress: nil, startedAt: Date())
        let options = settings.processingOptions
        let processor = self.processor
        task = Task { [weak self] in
            do {
                let summary = try await processor.process(meetingId: meetingId, options: options) { progress in
                    Task { @MainActor in self?.update(progress) }
                }
                let words = summary.tracks.reduce(0) { $0 + $1.words }
                self?.lastCompleted = (meetingId, "\(words) palabras en \(String(format: "%.1f", summary.totalSeconds)) s")
                if let message = Self.editsNotice(carried: summary.carriedEdits, dropped: summary.droppedEdits) {
                    self?.notice = Notice(meetingId: meetingId, title: "Procesamiento completado", message: message)
                }
                self?.onCompleted?(meetingId)
            } catch is CancellationError {
                self?.logger.notice("Processing cancelled")
            } catch {
                if Task.isCancelled || self?.meetingExists(meetingId) == false {
                    self?.logger.notice("Processing stopped for a cancelled or deleted meeting")
                } else {
                    self?.lastError = (meetingId, ProcessingErrorText.describe(error))
                }
            }
            self?.active = nil
            self?.task = nil
            self?.startNextIfIdle()
        }
    }

    static func editsNotice(carried: Int, dropped: Int) -> String? {
        guard dropped > 0 else { return nil }
        var text = dropped == 1
            ? "1 corrección de texto no se pudo trasladar al reprocesar; sigue en el historial."
            : "\(dropped) correcciones de texto no se pudieron trasladar al reprocesar; siguen en el historial."
        if carried > 0 {
            text += carried == 1 ? " 1 corrección sí se trasladó." : " \(carried) correcciones sí se trasladaron."
        }
        return text
    }

    private func update(_ progress: PipelineProgress) {
        guard active?.meetingId == progress.meetingId else { return }
        active?.progress = progress
    }
}
