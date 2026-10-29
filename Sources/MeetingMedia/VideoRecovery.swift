import AVFoundation
import Foundation
public import MeetingCore

public enum VideoRecovery {
    /// Fragmented masters survive independently of WAV registration and ASR.
    public static func recover(database: AppDatabase, paths: AppPaths) async {
        guard let videos = try? database.unfinishedVideos() else { return }
        for var video in videos {
            let url = paths.resolve(relativePath: video.relativePath)
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0,
                      !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw MediaError.unavailable("Video incompleto") }
                video.durationSeconds = duration
                video.fileSizeBytes = StorageMaintenance.size(of: url)
                video.state = .interrupted
            } catch {
                video.state = .failed
            }
            try? database.save(video: video)
        }
    }
}
