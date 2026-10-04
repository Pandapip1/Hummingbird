#if !canImport(AVFoundation)
import Foundation
import SwiftOpenUI

/// Non-Apple playback through the fork's `MediaPlayer` / `VideoPlayer` (GtkVideo → GStreamer).
///
/// The direct GStreamer pipeline supports muxed/adaptive media and independent
/// video and audio streams. Sources requiring custom HTTP headers remain unavailable.
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
        option.video.requestModifier == nil && option.audio?.requestModifier == nil
    }

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        guard request.video.headers.isEmpty, request.audio?.headers.isEmpty != false else {
            throw PluginError.notSupported("This source needs custom request headers, which the GTK player cannot use yet")
        }
        let asset = request.audio.map { MediaAsset(videoURL: request.video.url, audioURL: $0.url) }
            ?? MediaAsset(url: request.video.url)
        player.replaceCurrentItem(with: MediaPlayerItem(asset: asset))
        if let resumeAt, resumeAt > 0 { player.seek(to: resumeAt) }
        if autoplay { player.play() } else { player.pause() }
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
    func setExternalSubtitle(_ url: URL?) { player.setExternalSubtitle(url) }
    func stop() { ticker?.cancel(); ticker = nil; player.stop() }
}

@MainActor
func makeMediaBackend() -> MediaBackend { GTKMediaBackend() }

@MainActor
struct PlayerSurface: View {
    let model: PlayerModel
    var body: some View {
        if let p = (model.backend as? GTKMediaBackend)?.player {
            VideoPlayer(player: p)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.black.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
