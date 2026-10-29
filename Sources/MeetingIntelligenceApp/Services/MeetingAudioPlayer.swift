import AVFoundation
import MeetingCore
import MeetingMedia

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
    private(set) var hasVideo = false
    var videoPlayer: AVPlayer? { hasVideo ? player : nil }
    private var trackIDs: [AudioSource: CMPersistentTrackID] = [:]
    private var composition: AVComposition?
    private var timeObserver: Any?
    private var loadedKey: String?
    private var loadGeneration = UUID()

    func load(tracks: [AudioTrack], paths: AppPaths, video: VideoAsset? = nil) async {
        let key = tracks.map { "\($0.id):\($0.relativePath)" }.sorted().joined() + (video.map { "\($0.relativePath):\($0.state):\($0.durationSeconds)" } ?? "")
        guard key != loadedKey else { return }
        stop()
        loadGeneration = UUID()
        let generation = loadGeneration
        let media: MeetingMediaComposition
        do {
            media = try await MeetingMediaExporter.composition(tracks: tracks, video: video, paths: paths, strict: false)
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            loadError = error.localizedDescription
            isLoaded = false
            return
        }
        guard !Task.isCancelled, generation == loadGeneration else { return }
        loadedKey = key
        let composition = media.asset
        self.composition = composition
        trackIDs = media.trackIDs
        availableSources = media.trackIDs.keys.sorted { $0.rawValue < $1.rawValue }
        hasVideo = media.hasVideo
        var notices: [String] = []
        if video != nil && !media.hasVideo { notices.append("El video no está disponible; puedes escuchar el audio.") }
        if media.trackIDs.count < tracks.count { notices.append("Faltan pistas de audio; pueden haber sido eliminadas por la política de conservación.") }
        loadError = notices.isEmpty ? nil : notices.joined(separator: " ")
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
        loadedKey = nil
        isLoaded = false
        hasVideo = false
        currentTime = 0
    }

    private func applyMix() {
        guard let item = player?.currentItem, let composition else { return }
        let mix = AVMutableAudioMix()
        mix.inputParameters = composition.tracks(withMediaType: .audio).map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            let source = trackIDs.first { $0.value == track.trackID }?.key
            params.setVolume(source.map { mutedSources.contains($0) ? 0 : 1 / Float(max(1, trackIDs.count)) } ?? 1, at: .zero)
            return params
        }
        item.audioMix = mix
    }
}
