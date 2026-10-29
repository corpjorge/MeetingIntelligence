import AppKit
import AVFoundation
import MeetingAudio
import MeetingCore
import MeetingMedia
import ScreenCaptureKit

/// Opt-in integration fixture: captures only a window owned by this process,
/// never a user's meeting or microphone. Requires an isolated library override.
enum MediaVerificationDriver {
    private actor PreviewProbe {
        private(set) var frames = 0
        func receive() { frames += 1 }
    }

    static func run(env: AppEnvironment, directory: URL) async {
        guard ProcessInfo.processInfo.environment[AppPaths.environmentOverrideKey] != nil else { return }
        var report: [String: Any] = [:]
        let frame = NSRect(x: 100, y: 100, width: 640, height: 360)
        let source = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let cover = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false; cover.isReleasedWhenClosed = false
        defer { source.close(); cover.close() }
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(deviceRed: 0.1, green: 0.2, blue: 0.8, alpha: 1).cgColor
        source.contentView = view
        let covering = NSView(frame: view.frame)
        covering.wantsLayer = true
        covering.layer?.backgroundColor = NSColor(deviceRed: 0.9, green: 0.1, blue: 0.1, alpha: 1).cgColor
        cover.contentView = covering
        do {
            source.orderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            let content = try await SCShareableContent.currentProcess
            guard let window = content.windows.first(where: { $0.windowID == CGWindowID(source.windowNumber) }) else {
                throw MediaError.unavailable("No se encontró la ventana sintética.")
            }
            var meeting = Meeting(title: "FIXTURE · Video y audio", origin: .recording, captureScope: .microphoneOnly, status: .ready)
            let folder = try env.paths.prepareMeetingDirectory(meeting.id)
            let videoURL = folder.appendingPathComponent(WindowVideoRecorder.fileName)
            let probe = PreviewProbe()
            let recorder = try WindowVideoRecorder(filter: SCContentFilter(desktopIndependentWindow: window),
                                                   onPreview: { _ in Task { await probe.receive() } })
            try await recorder.start()
            try await Task.sleep(for: .milliseconds(600))
            report["previewFramesBeforeRecording"] = await probe.frames
            report["noFileBeforeRecording"] = !FileManager.default.fileExists(atPath: videoURL.path)
            let clock = CaptureClock()
            try recorder.beginRecording(to: videoURL, clock: clock, onStatus: { _ in })
            // Recording awaits the original completed start; it creates no second stream.
            try await recorder.start()
            try await Task.sleep(for: .seconds(1))
            cover.orderFront(nil)
            view.layer?.backgroundColor = NSColor(deviceRed: 0.1, green: 0.8, blue: 0.2, alpha: 1).cgColor
            try await Task.sleep(for: .seconds(1))
            clock.pause()
            try await Task.sleep(for: .milliseconds(400))
            clock.resume()
            try await Task.sleep(for: .milliseconds(700))
            let duration = clock.elapsed
            let dropped = try await recorder.stop(at: duration)
            meeting.durationSeconds = duration
            source.orderOut(nil); cover.orderOut(nil)
            var tracks: [AudioTrack] = []
            for (index, source) in [AudioSource.localMicrophone, .remoteSystemAudio].enumerated() {
                let url = folder.appendingPathComponent("\(source.fileStem).wav")
                let writer = try CrashSafeWAVWriter(url: url, sampleRate: 16_000)
                let samples = (0..<Int(duration * 16_000)).map { Float(sin(Double($0) * 2 * .pi * Double(440 + index * 220) / 16_000) * 0.3) }
                try writer.append(samples)
                try writer.close()
                tracks.append(AudioTrack(meetingId: meeting.id, source: source, relativePath: env.paths.relativePath(for: url)!,
                                         sampleRate: 16_000, channelCount: 1, durationSeconds: duration))
            }
            try env.database.insert(meeting: meeting, tracks: tracks)
            let video = VideoAsset(meetingId: meeting.id, relativePath: env.paths.relativePath(for: videoURL)!,
                                   windowTitle: "Ventana sintética cubierta", applicationName: "Verificación local",
                                   width: recorder.width, height: recorder.height, durationSeconds: duration,
                                   fileSizeBytes: StorageMaintenance.size(of: videoURL), state: .ready)
            try env.database.save(video: video)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let before = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
            let after = try await generator.image(at: CMTime(seconds: 1.6, preferredTimescale: 600)).image
            let beforeColor = NSBitmapImageRep(cgImage: before).colorAt(x: before.width / 2, y: before.height / 2)?.usingColorSpace(.deviceRGB)
            let afterColor = NSBitmapImageRep(cgImage: after).colorAt(x: after.width / 2, y: after.height / 2)?.usingColorSpace(.deviceRGB)
            report["blueBeforeCover"] = (beforeColor?.blueComponent ?? 0) > 0.6
            report["greenWhileCovered"] = (afterColor?.greenComponent ?? 0) > 0.6
            report["durationSeconds"] = duration
            report["droppedFrames"] = dropped
            report["meetingId"] = meeting.id
            for format in MediaExportFormat.allCases {
                let destination = directory.appendingPathComponent("verification.\(format.rawValue)")
                try await MeetingMediaExporter.export(tracks: tracks, video: video, paths: env.paths, format: format, to: destination)
                report[format.rawValue] = StorageMaintenance.size(of: destination)
            }
            report["success"] = report["blueBeforeCover"] as? Bool == true
                && report["greenWhileCovered"] as? Bool == true
                && (report["previewFramesBeforeRecording"] as? Int ?? 0) > 0
                && report["noFileBeforeRecording"] as? Bool == true
        } catch {
            report["success"] = false
            report["error"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("verification.json"))
        }
    }
}
