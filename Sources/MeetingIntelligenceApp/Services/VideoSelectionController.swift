import AppKit
import MeetingCore
import MeetingMedia
@preconcurrency import ScreenCaptureKit

/// The preview owns the authorized stream until recording takes ownership.
/// A fake session exercises selection/cancellation without capturing any content.
@MainActor
protocol VideoPreviewSession: AnyObject {
    func start() async throws
    func stop() async
    func takeRecorder() -> WindowVideoRecorder?
}

@MainActor
private final class NativeVideoPreviewSession: VideoPreviewSession {
    private var recorder: WindowVideoRecorder?

    init(filter: SCContentFilter, onFrame: @escaping @MainActor (NSImage) -> Void,
         onStatus: @escaping @MainActor (VideoCaptureStatus) -> Void) throws {
        recorder = try WindowVideoRecorder(filter: filter, onStatus: { status in
            Task { @MainActor in onStatus(status) }
        }, onPreview: { image in
            Task { @MainActor in onFrame(NSImage(cgImage: image, size: .zero)) }
        })
    }

    func start() async throws { try await recorder?.start() }
    func stop() async {
        let recorder = recorder
        self.recorder = nil
        await recorder?.stopPreview()
    }
    func takeRecorder() -> WindowVideoRecorder? {
        let recorder = recorder
        self.recorder = nil
        return recorder
    }
}

/// Selection starts an image-only preview, never audio or file recording. The
/// same stream is transferred to RecordingController when the user presses Start.
@Observable
final class VideoSelectionController: NSObject, SCContentSharingPickerObserver {
    typealias SessionFactory = @MainActor (SCContentFilter, @escaping @MainActor (NSImage) -> Void,
                                          @escaping @MainActor (VideoCaptureStatus) -> Void) throws -> any VideoPreviewSession
    private(set) var filter: SCContentFilter?
    private(set) var title = ""
    private(set) var applicationName = ""
    private(set) var bundleIdentifier: String?
    private(set) var preview: NSImage?
    private(set) var isChoosing = false
    private(set) var isLoadingPreview = false
    private(set) var error: String?
    private(set) var captureReady = false
    var canRecord: Bool { filter != nil && captureReady && !isChoosing }
    private let makeSession: SessionFactory
    private var session: (any VideoPreviewSession)?
    private var registered = false
    private var revision = UUID()
    private var startupFailed = false
    private var previewTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(makeSession: @escaping SessionFactory = { filter, onFrame, onStatus in
        try NativeVideoPreviewSession(filter: filter, onFrame: onFrame, onStatus: onStatus)
    }) {
        self.makeSession = makeSession
        super.init()
    }

    func beginSelection() { error = nil; isChoosing = true }

    func choose() {
        guard !isChoosing else { return }
        beginSelection()
        let picker = SCContentSharingPicker.shared
        if !registered { picker.add(self); registered = true }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? AppIdentity.fallbackBundleIdentifier]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present(using: .window)
    }

    func clear() {
        revision = UUID()
        previewTask?.cancel(); previewTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        let previous = session; session = nil
        Task { await previous?.stop() }
        filter = nil; preview = nil; title = ""; applicationName = ""; bundleIdentifier = nil
        captureReady = false; isChoosing = false; isLoadingPreview = false; error = nil
        if registered {
            SCContentSharingPicker.shared.remove(self)
            SCContentSharingPicker.shared.isActive = false
            registered = false
        }
    }

    /// Transfer, never recreate, the stream that produced the visible preview.
    func takeRecorder() -> WindowVideoRecorder? {
        guard canRecord, let recorder = session?.takeRecorder() else { return nil }
        revision = UUID()
        previewTask?.cancel(); previewTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        session = nil; captureReady = false
        return recorder
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.cancelSelection() }
    }
    func cancelSelection() { isChoosing = false }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.isChoosing = false
            self?.error = "No se pudo abrir el selector de ventana: \(message)"
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self, self.isChoosing, filter.style == .window else { return }
            if #available(macOS 15.2, *), let window = filter.includedWindows.first {
                self.acceptConfirmedWindow(filter, title: window.title ?? "Ventana sin título",
                                           applicationName: window.owningApplication?.applicationName ?? "",
                                           bundleIdentifier: window.owningApplication?.bundleIdentifier)
            } else { self.acceptConfirmedWindow(filter) }
        }
    }

    @discardableResult
    func acceptConfirmedWindow(_ filter: SCContentFilter, title: String = "Ventana seleccionada",
                               applicationName: String = "", bundleIdentifier: String? = nil) -> Task<Void, Never> {
        revision = UUID()
        let revision = revision
        previewTask?.cancel(); timeoutTask?.cancel()
        let previous = session; session = nil
        self.filter = filter; self.title = title
        self.applicationName = applicationName; self.bundleIdentifier = bundleIdentifier
        isChoosing = false; isLoadingPreview = true; captureReady = false
        preview = nil; error = nil; startupFailed = false
        let task = Task { [weak self, makeSession] in
            await previous?.stop()
            guard let self, self.revision == revision, !Task.isCancelled else { return }
            do {
                let capture = try makeSession(filter, { [weak self] image in
                    guard let self, self.revision == revision else { return }
                    self.preview = image; self.isLoadingPreview = false
                    self.timeoutTask?.cancel(); self.timeoutTask = nil
                    self.error = nil
                }, { [weak self] status in
                    guard let self, self.revision == revision else { return }
                    switch status {
                    case .recording: self.error = nil
                    case .unavailable(let message): self.error = message; self.isLoadingPreview = false
                    case .failed(let message):
                        self.startupFailed = true
                        self.error = message; self.isLoadingPreview = false; self.captureReady = false
                    }
                })
                self.session = capture
                try await capture.start()
                guard self.revision == revision, !Task.isCancelled else { await capture.stop(); return }
                guard !self.startupFailed else { await capture.stop(); self.session = nil; return }
                self.captureReady = true
                if self.preview == nil, self.isLoadingPreview {
                    self.timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        guard let self, self.revision == revision, self.preview == nil else { return }
                        self.isLoadingPreview = false
                        self.error = "La captura está activa, pero aún no llega imagen. Comprueba que la ventana no esté minimizada."
                    }
                }
            } catch {
                guard self.revision == revision, !Task.isCancelled else { return }
                self.captureReady = false; self.isLoadingPreview = false
                self.error = Self.startFailureMessage(error) ?? "No se pudo abrir la ventana seleccionada: \(error.localizedDescription)"
                let failed = self.session; self.session = nil
                await failed?.stop()
            }
        }
        previewTask = task
        return task
    }

    @discardableResult
    func retryPreview() -> Task<Void, Never>? {
        guard let filter, !isChoosing, !isLoadingPreview else { return nil }
        return acceptConfirmedWindow(filter, title: title, applicationName: applicationName, bundleIdentifier: bundleIdentifier)
    }

    static func startFailureMessage(_ error: any Error) -> String? {
        let failure = error as NSError
        guard failure.domain == SCStreamErrorDomain, failure.code == SCStreamError.Code.userDeclined.rawValue else { return nil }
        return "macOS rechazó la captura para esta copia de Meeting Intelligence. Si ya la autorizaste, cierra la app y vuelve a abrir esta misma compilación. La copia de Aplicaciones y una recompilada pueden tener autorizaciones distintas."
    }
}
