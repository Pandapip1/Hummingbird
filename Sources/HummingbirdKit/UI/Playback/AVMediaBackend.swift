#if canImport(AVFoundation)
import Foundation
import AVFoundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AVKit)
import AVKit
#endif

@MainActor
final class AVMediaBackend: MediaBackend {
    private(set) var player: AVPlayer?
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    private var timeObserver: Any?
    private var itemObserver: NSObjectProtocol?

    var currentTime: Double { player?.currentTime().seconds ?? 0 }
    var isPlaying: Bool { (player?.rate ?? 0) > 0 }
    var tracks: [MediaTrack] {
        guard let item = player?.currentItem else { return [] }
        return item.asset.availableMediaCharacteristicsWithMediaSelectionOptions.flatMap { characteristic in
            guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else { return [] }
            let kind: MediaTrack.Kind
            switch characteristic {
            case AVMediaCharacteristicVisual: kind = .video
            case AVMediaCharacteristicAudible: kind = .audio
            case AVMediaCharacteristicLegible: kind = .subtitles
            default: return []
            }
            return group.options.enumerated().map { index, option in
                MediaTrack(id: "\(kind.rawValue)-\(index)", kind: kind,
                           language: option.locale?.identifier, label: option.displayName)
            }
        }
    }

    func selectTrack(_ track: MediaTrack?) {
        guard let track, let item = player?.currentItem else { return }
        let characteristic: AVMediaCharacteristic = switch track.kind {
        case .video: AVMediaCharacteristicVisual
        case .audio: AVMediaCharacteristicAudible
        case .subtitles: AVMediaCharacteristicLegible
        }
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic),
              let index = Int(track.id.split(separator: "-").last ?? "-1"),
              group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
    }

    func canPlay(_ option: PlaybackOption) -> Bool { true }

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        let item = try await makeItem(for: request)
        removeObservers()
        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        player = p
        if let resumeAt, resumeAt > 0 {
            await p.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.onTick?(time.seconds) }
        }
        itemObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onEnded?() }
        }
        if autoplay { p.play() }
    }

    func play() { player?.play() }
    func pause() { player?.pause() }
    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }

    func stop() {
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func removeObservers() {
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let o = itemObserver { NotificationCenter.default.removeObserver(o); itemObserver = nil }
    }

    // MARK: building items

    private func asset(for media: ResolvedMedia) -> AVURLAsset {
        // This option key is not exposed in the public headers but is the long-standing way to set request headers.
        let options: [String: Any]? = media.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": media.headers]
        return AVURLAsset(url: media.url, options: options)
    }

    private func makeItem(for request: PlayRequest) async throws -> AVPlayerItem {
        let videoAsset = asset(for: request.video)
        guard let audioMedia = request.audio else { return AVPlayerItem(asset: videoAsset) }

        // Separate video and audio files are combined into one composition so AVPlayer plays them in sync.
        let audioAsset = asset(for: audioMedia)
        let composition = AVMutableComposition()
        let vDuration = try await videoAsset.load(.duration)
        let aDuration = try await audioAsset.load(.duration)
        let duration = CMTimeMinimum(vDuration, aDuration)
        guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let aTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let vOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw PluginError.execution("Could not combine the video and audio streams") }
        let range = CMTimeRange(start: .zero, duration: duration)
        try vOut.insertTimeRange(range, of: vTrack, at: .zero)
        try aOut.insertTimeRange(range, of: aTrack, at: .zero)
        vOut.preferredTransform = (try? await vTrack.load(.preferredTransform)) ?? .identity
        return AVPlayerItem(asset: composition)
    }
}

#if canImport(AVKit) && canImport(SwiftUI) && (os(iOS) || os(tvOS))
/// AVKit's SwiftUI `VideoPlayer` always supplies its own controls. Wrap the
/// underlying view controller so Hummingbird can provide one shared control
/// surface on Apple and GTK.
@MainActor
struct PlayerSurface: UIViewControllerRepresentable {
    let model: PlayerModel

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = true
        controller.player = (model.backend as? AVMediaBackend)?.player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = (model.backend as? AVMediaBackend)?.player
    }
}
#elseif canImport(AVKit) && canImport(SwiftUI) && os(macOS)
@MainActor
struct PlayerSurface: NSViewRepresentable {
    let model: PlayerModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = (model.backend as? AVMediaBackend)?.player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = (model.backend as? AVMediaBackend)?.player
    }
}
#endif

@MainActor
func makeMediaBackend() -> MediaBackend { AVMediaBackend() }
#endif
