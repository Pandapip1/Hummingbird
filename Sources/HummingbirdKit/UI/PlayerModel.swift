import Foundation
import Observation
import SwiftOpenUI
import AdvancedVideoPlayerKit
import os

enum SubtitleColorChoice: String, CaseIterable, Sendable {
    case white, yellow, green, cyan

    var label: String { rawValue.capitalized }
    @MainActor var color: Color {
        switch self {
        case .white: .white
        case .yellow: .yellow
        case .green: .green
        case .cyan: .cyan
        }
    }
}

enum SubtitleSizeChoice: Double, CaseIterable, Sendable {
    case small = 16
    case medium = 20
    case large = 24
    case extraLarge = 28

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
}

/// Device-local playback settings, kept in the stores' preferences domain.
enum PlaybackPreferenceKey {
    static let maxVideoHeight = "maxVideoHeight"
    static let preferAdaptive = "preferAdaptive"
    static let showSubtitlesByDefault = "showSubtitlesByDefault"
    static let subscriptionFetchLimit = "subscriptionFetchLimit"
    static let subtitleColor = "subtitleColor"
    static let subtitleSize = "subtitleSize"
    /// Gigabytes the media cache may hold before it removes least recently used videos.
    static let mediaCacheLimitGigabytes = "mediaCacheLimitGigabytes"
}

@MainActor
@Observable
final class PlayerModel: AdvancedVideoPlayerControlling {
    /// The platform player. The view layer reads it to draw the video surface (see `PlayerSurface`).
    private(set) var backend: MediaBackend?
    // Keep the rendering surface attached while AVFoundation prepares the item.
    // Generated video-only assets can require a rendering consumer before an
    // exact initial seek completes, and `selected` is intentionally committed
    // only after `backend.load` returns.
    var hasMedia: Bool { backend != nil }
    private(set) var loadedURL: String?
    private(set) var options: [PlaybackOption] = []
    private(set) var selected: PlaybackOption?
    private(set) var audioSources: [MediaSource] = []
    private(set) var selectedAudioSource: MediaSource?
    private(set) var errorMessage: String?
    private(set) var isPreparing = false
    private(set) var preparationMessage: String?
    private(set) var subtitleText: String?
    private(set) var subtitleChoice: SubtitleSource?
    private(set) var embeddedSubtitleChoice: MediaTrack?
    private(set) var subtitleSources: [SubtitleSource] = []
    var tracks: [MediaTrack] { backend?.tracks ?? [] }
    var pictureInPictureSupported: Bool { backend?.pictureInPictureSupported ?? false }
    private(set) var playbackTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var playbackRate: Float = 1
    private(set) var subtitleColorChoice: SubtitleColorChoice
    private(set) var subtitleSizeChoice: SubtitleSizeChoice
    private(set) var isFullscreen = false
    var title: String { details?.item.name ?? "" }
    var onPlaybackEnded: (() -> Void)?

    @ObservationIgnored private var cues: [SubtitleCue] = []
    @ObservationIgnored private var details: VideoDetails?
    @ObservationIgnored private var runtime: PluginRuntime?
    @ObservationIgnored private var library: LibraryStore?
    @ObservationIgnored private var trackerTask: Task<Void, Never>?
    @ObservationIgnored private var trackerHandle: Int?
    @ObservationIgnored private var lastHistoryWrite = Date.distantPast
    @ObservationIgnored private var presentFullscreenAction: (() -> Void)?
    @ObservationIgnored private var dismissFullscreenAction: (() -> Void)?
    @ObservationIgnored private var didFinishCurrentItem = false
    @ObservationIgnored private var playGeneration = 0
    @ObservationIgnored private var umpRefreshAttempts = 0
    @ObservationIgnored private var requestedPluginReload: (message: String, data: String?)?
    @ObservationIgnored private var declaredDuration: Double = 0
    @ObservationIgnored private var reportedDurationMismatch = false
    @ObservationIgnored private var pendingSeekTask: Task<Void, Never>?
    @ObservationIgnored private var playbackRequested = false
    @ObservationIgnored private let preferences: PreferencesDomain
    @ObservationIgnored private let mediaProxy: PluginMediaProxy
    @ObservationIgnored private let mediaCache: MediaCache
    @ObservationIgnored private let mediaServer: LocalMediaServer
    /// The download of the current on-demand video into the media cache.
    @ObservationIgnored private var vodSession: VODSession?
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    /// The generated-media presentation the proxy serves for the current video.
    @ObservationIgnored private var generatedPresentation: URL?
    /// What the player was last given, to reload it from local data after a player failure.
    @ObservationIgnored private var currentPlayback: LocalPlayback?
    @ObservationIgnored private var localRecoveryAttempts = 0
    @ObservationIgnored private var startup: PlaybackStartupTrace?

    /// Per-track, per-stage progress of the current video's media pipeline
    /// (download today; transcoding later). The seek bar's buffered ranges
    /// come from here.
    private(set) var pipeline: MediaPipelineSnapshot = .empty

