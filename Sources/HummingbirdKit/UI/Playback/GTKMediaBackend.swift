#if !canImport(AVFoundation)
import Foundation
import SwiftOpenUI

/// Non-Apple playback through the fork's `MediaPlayer` / `VideoPlayer` (GtkVideo → GStreamer).
///
/// Limits, all imposed by GtkVideo: it cannot send custom HTTP headers and cannot join separate audio and video
/// files. So only sources that need no `requestModifier` and are a single muxed file, HLS or live stream are offered.
@MainActor
final class GTKMediaBackend: MediaBackend {
    let player = MediaPlayer()
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    private var ticker: Task<Void, Never>?

    var currentTime: Double { player.currentTime }
    var isPlaying: Bool { player.isPlaying }

    init() {
        player.onEnded = { [weak self] in Task { @MainActor in self?.onEnded?() } }
        player.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.ticker?.cancel()
                self?.onFailure?(message)
            }
        }
    }

    func canPlay(_ option: PlaybackOption) -> Bool {
        option.audio == nil && option.video.requestModifier == nil
    }

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        guard request.audio == nil, request.video.headers.isEmpty else {
            throw PluginError.notSupported("This source needs custom request headers or separate audio, which the GTK player cannot do")
        }
        player.open(request.video.url, autoplay: autoplay, startAt: resumeAt ?? 0)
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.onTick?(self.player.currentTime)
            }
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to seconds: Double) { player.seek(to: seconds) }
    func stop() { ticker?.cancel(); ticker = nil; player.stop() }
}

@MainActor
func makeMediaBackend() -> MediaBackend { GTKMediaBackend() }

@MainActor
struct PlayerSurface: View {
    let model: PlayerModel
    var body: some View {
        if let p = (model.backend as? GTKMediaBackend)?.player {
            VideoPlayer(player: p).frame(height: 240)
        } else {
            Color.black.frame(height: 240)
        }
    }
}
#endif
