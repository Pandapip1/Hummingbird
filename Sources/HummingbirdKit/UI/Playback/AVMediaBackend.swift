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
    var duration: Double {
        guard let seconds = player?.currentItem?.duration.seconds, seconds.isFinite else { return 0 }
        return seconds
    }
    var isPlaying: Bool { (player?.rate ?? 0) > 0 }
    var tracks: [MediaTrack] {
        guard let item = player?.currentItem else { return [] }
        return item.asset.availableMediaCharacteristicsWithMediaSelectionOptions.flatMap { (characteristic) -> [MediaTrack] in
            guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else { return [] }
            let kind: MediaTrack.Kind
            switch characteristic {
            case AVMediaCharacteristic.visual: kind = .video
            case AVMediaCharacteristic.audible: kind = .audio
            case AVMediaCharacteristic.legible: kind = .subtitles
            default: return []
            }
            return group.options.enumerated().map { index, option in
                MediaTrack(id: "\(kind.rawValue)-\(index)", kind: kind,
                           language: option.locale?.identifier, label: option.displayName)
            }
        }
    }

    func selectTrack(_ track: MediaTrack?) {
        guard let item = player?.currentItem else { return }
        guard let track else {
            if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: AVMediaCharacteristic.legible) {
                item.select(nil, in: group)
            }
            return
        }
        let characteristic: AVMediaCharacteristic = switch track.kind {
        case .video: AVMediaCharacteristic.visual
        case .audio: AVMediaCharacteristic.audible
        case .subtitles: AVMediaCharacteristic.legible
        }
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic),
              let index = Int(track.id.split(separator: "-").last ?? "-1"),
              group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
    }

    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? {
        guard let item = player?.currentItem else { return nil }
        let characteristic: AVMediaCharacteristic = switch kind {
        case .video: AVMediaCharacteristic.visual
        case .audio: AVMediaCharacteristic.audible
        case .subtitles: AVMediaCharacteristic.legible
        }
        guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic),
              let selected = item.currentMediaSelection.selectedMediaOption(in: group),
              let index = group.options.firstIndex(where: { $0 === selected }) else { return nil }
        return tracks.first { $0.kind == kind && $0.id == "\(kind.rawValue)-\(index)" }
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
    func setPlaybackRate(_ rate: Float) { player?.rate = rate }
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

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = true
        controller.player = (model.backend as? AVMediaBackend)?.player
        context.coordinator.inlineController = controller
        context.coordinator.installPresenter()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = (model.backend as? AVMediaBackend)?.player
        context.coordinator.inlineController = controller
        context.coordinator.installPresenter()
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.dismissFullscreen(animated: false)
        coordinator.model?.removeFullscreenPresenter()
    }

    @MainActor
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var model: PlayerModel?
        weak var inlineController: AVPlayerViewController?
        private var fullscreenController: AVPlayerViewController?
        private var overlayController: UIViewController?

        init(model: PlayerModel) { self.model = model }

        func installPresenter() {
            model?.installFullscreenPresenter(
                present: { [weak self] in self?.presentFullscreen() },
                dismiss: { [weak self] in self?.dismissFullscreen(animated: true) }
            )
        }

        private func presentFullscreen() {
            guard fullscreenController == nil,
                  let model,
                  let inlineController,
                  let presenter = presentingController(from: inlineController) else { return }

            let controller = AVPlayerViewController()
            controller.player = (model.backend as? AVMediaBackend)?.player
            controller.showsPlaybackControls = false
            controller.allowsPictureInPicturePlayback = true
            controller.modalPresentationStyle = .fullScreen

            guard let container = controller.contentOverlayView else { return }
            let overlay = UIHostingController(rootView: FullscreenPlayerControls(model: model))
            overlay.view.backgroundColor = .clear
            controller.addChild(overlay)
            overlay.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(overlay.view)
            NSLayoutConstraint.activate([
                overlay.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                overlay.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                overlay.view.topAnchor.constraint(equalTo: container.topAnchor),
                overlay.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            overlay.didMove(toParent: controller)

            fullscreenController = controller
            overlayController = overlay
            inlineController.player = nil
            model.fullscreenDidChange(true)
            presenter.present(controller, animated: true)
            controller.presentationController?.delegate = self
        }

        func dismissFullscreen(animated: Bool) {
            guard let controller = fullscreenController else {
                model?.fullscreenDidChange(false)
                return
            }
            controller.dismiss(animated: animated) { [weak self] in self?.finishDismissal() }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finishDismissal()
        }

        private func finishDismissal() {
            overlayController?.willMove(toParent: nil)
            overlayController?.view.removeFromSuperview()
            overlayController?.removeFromParent()
            overlayController = nil
            fullscreenController = nil
            inlineController?.player = (model?.backend as? AVMediaBackend)?.player
            model?.fullscreenDidChange(false)
        }

        private func presentingController(from controller: UIViewController) -> UIViewController? {
            var presenter = controller.view.window?.rootViewController
            while let presented = presenter?.presentedViewController { presenter = presented }
            return presenter
        }
    }
}

@MainActor
private struct FullscreenPlayerControls: View {
    let model: PlayerModel
    var body: some View {
        PlayerControls(model: model, isFullscreen: true)
            .frame(maxHeight: .infinity, alignment: .bottom)
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