    /// Shown over the video while playback waits for bytes that the network
    /// has not delivered yet. Downloads retry on their own.
    var bufferingMessage: String? {
        guard pipeline.waitingForNetwork, pipeline.playableAhead(of: playbackTime) < 3 else { return nil }
        return "Waiting for the network. The download resumes on its own."
    }

    init(stores: AppDataStores, backend: MediaBackend? = nil) {
        self.backend = backend
        preferences = stores.preferences
        mediaProxy = stores.mediaProxy
        mediaCache = stores.mediaCache
        mediaServer = stores.mediaServer
        let defaults = stores.defaults
        subtitleColorChoice = SubtitleColorChoice(
            rawValue: defaults.string(forKey: PlaybackPreferenceKey.subtitleColor) ?? "white"
        ) ?? .white
        subtitleSizeChoice = SubtitleSizeChoice(
            rawValue: defaults.double(forKey: PlaybackPreferenceKey.subtitleSize)
        ) ?? .medium
    }

    // MARK: loading

    func load(details: VideoDetails, runtime: PluginRuntime, library: LibraryStore, sourceURL: String) async {
        umpRefreshAttempts = 0
        await load(details: details, runtime: runtime, library: library, sourceURL: sourceURL,
                   reloadAttempt: 0, resumeOverride: nil, autoplay: true)
    }

