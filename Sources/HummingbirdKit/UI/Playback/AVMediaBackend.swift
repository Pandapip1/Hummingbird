#if canImport(AVFoundation) && !BACKEND_GTK
import Foundation
import AVFoundation
import SwiftOpenUI
import AdvancedVideoPlayerKit
import os
#if canImport(AVKit)
import AVKit
#endif
#if os(iOS)
import UIKit
#endif

@MainActor
final class AVMediaBackend: MediaBackend {
    // The view must be able to attach a rendering surface before the first item
    // has finished loading. Replacing the item on a stable player also avoids
    // making view attachment depend on completion of the initial seek.
    private(set) var player: AVPlayer? = AVMediaBackend.makePlayer()
    var onTick: (@MainActor (Double) -> Void)?
    var onActivityChange: (@MainActor (PlaybackActivity) -> Void)?
    var onExternalEvent: (@MainActor (ExternalPlaybackEvent) -> Void)?
    /// The rate the app last asked for (0: paused). A rate change the player
    /// reports that differs came from outside the app's controls.
    private var commandedRate: Float = 0
    private var interrupted = false
    private var reportedActivity: PlaybackActivity = .paused
    private var sessionObserver: UUID?
    /// Playing when an audio interruption (a call, Siri) began.
    private var playingBeforeInterruption = false
    /// Stopped for good (its model tore it down): it never plays again, so
    /// a load still in flight cannot start an invisible second player.
    private(set) var isRetired = false

    /// Video keeps playing (as audio) when the app goes to the background or
    /// the device locks; by default AVFoundation pauses it silently.
    private static func makePlayer() -> AVPlayer {
        let player = AVPlayer()
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        return player
    }

    var activity: PlaybackActivity {
        guard let player, player.currentItem != nil else { return .paused }
        switch player.timeControlStatus {
        case .playing: return .playing
        case .paused: return .paused
        case .waitingToPlayAtSpecifiedRate: return .waiting(Self.describe(player.reasonForWaitingToPlay))
        @unknown default: return .paused
        }
    }

    private static func describe(_ reason: AVPlayer.WaitingReason?) -> String {
        switch reason {
        case .toMinimizeStalls?, .evaluatingBufferingRate?: "Buffering"
        case .noItemToPlay?: "Loading"
        default: "Waiting"
        }
    }

    /// Reports the engine's state as it is now (called on every change AVPlayer
    /// reports, so pauses the system makes reach the UI).
    private func refreshActivity() {
        let current = activity
        classifyRateChange()
        guard current != reportedActivity else { return }
        reportedActivity = current
        onActivityChange?(current)
    }

    /// A play or pause the app did not ask for. While the app is in front or
    /// in Picture in Picture it is the user (AVKit's or PiP's controls, Siri):
    /// it is reported so the app's intent follows. In the background it is the
    /// system (lock-screen and remote commands come through `remoteCommand`),
    /// and the app's intent stays as it was.
    private func classifyRateChange() {
        guard let player, player.currentItem != nil, !interrupted else { return }
        let rate = player.rate
        if rate == 0, commandedRate > 0 {
            let atEnd = duration > 0 && currentTime >= duration - 0.5
            commandedRate = 0
            guard !atEnd else { return }
            // An item that never became ready, stopped by AVFoundation before its
            // first frame, is one it cannot play (VP9 on the iOS simulator: no
            // failure, only a pause). Said so, not taken for the user's pause.
            if player.currentItem?.status != .readyToPlay, currentTime == 0 {
                Logger.avPlayer.error("stopped_before_ready")
                onUnplayableMedia?("")
                return
            }
            if ApplicationActivity.isActive || pictureInPictureState == .active {
                Logger.avPlayer.notice("external_pause")
                onExternalEvent?(.pause)
            } else {
                Logger.avPlayer.notice("system_pause_in_background")
            }
        } else if rate > 0, commandedRate == 0 {
            commandedRate = rate
            Logger.avPlayer.notice("external_play")
            onExternalEvent?(.play)
        }
    }
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onUnplayableMedia: (@MainActor (String) -> Void)?
    private var timeObserver: Any?

    /// AVFoundation pauses, without failing, an item whose video it cannot
    /// decode (VP9 or AV1 where the device has no decoder): said by name
    /// instead of a silent pause.
    private func reportUndecodableVideo() async {
        guard let item = player?.currentItem else { return }
        for track in item.tracks {
            guard let asset = track.assetTrack, asset.mediaType == .video,
                  let decodable = try? await asset.load(.isDecodable), !decodable else { continue }
            let descriptions = (try? await asset.load(.formatDescriptions)) ?? []
            let codec = descriptions.first.map { description in
                let code = CMFormatDescriptionGetMediaSubType(description).bigEndian
                return String(decoding: withUnsafeBytes(of: code) { Array($0) }, as: UTF8.self)
            } ?? "this"
            guard player?.currentItem === item else { return }
            Logger.avPlayer.error("video_not_decodable codec=\(codec, privacy: .public)")
            onUnplayableMedia?(codec)
            return
        }
    }

