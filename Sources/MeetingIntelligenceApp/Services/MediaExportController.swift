import AppKit
import MeetingCore
import MeetingMedia
import UniformTypeIdentifiers

@Observable
final class MediaExportController {
    private(set) var isExporting = false
    private(set) var progress = 0.0
    var error: String?
    private var task: Task<Void, Never>?

    func begin(detail: MeetingDetail, paths: AppPaths, format: MediaExportFormat) {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .mp4 ? .mpeg4Movie : format == .m4a ? .mpeg4Audio : .wav]
        let safeTitle = detail.meeting.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeTitle).\(format.rawValue)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true; progress = 0; error = nil
        task = Task {
            do {
                try await MeetingMediaExporter.export(tracks: detail.tracks, video: detail.video, paths: paths,
                                                      format: format, to: url) { value in
                    Task { @MainActor in if self.isExporting { self.progress = value } }
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = "No se pudo exportar: \(error.localizedDescription)" }
            }
            isExporting = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }
}