    private func load(details: VideoDetails, runtime: PluginRuntime, library: LibraryStore,
                      sourceURL: String, reloadAttempt: Int, resumeOverride: Double?, autoplay: Bool) async {
        let host = URL(string: sourceURL)?.host ?? "unknown"
        Logger.player.info("load_started plugin=\(runtime.id, privacy: .public) host=\(host, privacy: .public) attempt=\(reloadAttempt)")
        let signpost = OSSignposter.player.beginInterval("LoadContent", id: OSSignposter.player.makeSignpostID(), "plugin=\(runtime.id, privacy: .public) host=\(host, privacy: .public)")
        defer { OSSignposter.player.endInterval("LoadContent", signpost, "error=\(self.errorMessage != nil)") }
        teardown()
        loadedURL = sourceURL
        self.details = details
        declaredDuration = Double(details.item.duration ?? 0)
        duration = declaredDuration
        self.subtitleSources = details.subtitles
        self.runtime = runtime
        self.library = library
        errorMessage = nil
        preparationMessage = nil
        isPreparing = true
        defer { isPreparing = false; preparationMessage = nil }

        let maxHeight = preferences.defaults.object(forKey: PlaybackPreferenceKey.maxVideoHeight) as? Int ?? 1080
        let preferAdaptive = preferences.defaults.object(forKey: PlaybackPreferenceKey.preferAdaptive) as? Bool ?? true
        let engine = backend ?? makeMediaBackend()
        backend = engine
        engine.onTick = { [weak self] seconds in self?.tick(seconds) }
        engine.onEnded = { [weak self] in self?.finished() }
        engine.onFailure = { [weak self] message in self?.playerFailed(message) }
        startup = PlaybackStartupTrace()
        let preferredLanguage = Locale.current.language.languageCode?.identifier
        let splitAudioSources = PlaybackSelector.audioChoices(details.audioSources)
        selectedAudioSource = PlaybackSelector.bestAudio(details.audioSources, language: preferredLanguage)
        let sourceTypes = Dictionary(grouping: details.videoSources, by: \.pluginType)
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        Logger.player.info("source_inventory types=\(sourceTypes, privacy: .public) video=\(PlaybackSelector.inventory(details.videoSources), privacy: .public) audio=\(PlaybackSelector.inventory(details.audioSources), privacy: .public)")
        options = PlaybackSelector.options(for: details, preferredLanguage: preferredLanguage)
        guard let choice = PlaybackSelector.best(options, maxHeight: maxHeight, preferAdaptive: preferAdaptive) else {
            Logger.player.error("no_playable_source options=\(self.options.count)")
            errorMessage = options.isEmpty
                ? "This video has no source this device can play (it offers only formats the player does not support, such as WebM, DASH or DRM-protected streams)."
                : "No playable source found."
            return
        }
        if choice.kind == .generated {
            audioSources = PlaybackSelector.generatedAudioChoices(in: details.audioSources)
            selectedAudioSource = choice.audio
        } else {
            audioSources = splitAudioSources
        }
        let saved = SavedVideo(details.item)
        let ignoreSavedPosition = ProcessInfo.processInfo.environment["HUMMINGBIRD_DEBUG_IGNORE_RESUME"] == "1"
        let resume = resumeOverride ?? (ignoreSavedPosition ? nil : library.position(for: saved))
        requestedPluginReload = nil
        guard await play(choice, resumeAt: resume, duration: details.item.duration, autoplay: autoplay,
                         normalizeSavedPosition: resumeOverride == nil,
                         reloadOnBlockedBootstrap: reloadAttempt == 0) else {
            if let reload = requestedPluginReload, reloadAttempt < 2 {
                Logger.player.notice("plugin_reload attempt=\(reloadAttempt + 1) message=\(reload.message)")
                await runtime.reload(reloadData: reload.data)
                do {
                    let data = try await runtime.callRaw("getContentDetails", [sourceURL], kind: "details")
                    guard case .video(let refreshed) = try await PluginRuntime.decodeOffMain(ContentDetails.self, from: data) else {
                        errorMessage = "The plugin stopped returning video details after its playback workaround."
                        return
                    }
                    await load(details: refreshed, runtime: runtime, library: library,
                               sourceURL: sourceURL, reloadAttempt: reloadAttempt + 1,
                               resumeOverride: resumeOverride, autoplay: autoplay)
                } catch {
                    errorMessage = error.localizedDescription
                    Logger.player.error("plugin_reload_failed error=\(String(reflecting: type(of: error)), privacy: .public) message=\(error.localizedDescription)")
                }
            }
            return
        }

        if let first = details.subtitles.first(where: { $0.language?.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") == true }),
           preferences.defaults.bool(forKey: PlaybackPreferenceKey.showSubtitlesByDefault) {
            await chooseSubtitle(first)
        }
        await startTracker()
    }

    func select(_ option: PlaybackOption) async {
        let position = backend?.currentTime
        let autoplay = backend?.isPlaying ?? true
        var choice = option
        if choice.audio != nil, let selectedAudioSource { choice.audio = selectedAudioSource }
        guard await play(choice, resumeAt: position, duration: details?.item.duration,
                         autoplay: autoplay, normalizeSavedPosition: false) else { return }
        refreshAudioSources(for: choice)
    }

    func selectAudioSource(_ source: MediaSource) async {
        guard var choice = selected else { return }
        let position = backend?.currentTime
        let autoplay = backend?.isPlaying ?? true
        guard choice.audio != nil else { return }
        choice.audio = source
        guard await play(choice, resumeAt: position, duration: details?.item.duration,
                         autoplay: autoplay, normalizeSavedPosition: false) else { return }
        selectedAudioSource = source
    }

    private func refreshAudioSources(for choice: PlaybackOption) {
        guard let details else { return }
        if choice.kind == .generated {
            audioSources = PlaybackSelector.generatedAudioChoices(in: details.audioSources)
            selectedAudioSource = choice.audio
        } else {
            audioSources = PlaybackSelector.audioChoices(details.audioSources)
            selectedAudioSource = choice.audio
        }
    }

    func selectTrack(_ track: MediaTrack?) {
        backend?.selectTrack(track)
        switch track?.kind {
        case .video, .audio: break
        case .subtitles: embeddedSubtitleChoice = track
        case nil: embeddedSubtitleChoice = nil
        }
    }
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? {
        backend?.selectedTrack(ofKind: kind)
    }
    func chooseEmbeddedSubtitle(_ track: MediaTrack) async {
        await chooseSubtitle(nil)
        selectTrack(track)
    }
    func startPictureInPicture() { backend?.startPictureInPicture() }
    func stopPictureInPicture() { backend?.stopPictureInPicture() }
    func toggleFullscreen() {
        if isFullscreen {
            if let dismissFullscreenAction { dismissFullscreenAction() }
            else { isFullscreen = false }
        } else {
            if let presentFullscreenAction { presentFullscreenAction() }
            else { isFullscreen = true }
        }
    }
    func dismissFullscreen() {
        guard isFullscreen else { return }
        if let dismissFullscreenAction { dismissFullscreenAction() }
        else { isFullscreen = false }
    }
    func installFullscreenPresenter(present: @escaping () -> Void, dismiss: @escaping () -> Void) {
        presentFullscreenAction = present
        dismissFullscreenAction = dismiss
    }
    func removeFullscreenPresenter() {
        presentFullscreenAction = nil
        dismissFullscreenAction = nil
    }
    func fullscreenDidChange(_ fullscreen: Bool) { isFullscreen = fullscreen }
    func togglePlayback() {
        guard let backend else { return }
        if isPlaying {
            backend.pause()
            isPlaying = false
            playbackRequested = false
        } else {
            backend.play()
            backend.setPlaybackRate(playbackRate)
            isPlaying = true
            playbackRequested = true
        }
    }
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { backend?.setPlaybackRate(rate) }
    }
    func setSubtitleColor(_ choice: SubtitleColorChoice) {
        subtitleColorChoice = choice
        preferences.defaults.set(choice.rawValue, forKey: PlaybackPreferenceKey.subtitleColor)
    }
    func setSubtitleSize(_ choice: SubtitleSizeChoice) {
        subtitleSizeChoice = choice
        preferences.defaults.set(choice.rawValue, forKey: PlaybackPreferenceKey.subtitleSize)
    }
    func skip(by seconds: Double) {
        seek(to: playbackTime + seconds, coalescing: false)
    }
    func seek(to seconds: Double) {
        seek(to: seconds, coalescing: true)
    }
    private func seek(to seconds: Double, coalescing: Bool) {
        guard let backend else { return }
        let target = min(max(0, seconds), duration > 0 ? duration : .greatestFiniteMagnitude)
        if duration <= 0 || target < duration - 0.5 { didFinishCurrentItem = false }
        playbackTime = target
        pendingSeekTask?.cancel()
        if coalescing {
            pendingSeekTask = Task { @MainActor [weak self, weak backend] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                backend?.seek(to: target)
                self?.pendingSeekTask = nil
            }
        } else {
            backend.seek(to: target)
        }
    }
    func replay() {
        guard let backend else { return }
        didFinishCurrentItem = false
        backend.seek(to: 0)
        backend.play()
        backend.setPlaybackRate(playbackRate)
        playbackTime = 0
        isPlaying = true
        playbackRequested = true
    }

    private func play(
        _ option: PlaybackOption,
        resumeAt: Double?,
        duration: Int?,
        autoplay: Bool = true,
        normalizeSavedPosition: Bool = true,
        reloadOnBlockedBootstrap: Bool = false
    ) async -> Bool {
        guard let backend else { return false }
        playGeneration &+= 1
        let generation = playGeneration
        isPreparing = true
        defer { isPreparing = false }
        // The previous media keeps playing until the new media is loaded.
        let previousSession = vodSession
        let previousPresentation = generatedPresentation
        var newSession: VODSession?
        var newPresentation: URL?
        do {
            let videoHost = URL(string: option.video.url)?.host ?? "generated"
            let audioHost = option.audio.flatMap { URL(string: $0.url)?.host } ?? "none"
            Logger.player.info("source_selected kind=\(String(describing: option.kind), privacy: .public) videoType=\(option.video.pluginType, privacy: .public) height=\(option.video.height) videoBitrate=\(option.video.bitrate) audioBitrate=\(option.audio?.bitrate ?? 0) videoHost=\(videoHost, privacy: .public) audioHost=\(audioHost, privacy: .public)")
            startup?.mark(.selected)
            let playback: LocalPlayback
            switch option.kind {
            case .live:
                playback = .live(try await resolveUpstream(option.video))
            case .hls:
                playback = .uncachedAdaptiveHLS(try await resolveUpstream(option.video))
            case .generated:
                let url: URL
                if let audioSource = option.audio, audioSource.pluginType == "DashManifestRawAudioSource" {
                    url = try await resolveGeneratedPair(video: option.video, audio: audioSource, generation: generation)
                } else {
                    url = try await resolveGenerated(option.video, generation: generation)
                }
                newPresentation = url
                playback = try LocalPlayback(video: url, servedBy: .generatedMedia)
            case .progressive:
                let (session, local) = try await startDownload(option)
                newSession = session
                playback = local
            }
            startup?.mark(.resolved)
            let newPipelineTask = newSession.map(observePipeline)
            var start = resumeAt
            if let r = resumeAt {
                // Restart from the beginning if the viewer was already near the end, or has barely started.
                if option.kind == .live { start = nil }
                else if normalizeSavedPosition, r <= 5 { start = nil }
                else if normalizeSavedPosition, let duration, Double(duration) - r < 15 { start = nil }
            }
            try await backend.load(playback.request, resumeAt: start, autoplay: autoplay)
            startup?.mark(.playerLoaded)
            currentPlayback = playback
            localRecoveryAttempts = 0
            vodSession = newSession
            generatedPresentation = newPresentation
            pipelineTask?.cancel()
            pipelineTask = newPipelineTask
            if newSession == nil { pipeline = .empty }
            await stopMedia(session: previousSession, presentation: previousPresentation)
            backend.setPlaybackRate(playbackRate)
            didFinishCurrentItem = false
            // Media selections belong to the replaced AVPlayerItem. Do not show
            // a stale embedded-caption checkmark after a quality/source change.
            embeddedSubtitleChoice = nil
            selected = option
            if generation == playGeneration { errorMessage = nil }
            playbackTime = backend.currentTime
            self.duration = authoritativeDuration
            isPlaying = backend.isPlaying
            playbackRequested = autoplay
            Logger.player.info("load_completed playing=\(self.isPlaying)")
            return true
        } catch {
            if newSession != nil || newPresentation != nil {
                await stopMedia(session: newSession, presentation: newPresentation)
            }
            if let pluginError = error as? PluginError, case .reloadRequired(let message, let reloadData) = pluginError {
                requestedPluginReload = (message, reloadData)
            } else if error is CancellationError || (error as? MediaBackendLoadError) == .superseded {
                // A newer load replaced this one.
            } else {
                Logger.player.error("load_failed error=\(String(reflecting: type(of: error)), privacy: .public) message=\(error.localizedDescription)")
                errorMessage = (error as? PluginError)?.localizedDescription ?? error.localizedDescription
            }
            return false
        }
    }

    // MARK: media pipeline

    /// Starts downloading a file-based option into the media cache and
    /// returns the local playback for it.
    private func startDownload(_ option: PlaybackOption) async throws -> (VODSession, LocalPlayback) {
        guard let runtime, let sourceURL = loadedURL else {
            throw PluginError.execution("The video's plugin is no longer available")
        }
        let declared = declaredDuration > 0 ? declaredDuration : nil
        let muxed = option.audio == nil
        let video = try trackSpec(option.video, role: muxed ? .muxed : .video, runtime: runtime,
                                  sourceURL: sourceURL, declaredDuration: declared)
        let audio = try option.audio.map {
            try trackSpec($0, role: .audio, runtime: runtime, sourceURL: sourceURL, declaredDuration: declared)
        }
        return try await VODSession.start(video: video, audio: audio, cache: mediaCache, server: mediaServer)
    }

    private func trackSpec(_ source: MediaSource, role: MediaTrackRole, runtime: PluginRuntime,
                           sourceURL: String, declaredDuration: Double?) throws -> VODTrackSpec {
        guard let signer = Self.signer(for: source, runtime: runtime) else {
            throw PluginError.execution("Invalid media URL")
        }
        let identity = [
            "vod-v1", runtime.id, sourceURL, role.rawValue, source.pluginType, source.formatID ?? "",
            source.name, source.container, source.codec, String(source.bitrate),
            "\(source.width)x\(source.height)", source.language,
        ].joined(separator: "|")
        return VODTrackSpec(
            role: role, identity: identity, signer: signer,
            refresh: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.refreshedSigner(for: source)
            },
            indexHint: source.indexRange, container: source.container, codec: source.codec,
            bandwidth: source.bitrate, width: source.width, height: source.height,
            declaredDuration: source.duration > 0 ? Double(source.duration) : declaredDuration
        )
    }

