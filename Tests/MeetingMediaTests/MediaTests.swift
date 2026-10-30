import AVFoundation
import CoreVideo
import Foundation
import MeetingAudio
import MeetingCore
import Testing
@testable import MeetingMedia

@Suite("Video y exportación multimedia")
struct MediaTests {
    func paths() throws -> AppPaths {
        let paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mi-media-tests-\(UUID())"))
        try paths.prepare()
        return paths
    }

    func audio(_ paths: AppPaths, source: AudioSource, offset: Double = 0) throws -> AudioTrack {
        let url = paths.root.appendingPathComponent("\(source.rawValue).wav")
        let writer = try CrashSafeWAVWriter(url: url, sampleRate: 16_000)
        try writer.append([Float](repeating: 0.8, count: 16_000))
        try writer.close()
        return AudioTrack(meetingId: "fixture", source: source, relativePath: url.lastPathComponent,
                          sampleRate: 16_000, channelCount: 1, durationSeconds: 1, timelineOffsetSeconds: offset)
    }

    @Test func videoKeepsInitialOffsetAndStaticTailAndExportsWithMixedAudio() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let url = paths.root.appendingPathComponent("video.mov")
        let writer = try VideoFileWriter(url: url, width: 320, height: 180)
        try writer.appendBlack(at: 0)
        // A different source image starts late; retain the initial empty interval.
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
        let image = try #require(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 200, CVPixelBufferGetBytesPerRow(image) * 180)
        CVPixelBufferUnlockBaseAddress(image, [])
        try await Task.sleep(for: .milliseconds(30))
        #expect(try writer.append(image, at: 0.5))
        #expect(try writer.append(image, at: 0.4) == false)
        do { try await writer.finish(at: 1.5) }
        catch { throw MediaError.unavailable("Finalizar video de prueba: \(error.localizedDescription)") }
        let original = AVURLAsset(url: url)
        #expect(abs(try await original.load(.duration).seconds - 1.5) < 0.05)
        let generator = AVAssetImageGenerator(asset: original)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600)).image
        let late = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        #expect(early.dataProvider?.data != late.dataProvider?.data)
        let track = try audio(paths, source: .localMicrophone)
        let video = VideoAsset(meetingId: "fixture", relativePath: "video.mov", windowTitle: "FIXTURE", applicationName: "Test",
                               width: 320, height: 180, durationSeconds: 1.5, state: .ready)
        let exported = paths.root.appendingPathComponent("export.mp4")
        do { try await MeetingMediaExporter.export(tracks: [track], video: video, paths: paths, format: .mp4, to: exported) }
        catch { throw MediaError.unavailable("Exportar MP4 de prueba: \(error.localizedDescription)") }
        let result = AVURLAsset(url: exported)
        #expect(try await result.loadTracks(withMediaType: .video).count == 1)
        #expect(try await result.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await result.load(.duration).seconds - 1.5) < 0.1)
    }

    @Test func audioExportsMixTracksAtTheirOffsetsWithoutClipping() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let tracks = [try audio(paths, source: .localMicrophone), try audio(paths, source: .remoteSystemAudio, offset: 0.5)]
        let target = paths.root.appendingPathComponent("mixed.wav")
        try await MeetingMediaExporter.export(tracks: tracks, video: nil, paths: paths, format: .wav, to: target)
        let file = try AVAudioFile(forReading: target)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?.pointee)
        #expect(abs(Double(file.length) / 16_000 - 1.5) < 0.01)
        #expect(abs(samples[4_000] - 0.4) < 0.02)
        #expect(abs(samples[12_000] - 0.8) < 0.02)
        #expect(abs(samples[20_000] - 0.4) < 0.02)
        let m4a = paths.root.appendingPathComponent("mixed.m4a")
        try await MeetingMediaExporter.export(tracks: tracks, video: nil, paths: paths, format: .m4a, to: m4a)
        #expect(try await AVURLAsset(url: m4a).loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func failedOrCancelledExportPreservesDestinationAndOriginals() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let track = try audio(paths, source: .localMicrophone)
        let original = paths.resolve(relativePath: track.relativePath)
        let originalData = try Data(contentsOf: original)
        await #expect(throws: (any Error).self) {
            try await MeetingMediaExporter.export(tracks: [track], video: nil, paths: paths, format: .wav, to: original)
        }
        #expect(try Data(contentsOf: original) == originalData)
        let destination = paths.root.appendingPathComponent("kept.m4a")
        let marker = Data("previous export".utf8)
        try marker.write(to: destination)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MeetingMediaExporter.export(tracks: [track], video: nil, paths: paths, format: .m4a, to: destination)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: destination) == marker)
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.root.path).allSatisfy { !$0.hasPrefix(".mi-export-") })
        try FileManager.default.removeItem(at: original)
        await #expect(throws: (any Error).self) {
            try await MeetingMediaExporter.export(tracks: [track], video: nil, paths: paths, format: .m4a, to: destination)
        }
        #expect(try Data(contentsOf: destination) == marker)
    }

    @Test func caseVariantOrHardLinkedDestinationNeverReplacesAnOriginal() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let track = try audio(paths, source: .localMicrophone)
        let original = paths.resolve(relativePath: track.relativePath)
        let originalData = try Data(contentsOf: original)
        let caseSensitive = try paths.root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        let linked = paths.root.appendingPathComponent("linked-original.wav")
        #expect(link(original.path, linked.path) == 0)
        var destinations = [linked]
        if !caseSensitive { destinations.append(paths.root.appendingPathComponent(original.lastPathComponent.uppercased())) }
        for destination in destinations {
            for format in [MediaExportFormat.wav, .m4a] {
                await #expect(throws: MediaError.self) {
                    try await MeetingMediaExporter.export(tracks: [track], video: nil, paths: paths, format: format, to: destination)
                }
                #expect(try Data(contentsOf: original) == originalData)
                #expect(try Data(contentsOf: linked) == originalData)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.root.path).allSatisfy { !$0.hasPrefix(".mi-export-") })
        let separate = paths.root.appendingPathComponent("copy.wav")
        try FileManager.default.copyItem(at: original, to: separate)
        try await MeetingMediaExporter.export(tracks: [track], video: nil, paths: paths, format: .wav, to: separate)
        #expect(try Data(contentsOf: original) == originalData)
    }

    @Test func unfinishedPlayableVideoIsRecoveredAndMissingVideoIsMarkedFailed() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.open(paths: paths)
        let meeting = Meeting(title: "FIXTURE", origin: .recording, captureScope: .microphoneOnly, status: .interrupted)
        try db.insert(meeting: meeting, tracks: [])
        let url = paths.root.appendingPathComponent("video.mov")
        let writer = try VideoFileWriter(url: url, width: 320, height: 180)
        try writer.appendBlack(at: 0)
        try await writer.finish(at: 0.5)
        var video = VideoAsset(meetingId: meeting.id, relativePath: "video.mov", windowTitle: "Test", applicationName: "Test", width: 320, height: 180)
        try db.save(video: video)
        await VideoRecovery.recover(database: db, paths: paths)
        #expect(try db.video(meetingId: meeting.id)?.state == .interrupted)
        #expect(try db.video(meetingId: meeting.id)?.durationSeconds ?? 0 > 0.4)
        // A video remains viewable without audio after independent audio retention.
        let recovered = try #require(try db.video(meetingId: meeting.id))
        let media = try await MeetingMediaExporter.composition(tracks: [], video: recovered, paths: paths, strict: false)
        #expect(media.hasVideo && media.trackIDs.isEmpty)
        video.relativePath = "missing.mov"
        video.state = .recording
        try db.save(video: video)
        await VideoRecovery.recover(database: db, paths: paths)
        #expect(try db.video(meetingId: meeting.id)?.state == .failed)
    }

    @Test func videoMetadataMigratesPersistsAndCascadesOnDeletion() throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let db = try AppDatabase.open(paths: paths)
        let meeting = Meeting(title: "FIXTURE", origin: .recording, captureScope: .microphoneOnly, status: .recording)
        try db.insert(meeting: meeting, tracks: [])
        let video = VideoAsset(meetingId: meeting.id, relativePath: "Recordings/\(meeting.id)/video.mov", windowTitle: "Test",
                               applicationName: "Test", width: 320, height: 180)
        try db.save(video: video)
        #expect(try db.video(meetingId: meeting.id) == video)
        #expect(try db.meetingDetail(id: meeting.id)?.video == video)
        #expect(try db.unfinishedVideos().count == 1)
        try db.updateMeeting(id: meeting.id) { $0.status = .recorded }
        try db.deleteMeeting(id: meeting.id, paths: paths)
        #expect(try db.video(meetingId: meeting.id) == nil)
    }
}
