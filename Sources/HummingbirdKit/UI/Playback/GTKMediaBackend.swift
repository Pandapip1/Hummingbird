#if !canImport(AVFoundation)
import Foundation
@_spi(SwiftOpenUIBackend) import SwiftOpenUI
import AdvancedVideoPlayerKit

/// Non-Apple playback through the fork's `AVPlayer` / `VideoPlayer` compatibility implementation.
///
/// The direct GStreamer pipeline supports muxed/adaptive media and independent
/// video and audio streams, including per-stream HTTP request headers.
@MainActor
final class GTKMediaBackend: MediaBackend {
    let player = AVPlayer()
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    private var ticker: Task<Void, Never>?
    private var pictureInPictureController: AVPictureInPictureController?
    private var mediaSelectionGroups: [AVMediaCharacteristic: AVMediaSelectionGroup] = [:]
    private var mediaSelectionRefreshTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var activeLoadGenerations: Set<Int> = []
    private var committedLoadGeneration: Int?
    private var invalidatedThroughGeneration = 0
    private var loadCompletionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var mediaSelectionRefreshGeneration = 0
    private let itemFactory: (@MainActor (ResolvedMedia, ResolvedMedia?) async throws -> AVPlayerItem)?
    private let didInstallItem: (@MainActor (AVPlayerItem) async throws -> Void)?

    var currentTime: Double { player.currentTime().seconds }
    var duration: Double { player._swiftOpenUIDuration.seconds }
    var isPlaying: Bool { player.rate > 0 }
    var pictureInPictureSupported: Bool { true }
    var tracks: [MediaTrack] {
        if let asset = player.currentItem?.asset {
            asset._swiftOpenUIRefreshMediaSelectionGroups?()
            scheduleMediaSelectionGroupRefresh(for: asset)
        }
        return [AVMediaCharacteristic.visual, .audible, .legible].flatMap { characteristic -> [MediaTrack] in
            guard let group = mediaSelectionGroups[characteristic] else { return [] }
            let kind: MediaTrack.Kind
            switch characteristic {
            case .visual: kind = .video
            case .audible: kind = .audio
            case .legible: kind = .subtitles
            default: return []
            }
            return group.options.enumerated().map { index, option in
                MediaTrack(id: "\(kind.rawValue)-\(index)", kind: kind,
                           language: option.locale?.identifier, label: option.displayName)
            }
        }
    }

    init(
        itemFactory: (@MainActor (ResolvedMedia, ResolvedMedia?) async throws -> AVPlayerItem)? = nil,
        didInstallItem: (@MainActor (AVPlayerItem) async throws -> Void)? = nil
    ) {
        self.itemFactory = itemFactory
        self.didInstallItem = didInstallItem
        player._swiftOpenUIOnEnded = { [weak self] in Task { @MainActor in self?.onEnded?() } }
        player._swiftOpenUIOnFailure = { [weak self] message in
            Task { @MainActor in
                self?.ticker?.cancel()
                self?.onFailure?(message)
            }
        }
    }

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        loadGeneration &+= 1
        let generation = loadGeneration
        activeLoadGenerations.insert(generation)
        var committedAsset: AVAsset?
        defer {
            if Task.isCancelled, let committedAsset {
                cancelCommittedLoad(generation, asset: committedAsset)
            }
            finishLoad(generation)
        }
        mediaSelectionRefreshTask?.cancel()
        mediaSelectionRefreshTask = nil
        mediaSelectionRefreshGeneration &+= 1
        let item: AVPlayerItem
        do {
            if let itemFactory {
                item = try await itemFactory(request.video, request.audio)
            } else {
                item = try await makeItem(video: request.video, audio: request.audio)
            }
        } catch {
            if hasNewerCommittedLoad(than: generation) { throw MediaBackendLoadError.superseded }
            throw error
        }
        try Task.checkCancellation()
        try await waitForNewerLoads(than: generation)
        try Task.checkCancellation()
        guard canCommitLoad(generation) else { throw MediaBackendLoadError.superseded }
        player.replaceCurrentItem(with: item)
        committedLoadGeneration = generation
        committedAsset = item.asset
        mediaSelectionGroups = [:]
        if let didInstallItem { try await didInstallItem(item) }
        try Task.checkCancellation()
        item.asset._swiftOpenUIRefreshMediaSelectionGroups?()
        try await refreshMediaSelectionGroups(for: item.asset, generation: generation)
        try Task.checkCancellation()
        try await waitForNewerLoads(than: generation)
        try Task.checkCancellation()
        guard isCurrentLoad(generation, asset: item.asset) else { throw MediaBackendLoadError.superseded }
        if let resumeAt, resumeAt > 0 {
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
            try Task.checkCancellation()
            try await waitForNewerLoads(than: generation)
            try Task.checkCancellation()
            guard isCurrentLoad(generation, asset: item.asset) else { throw MediaBackendLoadError.superseded }
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
    func setPlaybackRate(_ rate: Float) { player.rate = rate }
    func selectTrack(_ track: MediaTrack?) {
        guard let item = player.currentItem else { return }
        let characteristic: AVMediaCharacteristic
        if let track {
            characteristic = switch track.kind {
            case .video: .visual
            case .audio: .audible
            case .subtitles: .legible
            }
        } else {
            characteristic = .legible
        }
        guard let group = mediaSelectionGroups[characteristic] else { return }
        guard let track else { item.select(nil, in: group); return }
        guard let index = Int(track.id.split(separator: "-").last ?? "-1"),
              group.options.indices.contains(index) else { return }
        item.select(group.options[index], in: group)
    }
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? {
        guard let item = player.currentItem else { return nil }
        let characteristic: AVMediaCharacteristic = switch kind {
        case .video: .visual
        case .audio: .audible
        case .subtitles: .legible
        }
        guard let group = mediaSelectionGroups[characteristic],
              let selected = item.currentMediaSelection.selectedMediaOption(in: group),
              let index = group.options.firstIndex(where: { $0 === selected }) else { return nil }
        return tracks.first { $0.kind == kind && $0.id == "\(kind.rawValue)-\(index)" }
    }
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
        loadGeneration &+= 1
        invalidatedThroughGeneration = loadGeneration
        activeLoadGenerations.removeAll()
        committedLoadGeneration = nil
        resumeLoadCompletionWaiters()
        ticker?.cancel(); ticker = nil
        mediaSelectionRefreshTask?.cancel(); mediaSelectionRefreshTask = nil
        mediaSelectionRefreshGeneration &+= 1
        stopPictureInPicture()
        player.pause(); player.replaceCurrentItem(with: nil)
        mediaSelectionGroups = [:]
    }