    /// Builds each upstream request through the plugin's request modifier,
    /// once per request as Grayjay does (YouTube's modifier carries the range
    /// in the URL and numbers the requests).
    nonisolated private static func signer(for source: MediaSource, runtime: PluginRuntime) -> UpstreamRequestSigner? {
        guard let url = URL(string: source.url), url.scheme == "https" || url.scheme == "http" else { return nil }
        guard let modifier = source.requestModifier else { return .plain(url) }
        let original = source.url
        let handle = modifier.handle
        return UpstreamRequestSigner { range in
            let rangeValue = "\(range.lowerBound)-\(range.upperBound - 1)"
            let data = try await runtime.callHandle(handle, "modifyRequest", [original, ["Range": "bytes=" + rangeValue]])
            let modified = try await PluginRuntime.decodeOffMain(ModifiedRequest.self, from: data)
            let target = modified.url.flatMap(URL.init(string:)) ?? url
            var request = URLRequest(url: target)
            let headers = modified.headers ?? [:]
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let rangeInHeaders = headers.keys.contains { $0.caseInsensitiveCompare("Range") == .orderedSame }
            let rangeInURL = URLComponents(url: target, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "range" && $0.value == rangeValue } ?? false
            if !rangeInHeaders, !rangeInURL {
                request.setValue("bytes=" + rangeValue, forHTTPHeaderField: "Range")
            }
            return request
        }
    }

