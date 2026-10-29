@preconcurrency public import AVFoundation
import Darwin
public import Foundation
import MeetingAudio
public import MeetingCore

public enum MediaExportFormat: String, Sendable, CaseIterable, Identifiable {
    case m4a, wav, mp4
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .m4a: "Exportar audio (M4A)…"
        case .wav: "Exportar audio (WAV)…"
        case .mp4: "Exportar video (MP4)…"
        }
    }
}

/// Immutable after construction. AVFoundation compositions are built off the UI
/// actor, then only read by playback/export; no mutable reference escapes.
public struct MeetingMediaComposition: @unchecked Sendable {
    public let asset: AVComposition
    public let audioMix: AVAudioMix
    public let trackIDs: [AudioSource: CMPersistentTrackID]
    public let hasVideo: Bool
}

/// AVAssetExportSession supports observing state and cancellation during export.
private final class ExportSessionHandle: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

public enum MeetingMediaExporter {
    public static func composition(tracks: [AudioTrack], video: VideoAsset?, paths: AppPaths,
                                   strict: Bool = true) async throws -> MeetingMediaComposition {
        let composition = AVMutableComposition()
        var ids: [AudioSource: CMPersistentTrackID] = [:]
        for track in tracks {
            try Task.checkCancellation()
            let url = paths.resolve(relativePath: track.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if strict { throw MediaError.unavailable("Falta una pista de audio. Puede haber sido eliminada por la política de conservación.") }
                continue
            }
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw MediaError.unavailable("No se pudo leer una pista de audio.") }
            let duration = try await asset.load(.duration)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source,
                                       at: CMTime(seconds: max(0, track.timelineOffsetSeconds), preferredTimescale: 60_000))
            ids[track.source] = target.trackID
        }
        var hasVideo = false
        if let video, video.state == .ready || video.state == .interrupted {
            do {
            let url = paths.resolve(relativePath: video.relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                if let source = try await asset.loadTracks(withMediaType: .video).first,
                   let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let range = try await source.load(.timeRange)
                    try target.insertTimeRange(range, of: source, at: range.start)
                    target.preferredTransform = try await source.load(.preferredTransform)
                    hasVideo = true
                }
            }
            if strict && !hasVideo { throw MediaError.unavailable("El archivo de video no está disponible.") }
            } catch {
                if strict { throw error }
            }
        } else if video != nil && strict {
            throw MediaError.unavailable("El video todavía no está listo para exportar.")
        }
        guard !ids.isEmpty || (!strict && hasVideo) else {
            throw MediaError.unavailable("El audio de esta grabación no está disponible.")
        }
        let mix = AVMutableAudioMix()
        let gain = 1 / Float(max(1, ids.count))
        mix.inputParameters = composition.tracks(withMediaType: .audio).map {
            let input = AVMutableAudioMixInputParameters(track: $0)
            input.setVolume(gain, at: .zero)
            return input
        }
        return MeetingMediaComposition(asset: composition, audioMix: mix, trackIDs: ids, hasVideo: hasVideo)
    }

    public static func export(tracks: [AudioTrack], video: VideoAsset?, paths: AppPaths,
                              format: MediaExportFormat, to destination: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let sources = tracks.map { paths.resolve(relativePath: $0.relativePath).standardizedFileURL.resolvingSymlinksInPath() }
            + (video.map { [paths.resolve(relativePath: $0.relativePath).standardizedFileURL.resolvingSymlinksInPath()] } ?? [])
        guard !sources.contains(destination.standardizedFileURL.resolvingSymlinksInPath()) else {
            throw MediaError.unavailable("El destino no puede reemplazar un archivo original de la reunión.")
        }
        if format == .mp4, video == nil { throw MediaError.unavailable("Esta reunión se grabó solo con audio.") }
        let media = try await composition(tracks: tracks, video: format == .mp4 ? video : nil, paths: paths)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".mi-export-\(UUID().uuidString).\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        progress(0)
        if format == .wav {
            try await exportWAV(media, to: temporary, progress: progress)
        } else {
            let preset = format == .m4a ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
            guard let session = AVAssetExportSession(asset: media.asset, presetName: preset) else {
                throw MediaError.unavailable("No se pudo preparar la exportación.")
            }
            let handle = ExportSessionHandle(session)
            handle.session.audioMix = media.audioMix
            handle.session.shouldOptimizeForNetworkUse = true
            let reporter = Task {
                for await state in handle.session.states(updateInterval: 0.2) {
                    if case .exporting(let value) = state { progress(value.fractionCompleted) }
                }
            }
            defer { reporter.cancel() }
            try await withTaskCancellationHandler {
                try await handle.session.export(to: temporary, as: format == .m4a ? .m4a : .mp4)
            } onCancel: {
                handle.session.cancelExport()
            }
        }
        try Task.checkCancellation()
        // Same-directory rename publishes the complete export atomically, including replacement.
        guard rename(temporary.path, destination.path) == 0 else {
            throw MediaError.unavailable("No se pudo guardar la exportación en el destino elegido.")
        }
        progress(1)
    }

    private static func exportWAV(_ media: MeetingMediaComposition, to url: URL,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: media.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: media.asset.tracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = media.audioMix
        guard reader.canAdd(output) else { throw MediaError.unavailable("No se pudo preparar la mezcla WAV.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaError.unavailable("No se pudo leer el audio.") }
        defer { reader.cancelReading() }
        let writer = try CrashSafeWAVWriter(url: url, sampleRate: 16_000)
        defer { try? writer.close() }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = sample.dataBuffer else { throw MediaError.unavailable("El audio contiene un bloque ilegible.") }
            var floats = [Float](repeating: 0, count: sample.numSamples)
            let status = floats.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw MediaError.unavailable("No se pudo convertir el audio.") }
            let position = Int64((sample.presentationTimeStamp.seconds * 16_000).rounded())
            if position > writer.framesWritten { try writer.appendSilence(frames: Int(position - writer.framesWritten)) }
            let overlap = max(0, Int(writer.framesWritten - position))
            if overlap < floats.count { try writer.append(Array(floats.dropFirst(overlap))) }
            count += 1
            if count.isMultiple(of: 32) {
                progress(min(0.99, writer.durationSeconds / max(0.01, media.asset.duration.seconds)))
                await Task.yield()
            }
        }
        guard reader.status == .completed else { throw reader.error ?? MediaError.unavailable("La exportación de audio se interrumpió.") }
        try writer.close()
    }
}
