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

    private(set) var active: ActiveJob?
    private(set) var queue: [String] = []
    private(set) var lastError: (meetingId: String, message: String)?
    private(set) var lastCompleted: (meetingId: String, summary: String)?

    private let processor: MeetingProcessor
    private let settings: AppSettings
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "dev.meetingintelligence", category: "processing")

    init(processor: MeetingProcessor, settings: AppSettings) {
        self.processor = processor
        self.settings = settings
    }

    func isBusy(_ meetingId: String) -> Bool {
        active?.meetingId == meetingId || queue.contains(meetingId)
    }

    func progress(for meetingId: String) -> PipelineProgress? {
        active?.meetingId == meetingId ? active?.progress : nil
    }

    func enqueue(_ meetingId: String) {
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

    private func startNextIfIdle() {
        guard active == nil, !queue.isEmpty else { return }
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
            } catch is CancellationError {
                self?.logger.notice("Processing cancelled")
            } catch {
                self?.lastError = (meetingId, error.localizedDescription)
            }
            self?.active = nil
            self?.task = nil
            self?.startNextIfIdle()
        }
    }

    private func update(_ progress: PipelineProgress) {
        guard active?.meetingId == progress.meetingId else { return }
        active?.progress = progress
    }
}