    /// Fresh request signing for `source` after its upstream URL expired:
    /// asks the plugin for the video's details again and finds the same format.
    private func refreshedSigner(for source: MediaSource) async throws -> UpstreamRequestSigner {
        guard let runtime, let sourceURL = loadedURL else { throw CancellationError() }
        let data = try await runtime.callRaw("getContentDetails", [sourceURL], kind: "details")
        guard case .video(let refreshed) = try await PluginRuntime.decodeOffMain(ContentDetails.self, from: data) else {
            throw PluginError.execution("The plugin stopped returning video details")
        }
        guard let match = (refreshed.videoSources + refreshed.audioSources)
            .first(where: { PlaybackSelector.isSameFileSource($0, as: source) }),
              let signer = Self.signer(for: match, runtime: runtime) else {
            throw PluginError.execution("The plugin no longer offers the selected format")
        }
        return signer
    }

    /// Follows a session's pipeline state. A session being prepared (e.g. a
    /// quality switch) feeds the startup trace; only the current session
    /// drives `pipeline`.
    private func observePipeline(of session: VODSession) -> Task<Void, Never> {
        Task { [weak self] in
            for await snapshot in session.states {
                guard !Task.isCancelled, let self else { return }
                self.startup?.observe(snapshot)
                if self.vodSession === session { self.pipeline = snapshot }
            }
        }
    }

    private func stopMedia(session: VODSession?, presentation: URL?) async {
        if let session { await session.stop() }
        if let presentation { await mediaProxy.release(presentation) }
    }