    private func isCurrentLoad(_ generation: Int, asset: AVAsset) -> Bool {
        committedLoadGeneration == generation && player.currentItem?.asset === asset
    }

    private func cancelCommittedLoad(_ generation: Int, asset: AVAsset) {
        guard isCurrentLoad(generation, asset: asset) else { return }
        ticker?.cancel()
        ticker = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        mediaSelectionGroups = [:]
        committedLoadGeneration = nil
    }

    private func canCommitLoad(_ generation: Int) -> Bool {
        generation > invalidatedThroughGeneration
            && !hasNewerCommittedLoad(than: generation)
            && !activeLoadGenerations.contains(where: { $0 > generation })
    }

    private func hasNewerCommittedLoad(than generation: Int) -> Bool {
        (committedLoadGeneration ?? 0) > generation
    }

    private func waitForNewerLoads(than generation: Int) async throws {
        while activeLoadGenerations.contains(where: { $0 > generation }) {
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || !activeLoadGenerations.contains(where: { $0 > generation }) {
                        continuation.resume()
                    } else {
                        loadCompletionWaiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.resumeLoadCompletionWaiter(id) }
            }
            try Task.checkCancellation()
        }
    }

    private func finishLoad(_ generation: Int) {
        activeLoadGenerations.remove(generation)
        resumeLoadCompletionWaiters()
    }

    private func resumeLoadCompletionWaiters() {
        let waiters = loadCompletionWaiters
        loadCompletionWaiters.removeAll()
        waiters.values.forEach { $0.resume() }
    }

    private func resumeLoadCompletionWaiter(_ id: UUID) {
        loadCompletionWaiters.removeValue(forKey: id)?.resume()
    }

    private func refreshMediaSelectionGroups(for asset: AVAsset, generation: Int) async throws {
        do {
            let characteristics = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
            try Task.checkCancellation()
            var groups: [AVMediaCharacteristic: AVMediaSelectionGroup] = [:]
            for characteristic in characteristics {
                if let group = try await asset.loadMediaSelectionGroup(for: characteristic) {
                    groups[characteristic] = group
                }
                try Task.checkCancellation()
            }
            guard isCurrentLoad(generation, asset: asset) else { return }
            mediaSelectionGroups = groups
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isCurrentLoad(generation, asset: asset) else { return }
            mediaSelectionGroups = [:]
        }
    }

    private func scheduleMediaSelectionGroupRefresh(for asset: AVAsset) {
        guard mediaSelectionRefreshTask == nil else { return }
        let generation = loadGeneration
        mediaSelectionRefreshGeneration &+= 1
        let refreshGeneration = mediaSelectionRefreshGeneration
        mediaSelectionRefreshTask = Task { @MainActor [weak self, weak asset] in
            defer {
                if let self, self.mediaSelectionRefreshGeneration == refreshGeneration {
                    self.mediaSelectionRefreshTask = nil
                }
            }
            guard let self, let asset else { return }
            try? await self.refreshMediaSelectionGroups(for: asset, generation: generation)
        }
    }

    private func asset(for media: ResolvedMedia) -> AVURLAsset {
        let options: [String: Any]? = media.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": media.headers]
        return AVURLAsset(url: media.url, options: options)
    }

    private func makeItem(video: ResolvedMedia, audio: ResolvedMedia?) async throws -> AVPlayerItem {
        let videoAsset = asset(for: video)
        guard let audio else { return AVPlayerItem(asset: videoAsset) }
        let audioAsset = asset(for: audio)
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
