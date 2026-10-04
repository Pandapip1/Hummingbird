#if !canImport(AVFoundation)
import Foundation
@_spi(SwiftOpenUIBackend) import SwiftOpenUI

/// Non-Apple playback through the fork's `AVPlayer` / `VideoPlayer` compatibility implementation.
///
/// The direct GStreamer pipeline supports muxed/adaptive media and independent
/// video and audio streams. Sources requiring custom HTTP headers remain unavailable.
@MainActor
final class GTKMediaBackend: MediaBackend {
    let player = AVPlayer()
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    private var ticker: Task<Void, Never>?
    private var pictureInPictureController: AVPictureInPictureController?

    var currentTime: Double { player.currentTime().seconds }
    var isPlaying: Bool { player.rate > 0 }
    var pictureInPictureSupported: Bool { true }

    init() {
        player._swiftOpenUIOnEnded = { [weak self] in Task { @MainActor in self?.onEnded?() } }
        player._swiftOpenUIOnFailure = { [weak self] message in
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
        let item = try await makeItem(videoURL: request.video.url, audioURL: request.audio?.url)
        player.replaceCurrentItem(with: item)
        if let resumeAt, resumeAt > 0 {
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        }
        if autoplay { player.play() } else { player.pause() }
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.onTick?(self.player.currentTime().seconds)
            }
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    func startPictureInPicture() {
        if pictureInPictureController == nil {
            pictureInPictureController = AVPictureInPictureController(playerLayer: AVPlayerLayer(player: player))
        }
        pictureInPictureController?.startPictureInPicture()
    }
    func stopPictureInPicture() {
        pictureInPictureController?.stopPictureInPicture()
        pictureInPictureController = nil
    }
    func stop() {
        ticker?.cancel(); ticker = nil
        stopPictureInPicture()
        player.pause(); player.replaceCurrentItem(with: nil)
    }

    private func makeItem(videoURL: URL, audioURL: URL?) async throws -> AVPlayerItem {
        guard let audioURL else { return AVPlayerItem(url: videoURL) }
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw PluginError.notSupported("The selected sources do not contain video and audio tracks")
        }
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero,
                                duration: CMTime(seconds: 24 * 60 * 60, preferredTimescale: 600))
        try composition.addMutableTrack(withMediaType: .video,
                                        preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: sourceVideo, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio,
                                        preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: sourceAudio, at: .zero)
        return AVPlayerItem(asset: composition)
    }
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