    /// The player failed while playing local data (the loopback server only
    /// ever waits for bytes, so this is the player giving up, e.g. on a
    /// timeout during a long outage). Reload the same local media at the
    /// same position instead of showing an error; the download carries on.
    private func playerFailed(_ message: String) {
        guard let playback = currentPlayback, playback.origin == .mediaCache || playback.origin == .generatedMedia,
              localRecoveryAttempts < 8 else {
            errorMessage = message
            return
        }
        localRecoveryAttempts += 1
        let attempt = localRecoveryAttempts
        let position = backend?.currentTime ?? playbackTime
        let autoplay = playbackRequested
        let generation = playGeneration
        Logger.player.notice("local_playback_recover attempt=\(attempt) position=\(position)")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(30, Double(attempt * attempt))))
            guard let self, generation == self.playGeneration, let backend = self.backend else { return }
            do {
                try await backend.load(playback.request, resumeAt: position > 0 ? position : nil, autoplay: autoplay)
                backend.setPlaybackRate(self.playbackRate)
            } catch {
                Logger.player.error("local_playback_recover_failed attempt=\(attempt) message=\(error.localizedDescription)")
            }
        }
    }

    // MARK: resolving sources

    private struct ModifiedRequest: Decodable, Sendable {
        var url: String?
        var headers: [String: String]?
    }

    private func resolveGeneratedPair(video: MediaSource, audio: MediaSource,
                                      generation: Int) async throws -> URL {
        guard let runtime, let videoHandle = video.handle, let audioHandle = audio.handle else {
            throw PluginError.execution("Generated video or audio source is unavailable")
        }
        let videoManifest = try await PluginRuntime.decodeOffMain(
            String.self, from: try await runtime.callHandle(videoHandle, "generate")
        )
        guard let videoExecutor = try await runtime.handleFromCall(videoHandle, "getRequestExecutor") else {
            throw PluginError.execution("The generated video source did not provide a request executor")
        }
        let audioManifest = try await PluginRuntime.decodeOffMain(
            String.self, from: try await runtime.callHandle(audioHandle, "generate")
        )
        guard let audioExecutor = try await runtime.handleFromCall(audioHandle, "getRequestExecutor") else {
            throw PluginError.execution("The generated audio source did not provide a request executor")
        }
        let url = try await mediaProxy.register(
            videoManifest: videoManifest, videoRuntime: runtime, videoExecutor: videoExecutor.handle,
            audioManifest: audioManifest, audioRuntime: runtime, audioExecutor: audioExecutor.handle,
            failure: { [weak self] error in
                Task { @MainActor in await self?.handlePluginMediaFailure(error, generation: generation) }
            }
        )
        return url
    }

    /// Registers a plugin-generated (DASH manifest + request executor) source with the media proxy.
    private func resolveGenerated(_ source: MediaSource, generation: Int) async throws -> URL {
        Logger.player.info("resolve_source type=\(source.pluginType, privacy: .public) generated=true")
        let signpost = OSSignposter.player.beginInterval("ResolveSource", id: OSSignposter.player.makeSignpostID(), "type=\(source.pluginType, privacy: .public)")
        defer { OSSignposter.player.endInterval("ResolveSource", signpost) }
        guard let handle = source.handle, let runtime else {
            throw PluginError.execution("Generated video source is unavailable")
        }
        let manifestData = try await runtime.callHandle(handle, "generate")
        let manifest = try await PluginRuntime.decodeOffMain(String.self, from: manifestData)
        guard let executor = try await runtime.handleFromCall(handle, "getRequestExecutor") else {
            throw PluginError.execution("The generated media source did not provide a request executor")
        }
        let url = try await mediaProxy.register(
            manifest: manifest, runtime: runtime, executor: executor.handle,
            prefetchExecutorFactory: { [source, sourceURL = loadedURL] in
                guard let sourceURL else {
                    throw PluginError.execution("The generated prefetch source URL is unavailable")
                }
                let clone = runtime.isolatedClone()
                do {
                    let data = try await clone.callRaw("getContentDetails", [sourceURL], kind: "details")
                    guard case .video(let details) = try await PluginRuntime.decodeOffMain(ContentDetails.self, from: data) else {
                        throw PluginError.execution("The isolated prefetch runtime did not return video details")
                    }
                    let candidates = source.pluginType == "DashManifestRawAudioSource"
                        ? details.audioSources : details.videoSources
                    guard let cloneSource = candidates.first(where: {
                              PlaybackSelector.isSameGeneratedSource($0, as: source) && $0.handle != nil
                          }), let handle = cloneSource.handle else {
                        throw PluginError.execution("The isolated prefetch runtime did not return the selected source")
                    }
                    _ = try await clone.callHandle(handle, "generate")
                    guard let executor = try await clone.handleFromCall(handle, "getRequestExecutor") else {
                        throw PluginError.execution("The isolated prefetch source did not provide an executor")
                    }
                    return (clone, executor.handle)
                } catch {
                    await clone.stop()
                    throw error
                }
            },
            failure: { [weak self] error in
                Task { @MainActor in
                    await self?.handlePluginMediaFailure(error, generation: generation)
                }
            }
        )
        return url
    }

    /// An upstream URL for media the player streams directly: live streams,
    /// and (as named debt, see `LocalPlayback.uncachedAdaptiveHLS`) upstream
    /// adaptive HLS. On-demand files never come through here; they are
    /// downloaded into the media cache (`startDownload`).
    private func resolveUpstream(_ source: MediaSource) async throws -> ResolvedMedia {
        let host = URL(string: source.url)?.host ?? "unknown"
        Logger.player.info("resolve_source type=\(source.pluginType, privacy: .public) host=\(host, privacy: .public) hasModifier=\(source.requestModifier != nil)")
        let signpost = OSSignposter.player.beginInterval("ResolveSource", id: OSSignposter.player.makeSignpostID(), "type=\(source.pluginType, privacy: .public)")
        defer { OSSignposter.player.endInterval("ResolveSource", signpost) }
        guard var url = URL(string: source.url) else { throw PluginError.execution("Invalid media URL") }
        var headers: [String: String] = [:]
        if let ref = source.requestModifier, let runtime {
            // The modifier runs once, for the initial request. The player then reuses its headers for later requests.
            let data = try await runtime.callHandle(ref.handle, "modifyRequest", [source.url, [String: String]()])
            if let mod = try? await PluginRuntime.decodeOffMain(ModifiedRequest.self, from: data) {
                if let u = mod.url, let nu = URL(string: u) { url = nu }
                headers = mod.headers ?? [:]
            }
        }
        return ResolvedMedia(url: url, headers: headers)
    }

    private func handlePluginMediaFailure(_ error: PluginError, generation: Int) async {
        guard case .reloadRequired(let message, let reloadData) = error else {
            guard generation == playGeneration else { return }
            errorMessage = error.localizedDescription
            return
        }
        await refreshPlayback(reason: message, reloadData: reloadData, generation: generation)
    }

    private func refreshPlayback(reason: String, reloadData: String?, generation: Int) async {
        guard generation == playGeneration else { return }
        guard let details, let runtime, let library, let sourceURL = loadedURL else {
            errorMessage = reason
            return
        }
        guard umpRefreshAttempts < 2 else {
            errorMessage = "YouTube playback details expired repeatedly. Please retry playback."
            Logger.player.error("ump_refresh_exhausted attempts=\(self.umpRefreshAttempts) reason=\(reason)")
            OSSignposter.player.emitEvent("UMPRefreshExhausted")
            return
        }
        let position = backend?.currentTime ?? playbackTime
        let autoplay = backend?.isPlaying ?? isPlaying
        umpRefreshAttempts += 1
        playGeneration &+= 1
        if position.isFinite, position > 1 {
            library.recordProgress(SavedVideo(details.item), seconds: position)
            library.flushHistory()
        }
        // Keep presenting whatever AVPlayer has already buffered while the
        // isolated plugin runtime obtains replacement playback details.
        Logger.player.notice("ump_refresh_started attempt=\(self.umpRefreshAttempts) position=\(position)")
        let signpost = OSSignposter.player.beginInterval("UMPRefresh", id: OSSignposter.player.makeSignpostID(), "attempt=\(self.umpRefreshAttempts)")
        defer { OSSignposter.player.endInterval("UMPRefresh", signpost) }
        await runtime.reload(reloadData: reloadData)
        do {
            let data = try await runtime.callRaw("getContentDetails", [sourceURL], kind: "details")
            guard case .video(let refreshed) = try await PluginRuntime.decodeOffMain(ContentDetails.self, from: data) else {
                throw PluginError.execution("The plugin stopped returning video details after refreshing playback")
            }
            let latestPosition = max(position, backend?.currentTime ?? 0)
            let latestAutoplay = backend?.isPlaying ?? autoplay
            await load(details: refreshed, runtime: runtime, library: library, sourceURL: sourceURL,
                       reloadAttempt: 1, resumeOverride: latestPosition, autoplay: latestAutoplay)
        } catch {
            errorMessage = error.localizedDescription
            Logger.player.error("ump_refresh_failed error=\(String(reflecting: type(of: error)), privacy: .public) message=\(error.localizedDescription)")
        }
    }

    /// The one duration the seek bar shows. A cached VOD's segment index is
    /// exact (the sum of its segments, shortest track); otherwise the player's
    /// item duration; otherwise what the plugin declared. A player duration
    /// far from the plugin's is logged: that is how a mis-estimated length
    /// (the 1.5x seek bar of the old progressive composition) shows up.
    private var authoritativeDuration: Double {
        if let indexed = pipeline.mediaDuration, indexed > 0 { return indexed }
        let backendDuration = backend?.duration ?? 0
        if backendDuration > 0 {
            if declaredDuration > 0, abs(backendDuration - declaredDuration) > max(2, declaredDuration * 0.05),
               !reportedDurationMismatch {
                reportedDurationMismatch = true
                Logger.player.error("duration_mismatch player=\(backendDuration) declared=\(self.declaredDuration)")
            }
            return backendDuration
        }
        return declaredDuration
    }

    // MARK: ticking

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        duration = authoritativeDuration
        isPlaying = backend?.isPlaying ?? false
        if isPlaying, seconds > playbackTime {
            startup?.firstFrame(at: seconds)
            if seconds - playbackTime < 2 { localRecoveryAttempts = 0 }
        }
        playbackTime = seconds
        subtitleText = cues.first(where: { seconds >= $0.start && seconds <= $0.end })?.text
        if Date().timeIntervalSince(lastHistoryWrite) > 5, let details, let library, seconds > 1 {
            lastHistoryWrite = Date()
            library.recordProgress(SavedVideo(details.item), seconds: seconds)
        }
    }

    private func finished() {
        guard !didFinishCurrentItem else { return }
        didFinishCurrentItem = true
        isPlaying = false
        playbackRequested = false
        if let details, let library { library.recordProgress(SavedVideo(details.item), seconds: 0); library.flushHistory() }
        onPlaybackEnded?()
    }

    // MARK: subtitles

    func chooseSubtitle(_ sub: SubtitleSource?) async {
        backend?.selectTrack(nil)
        embeddedSubtitleChoice = nil
        subtitleChoice = sub
        cues = []
        subtitleText = nil
        if let url = sub?.url.flatMap(URL.init(string:)) {
            backend?.setExternalSubtitle(url)
        } else {
            backend?.setExternalSubtitle(nil)
        }
        guard let sub else { return }
        var text: String?
        if let h = sub.getSubtitlesHandle, let runtime {
            for attempt in 0..<3 where text?.isEmpty ?? true {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                if let data = try? await runtime.callHandle(h, "getSubtitles") {
                    text = try? await PluginRuntime.decodeOffMain(String.self, from: data)
                }
            }
        }
        // Some plugins expose both a convenience loader and the underlying URL.
        // A generated loader can expire independently, so fall back to the URL.
        if (text?.isEmpty ?? true), let u = sub.url, let url = URL(string: u) {
            text = (try? await URLSession.shared.data(from: url)).flatMap { String(data: $0.0, encoding: .utf8) }
        }
        if let text {
            cues = await Task.detached(priority: .userInitiated) { SubtitleParser.parse(text) }.value
        }
    }

    // MARK: playback tracker

    private func startTracker() async {
        guard let details, let runtime else { return }
        var ref: PluginRuntime.HandleRef?
        if details.hasTracker { ref = try? await runtime.handleFromCall(details.handle, "getPlaybackTracker") }
        else if runtime.has("getPlaybackTracker") { ref = try? await runtime.handleFromSource("getPlaybackTracker", [details.item.url]) }
        guard let ref else { return }
        trackerHandle = ref.handle
        let handle = ref.handle
        let hasInit = await runtime.hasMember(handle: handle, "onInit")
        trackerTask = Task { [weak self] in
            var first = true
            var interval = max(100, ref.nextRequest ?? 10_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000)
                guard !Task.isCancelled, let self else { return }
                let (seconds, playing) = await MainActor.run { (self.backend?.currentTime ?? 0, self.backend?.isPlaying ?? false) }
                guard seconds.isFinite else { continue }
                if first && hasInit { _ = try? await runtime.callHandle(handle, "onInit", [seconds]) }
                else { _ = try? await runtime.callHandle(handle, "onProgress", [Int(seconds), playing]) }
                first = false
                if let next = await runtime.intProperty(handle: handle, "nextRequest") { interval = max(100, next) }
            }
        }
    }

    // MARK: teardown

    func restorePlaybackAfterSurfaceTransfer() {
        guard playbackRequested, let backend else { return }
        backend.play()
        backend.setPlaybackRate(playbackRate)
        isPlaying = true
    }

    func teardown() {
        pendingSeekTask?.cancel()
        pendingSeekTask = nil
        trackerTask?.cancel(); trackerTask = nil
        if let h = trackerHandle, let rt = runtime {
            Task { if await rt.hasMember(handle: h, "onConcluded") { _ = try? await rt.callHandle(h, "onConcluded", [-1]) } }
        }
        trackerHandle = nil
        if !didFinishCurrentItem,
           let seconds = backend?.currentTime, seconds.isFinite, seconds > 1, let details, let library {
            library.recordProgress(SavedVideo(details.item), seconds: seconds)
        }
        library?.flushHistory()
        dismissFullscreen()
        backend?.stop()
        backend = nil
        // Downloads stop with the player; what was downloaded stays cached and
        // resumes the next time this video plays.
        let session = vodSession, presentation = generatedPresentation
        vodSession = nil
        generatedPresentation = nil
        currentPlayback = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        pipeline = .empty
        startup = nil
        if session != nil || presentation != nil {
            Task { await self.stopMedia(session: session, presentation: presentation) }
        }
        loadedURL = nil
        selected = nil
        audioSources = []
        selectedAudioSource = nil
        reportedDurationMismatch = false
        playbackTime = 0; duration = 0; declaredDuration = 0; isPlaying = false; isFullscreen = false
        playbackRequested = false
        cues = []; subtitleText = nil; subtitleChoice = nil; embeddedSubtitleChoice = nil
        didFinishCurrentItem = false
    }
}
