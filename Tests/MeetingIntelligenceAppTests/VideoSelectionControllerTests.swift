import AppKit
import MeetingMedia
import ScreenCaptureKit
import Testing
@testable import MeetingIntelligenceApp

private final class FakeVideoPreview: VideoPreviewSession {
    var onFrame: (NSImage) -> Void = { _ in }
    var onStatus: (VideoCaptureStatus) -> Void = { _ in }
    var error: (any Error)?
    var frameOnStart = true
    var failOnStart = false
    var startCount = 0
    var stopCount = 0
    var resumeStart: CheckedContinuation<Void, Never>?
    var delayStart = false

    func start() async throws {
        startCount += 1
        if delayStart { await withCheckedContinuation { resumeStart = $0 } }
        if let error { throw error }
        if failOnStart { onStatus(.failed("fixture stopped")); return }
        if frameOnStart { onFrame(NSImage(size: NSSize(width: 2, height: 2))) }
    }
    func stop() async { stopCount += 1 }
    func takeRecorder() -> WindowVideoRecorder? { nil }
}

@Suite("Video: vista previa del stream autorizado")
struct VideoSelectionControllerTests {
    @Test func selectionStartsPreviewAutomaticallyAndReceivesLiveFrames() async {
        let capture = FakeVideoPreview()
        let selection = VideoSelectionController(makeSession: { _, frame, status in
            capture.onFrame = frame; capture.onStatus = status; return capture
        })
        let filter = SCContentFilter()
        await selection.acceptConfirmedWindow(filter, title: "FIXTURE").value
        #expect(capture.startCount == 1)
        #expect(selection.filter === filter && selection.canRecord)
        #expect(selection.preview != nil && !selection.isLoadingPreview && selection.error == nil)
        let updated = NSImage(size: NSSize(width: 3, height: 3))
        capture.onFrame(updated)
        #expect(selection.preview === updated)
        selection.clear()
    }

    @Test func actualStartFailurePreservesSelectionAndShowsRealError() async {
        let capture = FakeVideoPreview()
        capture.error = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let selection = VideoSelectionController(makeSession: { _, _, _ in capture })
        let filter = SCContentFilter()
        await selection.acceptConfirmedWindow(filter).value
        #expect(selection.filter === filter)
        #expect(!selection.canRecord && !selection.isLoadingPreview)
        #expect(selection.error?.contains("esta copia") == true)
        #expect(capture.stopCount == 1)
    }

    @Test func choosingAndCancellingKeepsExistingAuthorizedPreview() async {
        let capture = FakeVideoPreview()
        let selection = VideoSelectionController(makeSession: { _, frame, status in
            capture.onFrame = frame; capture.onStatus = status; return capture
        })
        let filter = SCContentFilter()
        await selection.acceptConfirmedWindow(filter).value
        selection.beginSelection()
        #expect(!selection.canRecord)
        selection.cancelSelection()
        #expect(selection.filter === filter && selection.canRecord)
        #expect(capture.startCount == 1 && capture.stopCount == 0)
        selection.clear()
        try? await Task.sleep(for: .milliseconds(10))
        #expect(capture.stopCount == 1)
    }

    @Test func failedStreamCannotBeMarkedReadyByLateStartCompletion() async {
        let capture = FakeVideoPreview()
        capture.failOnStart = true
        let selection = VideoSelectionController(makeSession: { _, frame, status in
            capture.onFrame = frame; capture.onStatus = status; return capture
        })
        await selection.acceptConfirmedWindow(SCContentFilter()).value
        #expect(!selection.canRecord)
        #expect(selection.error == "fixture stopped")
        #expect(capture.stopCount == 1)
    }

    @Test func oldPendingPreviewCannotReplaceNewSelectionAndIsStopped() async throws {
        let first = FakeVideoPreview(); first.delayStart = true
        let second = FakeVideoPreview()
        var calls = 0
        let selection = VideoSelectionController(makeSession: { _, frame, status in
            calls += 1
            let capture = calls == 1 ? first : second
            capture.onFrame = frame; capture.onStatus = status
            return capture
        })
        let old = selection.acceptConfirmedWindow(SCContentFilter(), title: "Old")
        try await waitUntil { first.resumeStart != nil }
        let newFilter = SCContentFilter()
        await selection.acceptConfirmedWindow(newFilter, title: "New").value
        let latest = selection.preview
        first.resumeStart?.resume()
        await old.value
        first.onFrame(NSImage(size: NSSize(width: 4, height: 4)))
        #expect(selection.filter === newFilter && selection.title == "New")
        #expect(selection.preview === latest && selection.canRecord)
        #expect(first.stopCount >= 1)
        selection.clear()
    }

    @Test func actualCaptureDenialExplainsCopyIdentityInsteadOfAssumingToggleIsOff() {
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        #expect(VideoSelectionController.startFailureMessage(denied)?.contains("esta copia") == true)
        #expect(VideoSelectionController.startFailureMessage(NSError(domain: "other", code: -3801)) == nil)
    }
}
