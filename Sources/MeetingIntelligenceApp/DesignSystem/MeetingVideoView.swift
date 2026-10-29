import AVKit
import SwiftUI

/// Uses AVPlayerView directly, avoiding the SwiftUI VideoPlayer overlay's
/// runtime superclass lookup with the CLT 26.5 SDK on newer macOS releases.
/// Transport stays in PlayerBar so video and citation seeking share one state.
struct MeetingVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
