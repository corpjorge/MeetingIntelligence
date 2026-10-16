import AVFoundation
import MeetingCore

/// Plays all tracks of a meeting in sync (one AVComposition) with per-source mute.
@Observable
final class MeetingAudioPlayer {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isLoaded = false
    private(set) var loadError: String?
    private(set) var availableSources: [AudioSource] = []
    var mutedSources: Set<AudioSource> = [] { didSet { applyMix() } }
    var rate: Float = 1 { didSet { if isPlaying { player?.rate = rate } } }

    private var player: AVPlayer?
    private var trackIDs: [AudioSource: CMPersistentTrackID] = [:]
    private var composition: AVMutableComposition?
    private var timeObserver: Any?
    private var loadedKey: String?

    func load(tracks: [AudioTrack], paths: AppPaths) async {
        let key = tracks.map { "\($0.id):\($0.relativePath)" }.sorted().joined()
        guard key != loadedKey else { return }
        loadedKey = key
        stop()
        let composition = AVMutableComposition()
        var ids: [AudioSource: CMPersistentTrackID] = [:]
        var missing: [String] = []
        for track in tracks {
            let url = paths.resolve(relativePath: track.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing.append(track.source.rawValue)
                continue
            }
            let asset = AVURLAsset(url: url)
            do {
                guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                      let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                let assetDuration = try await asset.load(.duration)
                try target.insertTimeRange(CMTimeRange(start: .zero, duration: assetDuration), of: source,
                                           at: CMTime(seconds: track.timelineOffsetSeconds, preferredTimescale: 600))
                ids[track.source] = target.trackID
            } catch {
                missing.append(track.source.rawValue)
            }
        }
        self.composition = composition
        trackIDs = ids
        availableSources = ids.keys.sorted { $0.rawValue < $1.rawValue }
        guard !ids.isEmpty else {
            loadError = tracks.isEmpty ? "La reunión no tiene audio." :
                "El audio no está disponible (se eliminó por la política de conservación o falta el archivo)."
            isLoaded = false
            return
        }
        loadError = missing.isEmpty ? nil : "Pistas no disponibles: \(missing.joined(separator: ", "))"
        let item = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        self.player = player
        duration = composition.duration.seconds
        applyMix()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds
                if self.isPlaying, self.player?.rate == 0 { self.isPlaying = false }
            }
        }
        isLoaded = true
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double, play: Bool = false) {
        guard let player else { return }
        let clamped = max(0, min(seconds, duration))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        if play { self.play() }
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }

    func stop() {
        pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        isLoaded = false
        currentTime = 0
    }

    private func applyMix() {
        guard let item = player?.currentItem, let composition else { return }
        let mix = AVMutableAudioMix()
        mix.inputParameters = composition.tracks(withMediaType: .audio).map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            let source = trackIDs.first { $0.value == track.trackID }?.key
            params.setVolume(source.map { mutedSources.contains($0) ? 0 : 1 } ?? 1, at: .zero)
            return params
        }
        item.audioMix = mix
    }
}