    /// No decoder for the media's format on this device (AV1 without
    /// hardware support, VP9 where the system has none): reloading cannot help.
    private nonisolated static func isUnplayable(_ error: NSError) -> Bool {
        var current: NSError? = error
        while let error = current {
            if error.domain == AVFoundationErrorDomain,
               [AVError.Code.decoderNotFound.rawValue, AVError.Code.fileFormatNotRecognized.rawValue].contains(error.code) {
                return true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
    private var tickInterval = 0.5
    private var itemObserver: NSObjectProtocol?
    private var itemFailureObserver: NSObjectProtocol?
    private var itemStatusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    var onPictureInPictureChange: (@MainActor (PictureInPictureState) -> Void)?
    var onRestoreFromPictureInPicture: (@MainActor () -> Void)?
    private(set) var pictureInPictureState: PictureInPictureState = PictureInPictureSupport.isAvailable ? .unavailable : .unsupported {
        didSet { if pictureInPictureState != oldValue { onPictureInPictureChange?(pictureInPictureState) } }
    }
    /// The layer Picture in Picture takes the video from. The surface puts it in
    /// the view hierarchy (AVKit requires that); on macOS it is the surface.
    let pictureInPictureLayer = AVPlayerLayer()
    /// Which surface shows the player: one at a time.
    let surfaces = PlayerSurfaceOwnership()
    #if !os(visionOS)
    private var pictureInPicture: AVPictureInPictureController?
    private var pictureInPictureDelegate: PictureInPictureDelegate?
    private var pictureInPicturePossibleObserver: NSKeyValueObservation?
    #endif
    private var mediaSelectionGroups: [AVMediaCharacteristic: AVMediaSelectionGroup] = [:]
    private var loadGeneration = 0
    private var activeLoadGenerations: Set<Int> = []
    private var committedLoadGeneration: Int?
    private var invalidatedThroughGeneration = 0
    private var loadCompletionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var currentTime: Double { player?.currentTime().seconds ?? 0 }
    var hasFailedItem: Bool { player?.currentItem?.status == .failed }
    var duration: Double {
        guard let seconds = player?.currentItem?.duration.seconds, seconds.isFinite else { return 0 }
        return seconds
    }
    var isPlaying: Bool { (player?.rate ?? 0) > 0 }
    var tracks: [MediaTrack] {
        return [AVMediaCharacteristic.visual, .audible, .legible].flatMap { characteristic -> [MediaTrack] in
            guard let group = mediaSelectionGroups[characteristic] else { return [] }
            let kind: MediaTrack.Kind
            switch characteristic {
            case AVMediaCharacteristic.visual: kind = .video
            case AVMediaCharacteristic.audible: kind = .audio
            case AVMediaCharacteristic.legible: kind = .subtitles
            default: return []
            }
            return group.options.enumerated().map { index, option in
                var characteristics: Set<MediaTrack.Characteristic> = []
                if option.hasMediaCharacteristic(.describesVideoForAccessibility) { characteristics.insert(.audioDescription) }
                if option.mediaType == .closedCaption
                    || option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                    || option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) {
                    characteristics.insert(.closedCaptions)
                }
                if option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) { characteristics.insert(.forced) }
                return MediaTrack(id: "\(kind.rawValue)-\(index)", kind: kind, language: option.locale?.identifier,
                                  label: option.displayName, characteristics: characteristics)
            }
        }
    }

    func selectTrack(_ track: MediaTrack?) {
        guard let item = player?.currentItem else { return }
        guard let track else {
            if let group = mediaSelectionGroups[.legible] {
                item.select(nil, in: group)
            }
            return
        }
        let characteristic: AVMediaCharacteristic = switch track.kind {
        case .video: AVMediaCharacteristic.visual
        case .audio: AVMediaCharacteristic.audible
        case .subtitles: AVMediaCharacteristic.legible
        }
        guard let group = mediaSelectionGroups[characteristic],
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
        guard let group = mediaSelectionGroups[characteristic],
              let selected = item.currentMediaSelection.selectedMediaOption(in: group),
              let index = group.options.firstIndex(where: { $0 === selected }) else { return nil }
        return tracks.first { $0.kind == kind && $0.id == "\(kind.rawValue)-\(index)" }
    }

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        guard !isRetired else { throw MediaBackendLoadError.superseded }
        Logger.avPlayer.info("load_started videoHost=\(LogRedaction.redact(request.video.url.host ?? "unknown"), privacy: .public) audioHost=\(LogRedaction.redact(request.audio?.url.host ?? "none"), privacy: .public) separateAudio=\(request.audio != nil)")
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
        let item: AVPlayerItem
        do {
            item = try await makeItem(for: request)
        } catch {
            if hasNewerCommittedLoad(than: generation) { throw MediaBackendLoadError.superseded }
            throw error
        }
        try Task.checkCancellation()
        try await waitForNewerLoads(than: generation)
        try Task.checkCancellation()
        guard canCommitLoad(generation), !isRetired else { throw MediaBackendLoadError.superseded }
        removeObservers()
        let p = player ?? Self.makePlayer()
        observeAudioSession()
        p.replaceCurrentItem(with: item)
        player = p
        pictureInPictureLayer.player = p
        surfaces.refresh()
        observeStatus(of: item)
        refreshActivity()
        committedLoadGeneration = generation
        committedAsset = item.asset
        mediaSelectionGroups = [:]
        try await refreshMediaSelectionGroups(for: item.asset, generation: generation)
        try Task.checkCancellation()
        try await waitForNewerLoads(than: generation)
        try Task.checkCancellation()
        guard isCurrentLoad(generation, asset: item.asset) else { throw MediaBackendLoadError.superseded }
        if let resumeAt, resumeAt > 0 {
            await p.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try Task.checkCancellation()
            try await waitForNewerLoads(than: generation)
            try Task.checkCancellation()
            guard isCurrentLoad(generation, asset: item.asset) else { throw MediaBackendLoadError.superseded }
        }
        installTimeObserver(on: p)
        itemObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.deactivatePlaybackEnvironment()
                self?.onEnded?()
            }
        }
        if autoplay {
            activatePlaybackEnvironment()
            commandedRate = p.defaultRate
            p.play()
        } else {
            commandedRate = 0
        }
    }

    func setTickInterval(_ seconds: Double) {
        guard seconds != tickInterval else { return }
        tickInterval = seconds
        guard let player, let observer = timeObserver else { return }
        player.removeTimeObserver(observer)
        timeObserver = nil
        installTimeObserver(on: player)
    }

    /// Reports the position every `tickInterval` while the time changes (AVPlayer
    /// does not call it while paused).
    private func installTimeObserver(on player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: tickInterval, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            Task { @MainActor in self?.onTick?(time.seconds) }
        }
    }

    func play() {
        guard let player, !isRetired else { return }
        activatePlaybackEnvironment()
        commandedRate = player.defaultRate
        player.play()
    }
    func pause() {
        commandedRate = 0
        player?.pause()
        deactivatePlaybackEnvironment()
    }
    func setPlaybackRate(_ rate: Float) {
        if rate > 0, player != nil { activatePlaybackEnvironment() }
        else { deactivatePlaybackEnvironment() }
        commandedRate = rate
        player?.defaultRate = rate > 0 ? rate : 1
        player?.rate = rate
    }
    func seek(to seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }

    // MARK: Picture in Picture

    /// Called by the surface once `pictureInPictureLayer` is in a window.
    func pictureInPictureLayerDidMoveToWindow() {
        #if !os(visionOS)
        guard PictureInPictureSupport.isAvailable, pictureInPicture == nil else { return }
        guard let controller = AVPictureInPictureController(playerLayer: pictureInPictureLayer) else { return }
        let delegate = PictureInPictureDelegate(
            event: { [weak self] event in self?.pictureInPictureEvent(event) },
            restore: { [weak self] in self?.onRestoreFromPictureInPicture?() }
        )
        controller.delegate = delegate
        pictureInPicture = controller
        pictureInPictureDelegate = delegate
        pictureInPicturePossibleObserver = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            // Read the value here; only the Bool crosses into the main actor.
            let possible = controller.isPictureInPicturePossible
            MainActor.assumeIsolated {
                guard let self, self.pictureInPictureState == .possible || self.pictureInPictureState == .unavailable else { return }
                self.pictureInPictureState = possible ? .possible : .unavailable
            }
        }
        #endif
    }

    func startPictureInPicture() {
        #if !os(visionOS)
        guard pictureInPictureState == .possible, let pictureInPicture else { return }
        pictureInPictureState = .starting
        pictureInPicture.startPictureInPicture()
        #endif
    }

    func stopPictureInPicture() {
        #if !os(visionOS)
        guard pictureInPictureState == .active, let pictureInPicture else { return }
        pictureInPictureState = .stopping
        pictureInPicture.stopPictureInPicture()
        #endif
    }

    #if !os(visionOS)
    private func pictureInPictureEvent(_ event: PictureInPictureDelegate.Event) {
        switch event {
        case .willStart: pictureInPictureState = .starting
        case .didStart: pictureInPictureState = .active
        case .willStop: pictureInPictureState = .stopping
        case .didStop, .failed:
            pictureInPictureState = pictureInPicture?.isPictureInPicturePossible == true ? .possible : .unavailable
        }
    }
    #endif

    func stop() {
        deactivatePlaybackEnvironment()
        isRetired = true
        commandedRate = 0
        removeRemoteCommands()
        updateNowPlaying(nil)
        loadGeneration &+= 1
        invalidatedThroughGeneration = loadGeneration
        activeLoadGenerations.removeAll()
        committedLoadGeneration = nil
        resumeLoadCompletionWaiters()
        removeObservers()
        #if !os(visionOS)
        // Closing the player (its tab or window) ends Picture in Picture too.
        pictureInPicture?.stopPictureInPicture()
        #endif
        pictureInPictureLayer.player = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        mediaSelectionGroups = [:]
        refreshActivity()
    }

    /// Audio interruptions and media-services resets (iOS). AVPlayer pauses
    /// itself for an interruption; that pause reaches the UI through
    /// `refreshActivity`, and playback resumes when the system says it may. A
    /// media-services reset invalidates the player: it is reported as a
    /// failure so the model reloads from the cache at the same position.
    private func observeAudioSession() {
        guard sessionObserver == nil else { return }
        sessionObserver = SystemMediaSession.observeAudio { [weak self] event in self?.audioEvent(event) }
    }

    private func audioEvent(_ event: SystemMediaSession.AudioEvent) {
        switch event {
        case .interruptionBegan:
            playingBeforeInterruption = activity.wantsToPlay
            interrupted = true
            commandedRate = 0
            Logger.avPlayer.notice("audio_interruption_began playing=\(self.playingBeforeInterruption)")
            onExternalEvent?(.interruptionBegan)
        case .interruptionEnded(let shouldResume):
            Logger.avPlayer.notice("audio_interruption_ended resume=\(shouldResume)")
            interrupted = false
            // The app decides (its intent may have changed meanwhile).
            onExternalEvent?(.interruptionEnded(shouldResume: shouldResume))
            playingBeforeInterruption = false
        case .outputLost:
            guard commandedRate > 0 else { return }
            // Headphones unplugged: the player pauses; that is the user's pause.
            commandedRate = 0
            Logger.avPlayer.notice("output_lost")
            onExternalEvent?(.outputLost)
        case .mediaServicesReset:
            Logger.avPlayer.error("media_services_reset")
            onFailure?("The system restarted its media services")
        }
        refreshActivity()
    }

    private func removeObservers() {
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let o = itemObserver { NotificationCenter.default.removeObserver(o); itemObserver = nil }
        if let o = itemFailureObserver { NotificationCenter.default.removeObserver(o); itemFailureObserver = nil }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil
    }

    private func observeStatus(of item: AVPlayerItem) {
        // Where the player waits, and why (e.g. "evaluating buffering rate",
        // "to minimize stalls"): the last step of a slow start or a stall.
        timeControlObserver = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in self?.refreshActivity() }
            let status = player.timeControlStatus
            let name = switch status {
            case .paused: "paused"
            case .waitingToPlayAtSpecifiedRate: "waiting"
            case .playing: "playing"
            @unknown default: "other"
            }
            let reason = player.reasonForWaitingToPlay?.rawValue ?? ""
            Logger.avPlayer.info("time_control status=\(name, privacy: .public) reason=\(reason, privacy: .public)")
            OSSignposter.player.emitEvent("PlayerTimeControl", "status=\(name, privacy: .public) reason=\(reason, privacy: .public)")
        }
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, change in
            guard let status = change.newValue else { return }
            let name: String = switch status {
            case .unknown: "status_unknown"
            case .readyToPlay: "status_ready"
            case .failed: "status_failed"
            @unknown default: "status_other"
            }
            if let error = item?.error as NSError? {
                Logger.avPlayer.error("\(name, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code) message=\(error.localizedDescription)")
            } else {
                Logger.avPlayer.info("\(name, privacy: .public)")
            }
            if status == .failed, let event = item?.errorLog()?.events.last {
                let uriHost = event.uri.flatMap { URL(string: $0)?.host } ?? ""
                Logger.avPlayer.error("error_log httpStatus=\(event.errorStatusCode) uriHost=\(LogRedaction.redact(uriHost), privacy: .public) server=\(event.serverAddress ?? "") comment=\(event.errorComment ?? "")")
            }
            if status == .failed, let error = item?.error as NSError? {
                let message = error.localizedDescription
                let unplayable = Self.isUnplayable(error)
                Task { @MainActor in
                    if unplayable { self?.onUnplayableMedia?(message) } else { self?.onFailure?(message) }
                }
            }
            if status == .readyToPlay {
                Task { @MainActor in await self?.reportUndecodableVideo() }
            }
        }
        itemFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: nil
        ) { notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let nsError = error.map { $0 as NSError }
            Logger.avPlayer.error("failed_to_end domain=\(nsError?.domain ?? "unknown", privacy: .public) code=\(nsError?.code ?? 0) message=\(nsError?.localizedDescription ?? "unknown")")
        }
    }

    private func isCurrentLoad(_ generation: Int, asset: AVAsset) -> Bool {
        committedLoadGeneration == generation && player?.currentItem?.asset === asset
    }

    private func cancelCommittedLoad(_ generation: Int, asset: AVAsset) {
        guard isCurrentLoad(generation, asset: asset) else { return }
        deactivatePlaybackEnvironment()
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        mediaSelectionGroups = [:]
        committedLoadGeneration = nil
    }

    // MARK: system remote commands and Now Playing

    /// The lock screen, Control Center, headphones, CarPlay and Siri control
    /// the video that played last; each command goes to the app as an
    /// external event, so the app's intent, UI and history follow it.
    private func installRemoteCommands() {
        SystemMediaSession.takeRemoteCommands(owner: self) { [weak self] command in
            guard let self else { return false }
            let event: ExternalPlaybackEvent = switch command {
            case .play: .play
            case .pause: .pause
            case .togglePlayPause: .togglePlayPause
            case .seek(let seconds): .seek(to: seconds)
            case .skip(let seconds): .skip(by: seconds)
            }
            self.onExternalEvent?(event)
            return true
        }
    }

    private func removeRemoteCommands() {
        SystemMediaSession.releaseRemoteCommands(owner: self)
    }

    func updateNowPlaying(_ nowPlaying: NowPlaying?) {
        if nowPlaying != nil { installRemoteCommands() }
        guard SystemMediaSession.ownsRemoteCommands(self) else { return }
        SystemMediaSession.publishNowPlaying(nowPlaying.map {
            SystemMediaSession.NowPlaying(title: $0.title, duration: $0.duration, position: $0.position, rate: $0.rate)
        })
    }

    /// Keeps playback alive under the platform policies that normally suspend
    /// media or blank the display after user inactivity.
    private func activatePlaybackEnvironment() {
        // The playback audio session, once (re-applying it is audible).
        SystemMediaSession.activateForPlayback { [weak self] message in
            self?.onFailure?("Could not activate background audio: \(message)")
        }
        SystemMediaSession.keepDisplayAwake(true)
    }

    private func deactivatePlaybackEnvironment() {
        SystemMediaSession.deactivate()
        SystemMediaSession.keepDisplayAwake(false)
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
            await withTaskCancellationHandler {
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

    // MARK: building items

    private func asset(for media: ResolvedMedia) -> AVURLAsset {
        // This option key is not exposed in the public headers but is the long-standing way to set request headers.
        let options: [String: Any]? = media.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": media.headers]
        return AVURLAsset(url: media.url, options: options)
    }

    private func makeItem(for request: PlayRequest) async throws -> AVPlayerItem {
        let videoAsset = asset(for: request.video)
        guard let audioMedia = request.audio else {
            // Loaded here, asynchronously, so neither the item nor replacing the
            // player's item waits for the asset on the main thread.
            _ = try await videoAsset.load(.isPlayable, .duration)
            return AVPlayerItem(asset: videoAsset, automaticallyLoadedAssetKeys: [.isPlayable, .duration])
        }

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

#if canImport(AVKit) && canImport(SwiftUI) && (os(iOS) || os(tvOS) || os(visionOS))
/// Holds the backend's Picture in Picture layer at the back of a player
/// controller's view, always filling it (rotation, resizing): AVKit needs the
/// layer on screen, and a layer with a stale frame would show a second copy
/// of the video in the corner.
@MainActor
final class PictureInPictureHostView: UIView {
    weak var backend: AVMediaBackend?

    func host(_ backend: AVMediaBackend) {
        self.backend = backend
        let layer = backend.pictureInPictureLayer
        if layer.superlayer !== self.layer {
            layer.removeFromSuperlayer()
            self.layer.addSublayer(layer)
        }
        // Marks the one surface that shows the player (UI tests count them).
        isAccessibilityElement = true
        accessibilityIdentifier = "player-surface"
        setNeedsLayout()
        if window != nil { backend.pictureInPictureLayerDidMoveToWindow() }
    }

    func release() {
        isAccessibilityElement = false
        accessibilityIdentifier = nil
        if let layer = backend?.pictureInPictureLayer, layer.superlayer === self.layer { layer.removeFromSuperlayer() }
        backend = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backend?.pictureInPictureLayer.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { backend?.pictureInPictureLayerDidMoveToWindow() }
    }

    /// Installs a host at the back of `controller`'s view.
    static func install(in controller: AVPlayerViewController) -> PictureInPictureHostView {
        let host = PictureInPictureHostView(frame: controller.view.bounds)
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.isUserInteractionEnabled = false
        controller.view.insertSubview(host, at: 0)
        return host
    }
}

/// AVKit's SwiftUI `VideoPlayer` always supplies its own controls. Wrap the
/// underlying view controller so Hummingbird can provide one shared control
/// surface on Apple and GTK.
@MainActor
struct PlayerSurface: UIViewControllerRepresentable {
    let model: PlayerModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController.pictureOnly()
        context.coordinator.inlineController = controller
        context.coordinator.installPresenter()
        context.coordinator.environment = context.environment
        // Only the owner of the player is attached to it (see
        // PlayerSurfaceOwnership): this surface claims it now.
        context.coordinator.claimInline(controller)
        // Entering full screen built AVKit's controller on the tap (a 349 ms
        // main-thread stall): build it once per player, while the run loop is idle.
        context.coordinator.prepareFullscreenWhenIdle()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // SwiftUI updates this view for any change it observes (every tick,
        // menus, tabs). Nothing here touches the player: attaching is the
        // ownership's job, so updates cannot pause it or attach a second copy.
        context.coordinator.inlineController = controller
        context.coordinator.installPresenter(replacing: false)
        context.coordinator.environmentChanged(context.environment)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.dismissFullscreen(animated: false)
        // A torn-down AVPlayerViewController pauses its player (tab switches,
        // layout changes rebuild this view): resigning detaches it first and
        // hands the player to the surface before it, if any.
        coordinator.resignInline()
        coordinator.model?.removeFullscreenPresenter(owner: coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var model: PlayerModel?
        weak var inlineController: AVPlayerViewController?
        /// The prepared presentation while it is on screen.
        private var fullscreenController: UIViewController?
        private var inlineClaim: PlayerSurfaceOwnership.Claim?
        private var fullscreenClaim: PlayerSurfaceOwnership.Claim?
        private var inlineHost: PictureInPictureHostView?
        private var preparationScheduled = false
        /// The page's environment, carried into the full-screen controls.
        var environment: EnvironmentValues?

        func environmentChanged(_ environment: EnvironmentValues) {
            self.environment = environment
            (model?.preparedFullscreen as? FullscreenStage)?.update(environment: environment)
        }

        private var backend: AVMediaBackend? { model?.backend as? AVMediaBackend }

        func claimInline(_ controller: AVPlayerViewController) {
            guard let backend else { return }
            let host = PictureInPictureHostView.install(in: controller)
            inlineHost = host
            let claim = PlayerSurfaceOwnership.Claim(name: "inline", attach: { [weak controller, weak backend, weak host] in
                guard let controller, let backend else { return }
                if controller.player !== backend.player { controller.player = backend.player }
                host?.host(backend)
            }, detach: { [weak controller, weak host] in
                controller?.player = nil
                host?.release()
            })
            inlineClaim = claim
            backend.surfaces.claim(claim)
        }

        func resignInline() {
            if let inlineClaim { backend?.surfaces.resign(inlineClaim) }
            inlineClaim = nil
        }
        var isFullscreen: Bool { fullscreenController != nil }

        init(model: PlayerModel) { self.model = model }

        /// A new surface takes over full screen (`replacing`); updates only
        /// install it when no surface has.
        func installPresenter(replacing: Bool = true) {
            let present: () -> Void = { [weak self] in self?.presentFullscreen() }
            let dismiss: () -> Void = { [weak self] in self?.dismissFullscreen(animated: true) }
            if replacing {
                model?.installFullscreenPresenter(owner: self, present: present, dismiss: dismiss)
            } else {
                model?.installFullscreenPresenterIfNone(owner: self, present: present, dismiss: dismiss)
            }
        }

        /// Builds the full-screen presentation once per player, at the first
        /// idle run-loop pass after this surface appears (not while scrolling,
        /// not on the tap). AVKit's controllers are UIKit objects and must be
        /// made on the main thread; idle time is the cheapest main time there is.
        func prepareFullscreenWhenIdle() {
            guard !preparationScheduled, model?.preparedFullscreen == nil else { return }
            preparationScheduled = true
            MainRunLoopIdle.perform(after: .milliseconds(500)) { [weak self] in
                guard let self, let model = self.model else { return }
                _ = FullscreenStage.prepared(for: model, environment: self.environment)
            }
        }

        private func presentFullscreen() {
            guard fullscreenController == nil,
                  let model,
                  let inlineController,
                  let presenter = presentingController(from: inlineController) else {
                Logger.player.error("fullscreen_present_refused presented=\(self.fullscreenController != nil) model=\(self.model != nil) inline=\(self.inlineController != nil) window=\(self.inlineController?.view.window != nil)")
                return
            }
            let start = ContinuousClock.now
            defer {
                let ms = start.duration(to: .now) / .milliseconds(1)
                Logger.player.notice("fullscreen_present main_ms=\(ms, format: .fixed(precision: 1))")
            }
            // Normally built already; if the tap came first it is built now, once.
            let stage = FullscreenStage.prepared(for: model, environment: environment)
            let controller = stage.controller
            fullscreenController = controller
            // The full-screen controller takes the player (attached before the
            // inline one lets go), with the Picture in Picture layer.
            if let backend {
                let playerController = stage.controller.playerController, host = stage.host
                let claim = PlayerSurfaceOwnership.Claim(name: "fullscreen", attach: { [weak playerController, weak backend, weak host] in
                    guard let playerController, let backend else { return }
                    if playerController.player !== backend.player { playerController.player = backend.player }
                    host?.host(backend)
                }, detach: { [weak playerController, weak host] in
                    playerController?.player = nil
                    host?.release()
                })
                fullscreenClaim = claim
                backend.surfaces.claim(claim)
            }
            model.fullscreenDidChange(true)
            presenter.present(controller, animated: true) {
                model.restorePlaybackAfterSurfaceTransfer()
                controller.setNeedsFocusUpdate()
                controller.updateFocusIfNeeded()
            }
            controller.presentationController?.delegate = self
        }

        func dismissFullscreen(animated: Bool) {
            guard let controller = fullscreenController else {
                model?.fullscreenDidChange(false)
                return
            }
            // AVPlayerViewController may pause its player while it tears down.
            // Transfer ownership back to the inline controller before dismissal
            // so late AVKit cleanup cannot pause the shared player after restore.
            // Hand the same player back without a gap: the inline surface
            // attaches first, then the full-screen one lets go.
            resignFullscreen()
            controller.dismiss(animated: animated) { [weak self] in self?.finishDismissal() }
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finishDismissal()
        }

        /// The presentation stays built (with its controls) for the next entry.
        private func finishDismissal() {
            resignFullscreen()
            fullscreenController = nil
            model?.fullscreenDidChange(false)
            model?.restorePlaybackAfterSurfaceTransfer()
        }

        private func resignFullscreen() {
            if let fullscreenClaim { backend?.surfaces.resign(fullscreenClaim) }
            fullscreenClaim = nil
        }

        private func presentingController(from controller: UIViewController) -> UIViewController? {
            var presenter = controller.view.window?.rootViewController
            while let presented = presenter?.presentedViewController { presenter = presented }
            return presenter
        }
    }
}

extension AVPlayerViewController {
    /// The player as a picture only, the one way the app makes one
    /// (`PlayerSurfaceConstructionTests`): our controls, drawn over it, take
    /// every touch, click and remote press. Interactive, AVKit's view took
    /// the remote's focus and kept it, so no control could be reached (tvOS).
    static func pictureOnly() -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.view.isUserInteractionEnabled = false
        controller.leaveNowPlayingToTheApp()
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    /// The app publishes Now Playing and handles the remote commands itself
    /// (`SystemMediaSession`); tvOS players never update Now Playing.
    func leaveNowPlayingToTheApp() {
        #if !os(tvOS)
        updatesNowPlayingInfoCenter = false
        #endif
    }
}

/// The full-screen presentation, built once per player (`PlayerModel.close`
/// drops it) and presented again on every entry.
@MainActor
private final class FullscreenStage {
    let controller: FullscreenPlayerViewController
    let host: PictureInPictureHostView
    private let overlay: UIHostingController<FullscreenPlayerControls>
    private let model: PlayerModel

    static func prepared(for model: PlayerModel, environment: EnvironmentValues?) -> FullscreenStage {
        if let stage = model.preparedFullscreen as? FullscreenStage { return stage }
        let start = ContinuousClock.now
        let stage = FullscreenStage(model: model, environment: environment)
        model.preparedFullscreen = stage
        let ms = start.duration(to: .now) / .milliseconds(1)
        Logger.player.notice("fullscreen_prepared main_ms=\(ms, format: .fixed(precision: 1))")
        return stage
    }

    /// The page's environment changed (the inline surface updated): the
    /// full-screen controls follow it.
    func update(environment: EnvironmentValues) {
        overlay.rootView = FullscreenPlayerControls(model: model, inherited: environment)
    }

    private init(model: PlayerModel, environment: EnvironmentValues?) {
        self.model = model
        let playerController = AVPlayerViewController.pictureOnly()
        // A container holds the player and, above it, our controls: inside
        // AVPlayerViewController's own view the controls would be outside
        // its accessibility (and, on tvOS, focus) hierarchy.
        let controller = FullscreenPlayerViewController(playerController: playerController)
        controller.modalPresentationStyle = .overFullScreen
        #if os(iOS)
        controller.modalPresentationCapturesStatusBarAppearance = true
        #endif

        let overlay = UIHostingController(rootView: FullscreenPlayerControls(model: model, inherited: environment))
        self.overlay = overlay
        overlay.view.backgroundColor = .clear
        controller.addChild(overlay)
        overlay.view.translatesAutoresizingMaskIntoConstraints = false
        // AVPlayerViewController's contentOverlayView belongs to AVKit's
        // own focus environment. On tvOS its container wins focus during
        // presentation, leaving interactive SwiftUI content unreachable.
        // Install controls above the player root so they participate in
        // the presented controller's focus hierarchy instead.
        let container = controller.view!  // loads the player's view too
        container.addSubview(overlay.view)
        NSLayoutConstraint.activate([
            overlay.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.view.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        overlay.didMove(toParent: controller)
        controller.controlsController = overlay
        self.controller = controller
        host = PictureInPictureHostView.install(in: playerController)
    }
}

/// Runs work on the main thread when its run loop is next about to sleep
/// (nothing else to do; not while a scroll tracks), after a delay that lets
/// the page draw its first frames.
@MainActor
enum MainRunLoopIdle {
    static func perform(after delay: Duration, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 0) { observer, _ in
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .defaultMode)
                // Not inside the observer: SwiftUI and Core Animation commit their
                // transactions in this same phase. Run as the next main-queue work.
                Task { @MainActor in work() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
        }
    }
}

/// The full-screen player: AVPlayerViewController as a child, our controls
/// above it. AVPlayerViewController otherwise prefers its own full-screen
/// container (focusable on tvOS even with its controls disabled) and keeps
/// added subviews out of its accessibility hierarchy.
@MainActor
private final class FullscreenPlayerViewController: UIViewController {
    let playerController: AVPlayerViewController
    weak var controlsController: UIViewController?

    init(playerController: AVPlayerViewController) {
        self.playerController = playerController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(playerController)
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        playerController.view.isUserInteractionEnabled = false
        view.insertSubview(playerController.view, at: 0)
        NSLayoutConstraint.activate([
            playerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerController.didMove(toParent: self)
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        controlsController.map { [$0] } ?? super.preferredFocusEnvironments
    }

}

/// The full-screen controls, hosted by their own UIHostingController, which
/// inherits nothing from the page: the inline surface's whole environment is
/// carried in (so a control the page provides, such as Watch Later, can't go
/// missing here), except what describes this screen (size classes, scale).
@MainActor
private struct FullscreenPlayerControls: View {
    let model: PlayerModel
    let inherited: EnvironmentValues?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let inherited {
            controls
                .environment(\.horizontalSizeClass, horizontalSizeClass)
                .environment(\.verticalSizeClass, verticalSizeClass)
                .environment(\.displayScale, displayScale)
                .environment(\.self, inherited)
        } else {
            controls
        }
    }

    private var controls: some View {
        PlayerControls(model: model, isFullscreen: true)
            // Built ahead of time (FullscreenStage): each entry starts afresh, so
            // the controls show and focus starts on play/pause.
            .id(model.isFullscreen)
            .frame(maxHeight: .infinity, alignment: .bottom)
            #if os(tvOS)
            .onExitCommand { model.toggleFullscreen() }
            #endif
    }
}
#elseif canImport(AVKit) && canImport(SwiftUI) && os(macOS)
@MainActor
struct PlayerSurface: NSViewRepresentable {
    let model: PlayerModel

    /// Shows the backend's `pictureInPictureLayer`, so the same layer drives
    /// Picture in Picture (AVKit needs it on screen).
    final class LayerView: NSView {
        weak var backend: AVMediaBackend?
        private var claim: PlayerSurfaceOwnership.Claim?

        func show(_ backend: AVMediaBackend?) {
            guard backend !== self.backend else { return }
            resign()
            self.backend = backend
            wantsLayer = true
            if window != nil { claimPlayer() }
        }

        /// Only the owner hosts the layer (see PlayerSurfaceOwnership): a
        /// second view hosting the same layer is a second copy on screen.
        private func claimPlayer() {
            guard let backend, claim == nil else { return }
            let claim = PlayerSurfaceOwnership.Claim(name: "mac", attach: { [weak self, weak backend] in
                guard let self, let backend else { return }
                let layer = backend.pictureInPictureLayer
                layer.videoGravity = .resizeAspect
                if layer.superlayer !== self.layer {
                    layer.removeFromSuperlayer()
                    self.layer?.addSublayer(layer)
                }
                layer.frame = self.bounds
                backend.pictureInPictureLayerDidMoveToWindow()
            }, detach: { [weak self, weak backend] in
                guard let layer = backend?.pictureInPictureLayer, layer.superlayer === self?.layer else { return }
                layer.removeFromSuperlayer()
            })
            self.claim = claim
            backend.surfaces.claim(claim)
        }

        private func resign() {
            if let claim { backend?.surfaces.resign(claim) }
            claim = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { claimPlayer() } else { resign() }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let layer = backend?.pictureInPictureLayer, layer.superlayer === self.layer { layer.frame = bounds }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.show(model.backend as? AVMediaBackend)
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        view.show(model.backend as? AVMediaBackend)
    }
}
#endif

@MainActor
enum PictureInPictureSupport {
    /// Whether this device can show Picture in Picture at all.
    static var isAvailable: Bool {
        #if os(visionOS)
        false
        #else
        AVPictureInPictureController.isPictureInPictureSupported()
        #endif
    }
}

#if !os(visionOS)
/// Relays AVKit's Picture in Picture callbacks (delivered on the main thread).
@MainActor
final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    enum Event { case willStart, didStart, failed, willStop, didStop }
    private let event: @MainActor (Event) -> Void
    private let restore: @MainActor () -> Void

    init(event: @escaping @MainActor (Event) -> Void, restore: @escaping @MainActor () -> Void) {
        self.event = event
        self.restore = restore
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { event(.willStart) }
    }
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { event(.didStart) }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        MainActor.assumeIsolated { event(.failed) }
    }
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { event(.willStop) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { event(.didStop) }
    }
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // Bring the player's tab back before the video returns to it.
        MainActor.assumeIsolated { restore() }
        completionHandler(true)
    }
}
#endif

@MainActor
func makeMediaBackend() -> MediaBackend { AVMediaBackend() }

/// Loads the playback frameworks once, off the main thread, so the first video
/// does not pay for it there (making the first AVPlayerLayer initialises
/// AVFoundation and QuartzCore: about 100 ms on the main thread otherwise).
func prewarmMediaBackend() {
    Task.detached(priority: .utility) {
        _ = AVPlayerLayer()
        _ = AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
    }
}
#endif
