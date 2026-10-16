public import Foundation
import AVFoundation
public import MeetingCore

public struct AudioFileInfo: Sendable, Hashable {
    public var durationSeconds: Double
    public var sampleRate: Double
    public var channelCount: Int
    public var formatDescription: String
}

public enum AudioImportError: LocalizedError, Sendable {
    case unsupportedType(String)
    case noAudioTrack
    case unreadable(String)
    case exportFailed(String)
    case tooShort

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext): "Formato no soportado: .\(ext). Usa WAV, M4A, MP3 o MP4."
        case .noAudioTrack: "El archivo no contiene una pista de audio."
        case .unreadable(let detail): "No se pudo leer el audio: \(detail)"
        case .exportFailed(let detail): "No se pudo extraer el audio del contenedor: \(detail)"
        case .tooShort: "El audio es demasiado corto para transcribirlo (mínimo 1 segundo)."
        }
    }
}

/// Imports external recordings into the library.
///
/// WAV/M4A/MP3/AIFF/CAF are copied byte-for-byte (originals preserved).
/// MP4/MOV containers have their audio extracted to M4A with AVFoundation.
public struct AudioImporter: Sendable {
    public static let directlyReadable: Set<String> = ["wav", "wave", "m4a", "mp3", "aif", "aiff", "caf", "aac", "flac"]
    public static let containers: Set<String> = ["mp4", "mov", "m4v"]
    public static var supportedExtensions: Set<String> { directlyReadable.union(containers) }

    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public static func inspect(_ url: URL) throws -> AudioFileInfo {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.fileFormat
            let rate = format.sampleRate
            return AudioFileInfo(durationSeconds: rate > 0 ? Double(file.length) / rate : 0,
                                 sampleRate: rate, channelCount: Int(format.channelCount),
                                 formatDescription: url.pathExtension.uppercased())
        } catch {
            throw AudioImportError.unreadable(error.localizedDescription)
        }
    }

    /// Copies or extracts `source` into the meeting folder and returns the track to persist.
    public func importFile(_ source: URL, meetingId: String) async throws -> AudioTrack {
        let ext = source.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { throw AudioImportError.unsupportedType(ext) }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let dir = try paths.prepareMeetingDirectory(meetingId)
        let destination: URL
        if Self.containers.contains(ext) {
            destination = dir.appendingPathComponent("imported.m4a")
            try await extractAudio(from: source, to: destination)
        } else {
            destination = dir.appendingPathComponent("imported.\(ext)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)

        let info = try Self.inspect(destination)
        guard info.durationSeconds >= 1 else {
            try? FileManager.default.removeItem(at: destination)
            throw AudioImportError.tooShort
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return AudioTrack(meetingId: meetingId, source: .imported,
                          relativePath: paths.relativePath(for: destination) ?? destination.lastPathComponent,
                          originalFileName: source.lastPathComponent,
                          sampleRate: info.sampleRate, channelCount: info.channelCount,
                          durationSeconds: info.durationSeconds,
                          captureDetail: "Importado desde \(source.lastPathComponent) (\(info.formatDescription))",
                          fileSizeBytes: size)
    }

    private func extractAudio(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw AudioImportError.noAudioTrack }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioImportError.exportFailed("preset M4A no disponible")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw AudioImportError.exportFailed(error.localizedDescription)
        }
    }
}
