import Foundation
import Observation
import SwiftOpenUI
import AdvancedVideoPlayerKit
import os

/// Device-local playback settings, kept in the stores' preferences domain.
enum PlaybackPreferenceKey {
    static let maxVideoHeight = "maxVideoHeight"
    static let showSubtitlesByDefault = "showSubtitlesByDefault"
    static let subscriptionFetchLimit = "subscriptionFetchLimit"
    /// Gigabytes the media cache may hold before it removes least recently used videos.
    static let mediaCacheLimitGigabytes = "mediaCacheLimitGigabytes"
    /// Re-encode finished downloads to save space (off by default).
    static let transcodeDownloads = "transcodeDownloads"
}

/// The outcome of a stream switch, announced once to assistive technology
/// (each one is new, even with the same words).
struct SwitchAnnouncement: Equatable, Sendable {
    let id = UUID()
    let text: String
    init(_ text: String) { self.text = text }
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
    /// Playable media is loaded. Until then the controls are disabled and the
    /// page shows progress.
    /// Media is loaded. A stream switch in progress does not change this:
    /// every control stays usable while a switch is pending.
    var isMediaReady: Bool { selected != nil }
    private(set) var loadedURL: String?
    private(set) var options: [PlaybackOption] = []
    private(set) var selected: PlaybackOption? { didSet { if selected?.kind != oldValue?.kind { refreshScrubberContent() } } }
    private(set) var audioSources: [MediaSource] = []
    private(set) var selectedAudioSource: MediaSource?
    /// A source or audio stream being switched to, not yet confirmed playing.
    private(set) var pendingOption: PlaybackOption?
    private(set) var pendingAudioSource: MediaSource?
    /// The player gave up on local data and is being reloaded at the same position.
    private(set) var isRecovering = false { didSet { if isRecovering != oldValue { refreshBufferingMessage() } } }
    /// Tests only: a load alone confirms a switch (fake backends that never play).
    @ObservationIgnored var confirmsSwitchOnLoadForTesting = false
    /// A switch waiting for its new stream to play (its generation), and the
    /// backend failure that ended the wait, if any.
    @ObservationIgnored private var confirmingGeneration: Int?
    @ObservationIgnored private var confirmationFailure: String?
    /// The play generation the user cancelled by choosing the current stream.
    @ObservationIgnored private var cancelledSwitchGeneration: Int?
    /// Tests only: turns an option into local playback without a plugin, so
    /// load generations, switching and confirmation can be driven by a fake
    /// backend. Nil in the app.
    /// Makes the playback engine for each load (the platform's; tests supply their own).
    @ObservationIgnored var makeBackend: @MainActor () -> any MediaBackend = { makeMediaBackend() }
    @ObservationIgnored var localPlaybackForTesting: (@MainActor (PlaybackOption) async throws -> LocalPlayback)?
    private(set) var errorMessage: String?
    private(set) var isPreparing = false
    private(set) var preparationMessage: String?
    private(set) var embeddedSubtitleChoice: MediaTrack?
    /// The outcome of the last stream switch, for assistive technology to
    /// announce ("Now playing 1080p", or why the previous stream was kept).
    private(set) var switchAnnouncement: SwitchAnnouncement?
    var tracks: [MediaTrack] { backend?.tracks ?? [] }
    /// Picture in Picture, as the backend reports it (see `PictureInPictureState`).
    private(set) var pictureInPictureState: PictureInPictureState = .unsupported
    /// Brings this player's page back (its tab becomes active) when the user
    /// returns from Picture in Picture. Set by the tab that owns the player.
    @ObservationIgnored var onRestoreRequested: (() -> Void)?
    /// Called when playback starts; the window pauses its other tabs.
    @ObservationIgnored var onStartedPlaying: (() -> Void)?

    /// The app is back in front (the player's own activity observer: one path
    /// for every player, in the app and in debug scenes). First every loopback
    /// listener is bound again and downloads restart, awaited, so nothing asks
    /// a socket iOS closed (`LoopbackLifecycle.resume`). Then a video the user
    /// had playing keeps playing: an item that failed while the app was away,
    /// or whose server could not keep its port, is rebuilt at the same
    /// position from the cache (VOD never needs the network for bytes it has);
    /// one the system only paused resumes where it is. A video the user paused
    /// stays paused.
    func resumeAfterBackground() async {
        let generation = playGeneration
        let moves = await LoopbackLifecycle.shared.resume()
        guard generation == playGeneration, let backend, !didFinishCurrentItem, !unplayable else { return }
        if let playback = currentPlayback, case let moved = playback.moved(moves),
           case let failed = backend.hasFailedItem || recoverOnResume, moved != nil || failed {
            recoverOnResume = false
            let next = moved ?? playback
            currentPlayback = next
            let position = backend.currentTime > 0 ? backend.currentTime : playbackTime
            Logger.player.notice("resume_rebuild position=\(position) moved=\(moved != nil) failed=\(failed)")
            errorMessage = nil
            isRecovering = true
            defer { isRecovering = false }
            do {
                try await backend.load(next.request, resumeAt: position > 0 ? position : nil, autoplay: playbackRequested)
                backend.setPlaybackRate(playbackRate)
            } catch is CancellationError {
            } catch MediaBackendLoadError.superseded {
            } catch {
                guard generation == playGeneration else { return }
                errorMessage = error.localizedDescription
            }
            return
        }
        guard playbackRequested, backend.activity == .paused, !isRecovering, !isInterrupted,
              pictureInPictureState != .active else { return }
        Logger.player.notice("resume_after_foreground position=\(backend.currentTime)")
        playByUser()
    }

    /// Another tab of the window started playing: this one pauses, unless
    /// it is in Picture in Picture.
    func pauseForAnotherTab() {
        guard isPlaying, pictureInPictureState != .active else { return }
        togglePlayback()
    }
    /// The position, in its own observable (`PlaybackClock`): only the views
    /// that show it redraw as playback advances.
    @ObservationIgnored let clock = PlaybackClock()
    private(set) var playbackTime: Double {
        get { clock.time }
        set { clock.time = newValue }
    }
    private(set) var duration: Double = 0 { didSet { if duration != oldValue { refreshScrubberContent() } } }
    private(set) var isPlaying = false { didSet { if isPlaying != oldValue { applyTickInterval() } } }
    /// Why playback that should advance does not (buffering, stalled,
    /// reconnecting); nil while it plays or is paused. Computed from its
    /// inputs, never stored: a stored copy went stale whenever a change
    /// arrived through a path that did not refresh it (surface handover).
    var waitingReason: String? {
        if isRecovering { return "Reconnecting" }
        if watchdogStalled, engineActivity.wantsToPlay { return "Stalled" }
        return engineActivity.waitingReason
    }
    /// What the engine last reported, reconciled on every tick as well as on
    /// every change it reports.
    private(set) var engineActivity: PlaybackActivity = .paused
    /// The watchdog saw "playing" without the clock advancing.
    private var watchdogStalled = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    private(set) var playbackRate: Float = 1
    private(set) var isFullscreen = false { didSet { if isFullscreen != oldValue { applyTickInterval() } } }
    var title: String { details?.item.name ?? "" }
    var onPlaybackEnded: (() -> Void)?

    @ObservationIgnored private var details: VideoDetails?
    @ObservationIgnored private var runtime: PluginRuntime?
    @ObservationIgnored private var library: LibraryStore?
    @ObservationIgnored private var trackerTask: Task<Void, Never>?
    @ObservationIgnored private var trackerHandle: Int?
    @ObservationIgnored private var lastHistoryWrite = Date.distantPast
    @ObservationIgnored private var presentFullscreenAction: (() -> Void)?
    @ObservationIgnored private var dismissFullscreenAction: (() -> Void)?
    /// The surface whose presenter is installed: only it can remove it.
    @ObservationIgnored private weak var fullscreenPresenterOwner: AnyObject?
    /// The full-screen presentation the player's surface built ahead of time
    /// and reuses for every entry, for as long as this player lives (opaque:
    /// each surface keeps its own kind).
    @ObservationIgnored var preparedFullscreen: AnyObject?
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
    @ObservationIgnored private let mediaDownloads: MediaDownloads
    /// The download of the current on-demand video into the media cache.
    @ObservationIgnored private var vodSession: VODSession?
    @ObservationIgnored private var pipelineTask: Task<Void, Never>?
    /// The generated-media presentation the proxy serves for the current video.
    @ObservationIgnored private var generatedPresentation: URL?
    /// What the player was last given, to reload it from local data after a player failure.
    @ObservationIgnored private var currentPlayback: LocalPlayback?
    /// Local playback failed while the app was away: rebuilt when it is back.
    @ObservationIgnored private var recoverOnResume = false
    /// This system has no decoder for the media (`mediaUnplayable`): nothing to rebuild.
    @ObservationIgnored private var unplayable = false
    @ObservationIgnored private var localRecoveryAttempts = 0
    @ObservationIgnored private var startup: PlaybackStartupTrace?

    /// The video's chapters from the plugin (`getContentChapters`), for the seek bar.
    private(set) var chapters: [PlaybackChapter] = [] { didSet { refreshScrubberContent() } }

    /// What the seek bar shows (see `PlaybackScrubber`).
    /// What the seek bar shows. Built off the main actor whenever the pipeline,
    /// duration, chapters or kind of stream change (a long video's lanes map
    /// thousands of byte ranges to times), never while a view renders.
    private(set) var scrubberContent = ScrubberContent(duration: 0)
    @ObservationIgnored private var scrubberContentTask: Task<Void, Never>?

    private func refreshScrubberContent() {
        let pipeline = pipeline, duration = duration, chapters = chapters, isLive = selected?.kind == .live
        scrubberContentTask?.cancel()
        scrubberContentTask = Task { [weak self] in
            let content = await Self.makeScrubberContent(pipeline: pipeline, duration: duration,
                                                         chapters: chapters, isLive: isLive)
            guard !Task.isCancelled, let self, self.scrubberContent != content else { return }
            self.scrubberContent = content
        }
    }

    @concurrent nonisolated private static func makeScrubberContent(pipeline: MediaPipelineSnapshot, duration: Double,
                                                                     chapters: [PlaybackChapter], isLive: Bool) async -> ScrubberContent {
        PlaybackScrubber.content(pipeline: pipeline, duration: duration, chapters: chapters, isLive: isLive)
    }

    /// Seeks to just behind the live edge of the recording.
    func jumpToLive() {
        let edge = pipeline.mediaDuration ?? duration
        seek(to: max(0, edge - 2))
    }

    /// Per-track, per-stage progress of the current video's media pipeline
    /// (download today; transcoding later). The seek bar's buffered ranges
    /// come from here.
    private(set) var pipeline: MediaPipelineSnapshot = .empty { didSet { refreshScrubberContent(); refreshBufferingMessage() } }

    /// Shown over the video while playback waits for bytes that the network
    /// has not delivered yet. Downloads retry on their own. Stored, and set
    /// only when it changes, so the page does not redraw on every tick.
    private(set) var bufferingMessage: String?

    private func refreshBufferingMessage() {
        let message: String? = if isRecovering {
            "Reloading the video from this device…"
        } else if pipeline.waitingForNetwork, pipeline.playableAhead(of: playbackTime) < 3 {
            "Waiting for the network. The download resumes on its own."
        } else {
            nil
        }
        if message != bufferingMessage { bufferingMessage = message }
    }

    // MARK: ticking less

    @ObservationIgnored private var controlsOnScreen = true
    @ObservationIgnored private var pageOnScreen = true
    @ObservationIgnored private var applicationActive = true

    /// The controls appeared or hid (`AdvancedVideoPlayerControls`).
    func controlsVisibilityChanged(_ visible: Bool) {
        controlsOnScreen = visible
        applyTickInterval()
    }

    /// The video's page came on screen or left it (another tab, navigation).
    func pageVisibilityChanged(_ visible: Bool) {
        pageOnScreen = visible
        applyTickInterval()
    }

    /// Twice a second while someone can see the position; otherwise every
    /// `quietTickInterval` seconds, still often enough to record progress at
    /// least every 5 s. Paused, the engine does not tick.
    private func applyTickInterval() {
        let watched = isPlaying && controlsOnScreen && (pageOnScreen || isFullscreen) && applicationActive
        backend?.setTickInterval(watched ? Self.visibleTickInterval : Self.quietTickInterval)
    }

    nonisolated static let visibleTickInterval = 0.5
    nonisolated static let quietTickInterval = 2.5

    init(stores: AppDataStores, backend: MediaBackend? = nil) {
        self.backend = backend
        preferences = stores.preferences
        mediaProxy = stores.mediaProxy
        mediaCache = stores.mediaCache
        mediaServer = stores.mediaServer
        mediaDownloads = stores.mediaDownloads
        if let backend { attach(backend) }
        // In the background nobody sees the position: tick quietly (Now Playing
        // computes elapsed time from the rate).
        ApplicationActivity.observe { [weak self] active in
            Task { @MainActor in
                guard let self else { return }
                let returning = active && !self.applicationActive
                self.applicationActive = active
                self.applyTickInterval()
                if returning { await self.resumeAfterBackground() }
            }
        }
    }

    /// Routes the backend's events to this model.
    private func attach(_ engine: MediaBackend) {
        engine.onTick = { [weak self] seconds in self?.tick(seconds) }
        startWatchdog()
        engine.onEnded = { [weak self] in self?.finished() }
        engine.onFailure = { [weak self] message in self?.playerFailed(message) }
        engine.onUnplayableMedia = { [weak self] message in self?.mediaUnplayable(message) }
        engine.onActivityChange = { [weak self] activity in self?.activityChanged(activity) }
        engine.onExternalEvent = { [weak self] event in self?.externalEvent(event) }
        applyTickInterval()
        engine.onPictureInPictureChange = { [weak self] state in self?.pictureInPictureState = state }
        engine.onRestoreFromPictureInPicture = { [weak self] in self?.onRestoreRequested?() }
        pictureInPictureState = engine.pictureInPictureState
    }

    // MARK: download health

    struct DownloadHealthRow: Identifiable, Equatable {
        var id: String
        var title: String
        var summary: String
        var lastIssue: String?
        var issueIsRecent: Bool
    }

    /// Every track has at least 5 s (or the rest) downloaded from `position` on.
    private func hasLocalDataAhead(of position: Double) -> Bool {
        let tracks = pipeline.tracks
        guard !tracks.isEmpty else { return false }
        return tracks.allSatisfy { track in
            track.isComplete || Self.margin(ahead: position, in: track.timeRanges(for: .download)) >= 5
        }
    }

    /// Seconds downloaded without a gap from the playhead on, per track.
    nonisolated static func margin(ahead position: Double, in ranges: [ClosedRange<Double>]) -> Double {
        guard let current = ranges.first(where: { $0.contains(position) || ($0.lowerBound > position && $0.lowerBound - position < 0.5) }) else { return 0 }
        return max(0, current.upperBound - position)
    }

    var downloadHealth: [DownloadHealthRow] {
        pipeline.tracks.compactMap { track -> DownloadHealthRow? in
            guard let health = track.health else { return nil }
            let margin = Self.margin(ahead: playbackTime, in: track.timeRanges(for: .download))
            var parts: [String] = []
            parts.append(health.throughput > 0 ? "\(Int(health.throughput * 8 / 1_000)) kbps" : "no transfer yet")
            if let media = health.mediaRate { parts.append("media \(Int(media * 8 / 1_000)) kbps") }
            if let factor = health.speedFactor { parts.append(String(format: "%.1f\u{00D7} realtime", factor)) }
            parts.append(track.isComplete ? "complete" : String(format: "%.0f s ahead", margin))
            if health.refreshes > 0 { parts.append("\(health.refreshes) refreshes") }
            let issue = health.lastIssue.map { kind -> String in
                let age = health.lastIssueAt.map { Int(Date().timeIntervalSince($0)) }.map { " \($0) s ago" } ?? ""
                return "Last issue: \(kind.rawValue)\(age)\(health.lastIssueDetail.map { " (\($0))" } ?? "")"
            }
            let recent = health.lastIssueAt.map { Date().timeIntervalSince($0) < 30 } ?? false
            return DownloadHealthRow(id: track.role.rawValue, title: track.role.rawValue.capitalized,
                                     summary: parts.joined(separator: " \u{00B7} "), lastIssue: issue, issueIsRecent: recent)
        }
    }

    // MARK: real state

    /// The engine's state is the truth: a pause the system makes (an
    /// interruption, a route change, a torn-down view) shows as paused.
    private func activityChanged(_ activity: PlaybackActivity) {
        defer { publishNowPlaying() }
        let margins = pipeline.tracks.map { track in
            "\(track.role.rawValue)=\(String(format: "%.1f", Self.margin(ahead: playbackTime, in: track.timeRanges(for: .download))))"
        }.joined(separator: ",")
        Logger.player.notice("playback_activity state=\(String(describing: activity), privacy: .public) position=\(self.playbackTime) margin=\(margins, privacy: .public)")
        let started = activity.wantsToPlay && !isPlaying
        isPlaying = activity.wantsToPlay
        if activity != engineActivity { engineActivity = activity }
        if started { onStartedPlaying?() }
        if watchdog == nil { startWatchdog() }
    }

    /// Watches that playback which should advance does: "playing" with a
    /// clock that has not moved for 2 s shows as stalled; after 4 s the
    /// loopback server is checked (iOS reclaims a suspended app's sockets);
    /// after 6 s the item is reloaded from the cache at the same position.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var lastTime = -1.0
            var since = ContinuousClock.now
            var checkedServer = false
            var recovered = false
            var idle = false
            var lastActivity = PlaybackActivity.paused
            while !Task.isCancelled {
                // Paused or stopped, there is nothing to watch closely: wake rarely.
                try? await Task.sleep(for: .milliseconds(idle ? 2_000 : 500))
                guard let self, let backend = self.backend else { idle = true; continue }
                idle = !backend.activity.wantsToPlay
                let activity = backend.activity
                if activity != self.engineActivity { self.engineActivity = activity }
                let time = backend.currentTime
                // Every change of state starts a fresh window: time spent buffering
                // (the clock rightly still) is not "playing without advancing".
                let changed = activity != lastActivity
                lastActivity = activity
                if changed || !activity.wantsToPlay || abs(time - lastTime) > 0.01 {
                    lastTime = time
                    since = .now
                    checkedServer = false
                    recovered = false
                    if self.watchdogStalled {
                        self.watchdogStalled = false
                        Logger.player.notice("playback_advancing_again position=\(time)")
                    }
                    continue
                }
                let stuck = since.duration(to: .now)
                if activity == .playing, stuck > .seconds(2), !self.watchdogStalled {
                    self.watchdogStalled = true
                    Logger.player.error("playback_not_advancing position=\(time) since_ms=\(Int(stuck / .milliseconds(1)))")
                }
                if stuck > .seconds(4), !checkedServer, self.currentPlayback?.origin == .mediaCache {
                    checkedServer = true
                    // Never awaited here: a check that hangs must not stop the
                    // watchdog (a stall it set would then never clear).
                    let server = self.mediaServer
                    Task { _ = try? await server.ensureListening() }
                }
                // Waiting although the cache holds what comes next: the player
                // lost its connection (suspension, sleep), not the network.
                if case .waiting = activity, stuck > .seconds(12), !recovered, !self.isRecovering,
                   self.currentPlayback?.origin == .mediaCache, self.hasLocalDataAhead(of: time) {
                    recovered = true
                    Logger.player.error("waiting_with_local_data position=\(time)")
                    self.playerFailed("Playback was waiting although the video is downloaded")
                }
                if self.watchdogStalled, stuck > .seconds(6), !recovered, !self.isRecovering {
                    recovered = true
                    self.playerFailed("Playback stopped advancing")
                }
            }
        }
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
        Logger.player.info("load_started plugin=\(runtime.id, privacy: .public) host=\(LogRedaction.redact(host), privacy: .public) attempt=\(reloadAttempt)")
        let signpost = OSSignposter.player.beginInterval("LoadContent", id: OSSignposter.player.makeSignpostID(), "plugin=\(runtime.id, privacy: .public) host=\(LogRedaction.redact(host), privacy: .public)")
        defer { OSSignposter.player.endInterval("LoadContent", signpost, "error=\(self.errorMessage != nil)") }
        teardown()
        loadedURL = sourceURL
        self.details = details
        declaredDuration = Double(details.item.duration ?? 0)
        duration = declaredDuration
        self.runtime = runtime
        self.library = library
        errorMessage = nil
        preparationMessage = nil
        isPreparing = true
        defer { isPreparing = false; preparationMessage = nil }

        let maxHeight = preferences.defaults.object(forKey: PlaybackPreferenceKey.maxVideoHeight) as? Int ?? 1080
        let engine = backend ?? makeBackend()
        backend = engine
        attach(engine)
        startup = PlaybackStartupTrace()
        let preferredLanguage = Locale.current.language.languageCode?.identifier
        let splitAudioSources = PlaybackSelector.audioChoices(details.audioSources)
        selectedAudioSource = PlaybackSelector.bestAudio(details.audioSources, language: preferredLanguage,
                                                         prefersDescriptions: MediaAccessibilityPreferences.prefersAudioDescriptions)
        let sourceTypes = Dictionary(grouping: details.videoSources, by: \.pluginType)
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        Logger.player.info("source_inventory types=\(sourceTypes, privacy: .public) video=\(PlaybackSelector.inventory(details.videoSources), privacy: .public) audio=\(PlaybackSelector.inventory(details.audioSources), privacy: .public)")
        options = PlaybackSelector.options(for: details, preferredLanguage: preferredLanguage)
        guard let choice = PlaybackSelector.best(options, maxHeight: maxHeight) else {
            Logger.player.error("no_playable_source options=\(self.options.count)")
            errorMessage = options.isEmpty
                ? "This video has no source this device can play (it offers only formats the player does not support, such as DASH or DRM-protected streams)."
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

        // The platform player chooses subtitles per the system's settings; the
        // app's "show subtitles" setting asks for the viewer's language on top.
        if preferences.defaults.bool(forKey: PlaybackPreferenceKey.showSubtitlesByDefault),
           selectedTrack(ofKind: .subtitles) == nil, let track = preferredSubtitleTrack() {
            selectTrack(track)
        }
        await loadChapters(sourceURL: sourceURL)
        await startTracker()
    }

    /// Switches to another source. `selected` keeps naming the stream that is
    /// playing until the new one is confirmed (loaded and, when playing, its
    /// first frames shown); meanwhile `pendingOption` names the choice. On
    /// failure the old stream keeps playing and the error is shown.
    func select(_ option: PlaybackOption) async {
        // Choosing the stream that is playing cancels a pending switch.
        if option.id == selected?.id {
            if pendingOption != nil || pendingAudioSource != nil { cancelPendingSwitch() }
            return
        }
        let position = backend?.currentTime
        let autoplay = backend?.isPlaying ?? true
        var choice = option
        if choice.audio != nil, let selectedAudioSource { choice.audio = selectedAudioSource }
        pendingOption = option
        defer { if pendingOption?.id == option.id { pendingOption = nil } }
        guard await play(choice, resumeAt: position, duration: details?.item.duration,
                         autoplay: autoplay, normalizeSavedPosition: false) else {
            announceKept(instead: option.label, pending: pendingOption?.id == option.id)
            return
        }
        refreshAudioSources(for: choice)
        switchAnnouncement = SwitchAnnouncement("Now playing \(option.label)")
    }

    /// Switches the audio stream, confirming it the same way as `select`.
    func selectAudioSource(_ source: MediaSource) async {
        if source.id == selectedAudioSource?.id, pendingOption == nil {
            if pendingAudioSource != nil { cancelPendingSwitch() }
            return
        }
        guard var choice = selected else { return }
        let position = backend?.currentTime
        let autoplay = backend?.isPlaying ?? true
        guard choice.audio != nil else { return }
        choice.audio = source
        pendingAudioSource = source
        defer { if pendingAudioSource?.id == source.id { pendingAudioSource = nil } }
        guard await play(choice, resumeAt: position, duration: details?.item.duration,
                         autoplay: autoplay, normalizeSavedPosition: false) else {
            announceKept(instead: PlaybackSelector.audioLabel(for: source), pending: pendingAudioSource?.id == source.id)
            return
        }
        selectedAudioSource = source
        switchAnnouncement = SwitchAnnouncement("Now playing audio \(PlaybackSelector.audioLabel(for: source))")
    }

    /// A switch that did not take effect: says so, unless the viewer cancelled
    /// it or chose something else meanwhile (`pending` is false then).
    private func announceKept(instead choice: String, pending: Bool) {
        guard pending else { return }
        let current = selected?.label ?? "the current stream"
        switchAnnouncement = SwitchAnnouncement("Could not switch to \(choice). \(current) keeps playing.")
    }

    /// Cancels the pending stream switch: the stream that is playing stays
    /// (it is put back if the new one had already replaced it).
    func cancelPendingSwitch() {
        cancelledSwitchGeneration = playGeneration
        playGeneration &+= 1
        pendingOption = nil
        pendingAudioSource = nil
    }

    struct PlaybackNotConfirmed: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { "The new stream could not play (\(reason)), so the previous one was kept. Try again." }
    }

    /// The new stream had replaced the playing one when the user cancelled the
    /// switch: the previous stream is loaded back where playback is.
    private func restoreAfterCancel(_ generation: Int, on backend: MediaBackend, resumeAt: Double?, autoplay: Bool) async {
        guard cancelledSwitchGeneration == generation, self.backend === backend, let previous = currentPlayback else { return }
        cancelledSwitchGeneration = nil
        let position = backend.currentTime > 0 ? backend.currentTime : resumeAt
        try? await backend.load(previous.request, resumeAt: position, autoplay: autoplay)
        backend.setPlaybackRate(playbackRate)
    }

    /// After a load, waits until the new item is visibly playing: its time
    /// advances while the player plays. A paused load is confirmed by loading.
    /// There is no deadline: under download-first a slow network means the
    /// switch is still pending (the spinner stays), not that it failed. Only a
    /// failure the backend reports ends the wait as a failed switch, and the
    /// checkmark never moves without confirmation (no optimistic UI).
    private func confirmPlayback(of backend: MediaBackend, autoplay: Bool, generation: Int) async throws {
        guard autoplay, !confirmsSwitchOnLoadForTesting else { return }
        confirmingGeneration = generation
        confirmationFailure = nil
        defer { if confirmingGeneration == generation { confirmingGeneration = nil } }
        let start = backend.currentTime
        while true {
            try Task.checkCancellation()
            guard generation == playGeneration else { throw MediaBackendLoadError.superseded }
            if let failure = confirmationFailure {
                Logger.player.notice("switch_failed generation=\(generation)")
                throw PlaybackNotConfirmed(reason: failure)
            }
            if backend.isPlaying, backend.currentTime > start + 0.05 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
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
    /// The subtitle track in the viewer's language, else the first one.
    private func preferredSubtitleTrack() -> MediaTrack? {
        let subtitles = tracks.filter { $0.kind == .subtitles }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return subtitles.first { $0.language?.hasPrefix(language) == true } ?? subtitles.first
    }

    /// Subtitles on (the viewer's language) or off: the captions key command.
    func toggleCaptions() {
        if selectedTrack(ofKind: .subtitles) != nil {
            selectTrack(nil)
        } else if let track = preferredSubtitleTrack() {
            selectTrack(track)
        }
    }
    func startPictureInPicture() { backend?.startPictureInPicture() }
    func stopPictureInPicture() { backend?.stopPictureInPicture() }
    func toggleFullscreen() {
        Logger.player.notice("fullscreen_toggle fullscreen=\(self.isFullscreen) presenter=\(self.presentFullscreenAction != nil)")
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
    /// `owner` is the surface presenting full screen. A surface torn down
    /// after its replacement installed itself (a reload rebuilds the surface)
    /// must not remove the replacement's presenter: removal names its owner.
    func installFullscreenPresenter(owner: AnyObject, present: @escaping () -> Void, dismiss: @escaping () -> Void) {
        fullscreenPresenterOwner = owner
        presentFullscreenAction = present
        dismissFullscreenAction = dismiss
    }
    /// Installs `owner` only when no surface presents full screen: a surface
    /// being replaced, updated late, must not take it back from its replacement.
    func installFullscreenPresenterIfNone(owner: AnyObject, present: @escaping () -> Void, dismiss: @escaping () -> Void) {
        guard fullscreenPresenterOwner == nil else { return }
        installFullscreenPresenter(owner: owner, present: present, dismiss: dismiss)
    }
    func removeFullscreenPresenter(owner: AnyObject) {
        guard fullscreenPresenterOwner === owner else { return }
        fullscreenPresenterOwner = nil
        presentFullscreenAction = nil
        dismissFullscreenAction = nil
    }
    func fullscreenDidChange(_ fullscreen: Bool) { isFullscreen = fullscreen }
    func togglePlayback() {
        if isPlaying { pauseByUser() } else { playByUser() }
    }

    // MARK: intent
    //
    // The one place playback is started or stopped for the user, whichever
    // control they used: the app's, the lock screen, Control Center,
    // headphones, CarPlay, Siri, Picture in Picture or the system player UI
    // (`externalEvent`). Intent (`playbackRequested`), the engine, Now
    // Playing and history change together; the UI shows the engine's state.

    /// The user wants it playing.
    func playByUser() {
        guard let backend else { return }
        playbackRequested = true
        if !backend.activity.wantsToPlay {
            backend.play()
            if playbackRate != 1 { backend.setPlaybackRate(playbackRate) }
        }
        isPlaying = true
        publishNowPlaying()
    }

    /// Records the position now (unthrottled): after a seek, a stream switch,
    /// and before the app goes to the background, so a crash right after
    /// never restores an older position. Ticks record at most every 5 s.
    func recordProgressNow(at position: Double? = nil) {
        guard let details, let library else { return }
        let seconds = position ?? backend?.currentTime ?? playbackTime
        guard seconds.isFinite, seconds > 1, !didFinishCurrentItem else { return }
        library.recordProgress(SavedVideo(details.item), seconds: seconds)
        lastHistoryWrite = Date()
    }

    /// The user wants it paused. A pause is where progress is worth syncing;
    /// ticks only update the library (see LibraryStore.recordProgress).
    func pauseByUser() {
        guard let backend else { return }
        playbackRequested = false
        if backend.activity.wantsToPlay { backend.pause() }
        isPlaying = false
        let seconds = backend.currentTime
        if seconds.isFinite, seconds > 1, let details, let library {
            library.recordProgress(SavedVideo(details.item), seconds: seconds)
            library.syncHistory()
        }
        publishNowPlaying()
    }

    /// A call or another app took the audio: playback stopped but the user
    /// still wants it (`playbackRequested` unchanged) until the interruption
    /// ends; the UI shows it paused meanwhile.
    private(set) var isInterrupted = false

    private func externalEvent(_ event: ExternalPlaybackEvent) {
        Logger.player.notice("external_event \(String(describing: event), privacy: .public)")
        switch event {
        case .play: playByUser()
        case .pause: pauseByUser()
        case .togglePlayPause: togglePlayback()
        case .seek(let seconds): seek(to: seconds, coalescing: false)
        case .skip(let seconds): skip(by: seconds)
        case .interruptionBegan:
            isInterrupted = true
            isPlaying = false
            publishNowPlaying()
        case .interruptionEnded(let shouldResume):
            isInterrupted = false
            if shouldResume, playbackRequested { playByUser() }
            else if playbackRequested { pauseByUser() }
        case .outputLost:
            pauseByUser()
        }
    }

    /// What the lock screen and Control Center show.
    private func publishNowPlaying() {
        guard let backend, let details else { return }
        backend.updateNowPlaying(NowPlaying(title: details.item.name, duration: authoritativeDuration,
                                            position: backend.currentTime,
                                            rate: backend.activity == .playing ? playbackRate : 0))
    }
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { backend?.setPlaybackRate(rate) }
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
        recordProgressNow(at: target)
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
        playbackTime = 0
        playByUser()
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
            Logger.player.info("source_selected kind=\(String(describing: option.kind), privacy: .public) videoType=\(option.video.pluginType, privacy: .public) height=\(option.video.height) videoBitrate=\(option.video.bitrate) audioBitrate=\(option.audio?.bitrate ?? 0) videoHost=\(LogRedaction.redact(videoHost), privacy: .public) audioHost=\(LogRedaction.redact(audioHost), privacy: .public)")
            startup?.mark(.selected)
            let playback: LocalPlayback
            if let resolveForTesting = localPlaybackForTesting {
                playback = try await resolveForTesting(option)
            } else {
                switch option.kind {
                case .live:
                    let (session, local) = try await startHLSDownload(option, live: true)
                    newSession = session
                    playback = local
                case .hls:
                    let (session, local) = try await startHLSDownload(option)
                    newSession = session
                    playback = local
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
            // A teardown or a newer load while this one was resolving retires
            // this play: loading the old engine now would start a second,
            // invisible player (doubled audio).
            // A switch resumes where playback is now: the old stream kept
            // playing while the new one was prepared.
            if !normalizeSavedPosition, option.kind != .live, currentPlayback != nil, backend.currentTime > 0 {
                start = backend.currentTime
            }
            guard generation == playGeneration, self.backend === backend else { throw MediaBackendLoadError.superseded }
            try await backend.load(playback.request, resumeAt: start, autoplay: autoplay)
            // Installed in the player: unless the engine was torn down or the
            // user cancelled this switch, it finishes (it is what plays).
            guard self.backend === backend else {
                backend.stop()
                throw MediaBackendLoadError.superseded
            }
            if cancelledSwitchGeneration == generation {
                await restoreAfterCancel(generation, on: backend, resumeAt: resumeAt, autoplay: autoplay)
                throw MediaBackendLoadError.superseded
            }
            startup?.mark(.playerLoaded)
            do {
                try await confirmPlayback(of: backend, autoplay: autoplay, generation: generation)
            } catch MediaBackendLoadError.superseded {
                await restoreAfterCancel(generation, on: backend, resumeAt: resumeAt, autoplay: autoplay)
                newPipelineTask?.cancel()
                throw MediaBackendLoadError.superseded
            } catch let failure as PlaybackNotConfirmed {
                // The new item replaced the old one in the player but never
                // played: put the previous stream back where it was.
                if let previous = currentPlayback {
                    try? await backend.load(previous.request, resumeAt: resumeAt, autoplay: autoplay)
                    backend.setPlaybackRate(playbackRate)
                }
                newPipelineTask?.cancel()
                throw failure
            }
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
            // Media selections belong to the replaced item: the subtitles the
            // viewer chose carry over to the new stream when it has them.
            let previousSubtitle = embeddedSubtitleChoice
            embeddedSubtitleChoice = nil
            if let previousSubtitle, let match = tracks.first(where: {
                $0.kind == .subtitles && $0.label == previousSubtitle.label && $0.language == previousSubtitle.language
            }) {
                selectTrack(match)
            }
            selected = option
            if generation == playGeneration { errorMessage = nil }
            recordProgressNow()
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
        var video = try trackSpec(option.video, role: muxed ? .muxed : .video, runtime: runtime,
                                  sourceURL: sourceURL, declaredDuration: declared)
        // A video the transcode stage has re-encoded plays from its output; the
        // original was consumed. It is complete, so nothing is fetched.
        let transcoded = TranscodeStage.transcodedIdentity(video.identity)
        if await mediaCache.isComplete(identity: transcoded) {
            video.identity = transcoded
            video.indexHint = nil
            video.codec = ""
            video.container = "video/mp4"
            video.isTranscoded = true
        }
        let audio = try option.audio.map {
            try trackSpec($0, role: .audio, runtime: runtime, sourceURL: sourceURL, declaredDuration: declared)
        }
        return try await VODSession.start(video: video, audio: audio, subtitles: localSubtitles(),
                                          downloads: mediaDownloads, server: mediaServer,
                                          info: downloadInfo(live: false))
    }

    /// Starts downloading an on-demand HLS presentation into the media cache
    /// (playlists rewritten to local URIs, every segment cached).
    /// `live`: record a live stream into the cache as it is published (see
    /// `LiveHLSRecorder`) and play the recording.
    private func startHLSDownload(_ option: PlaybackOption, live: Bool = false) async throws -> (VODSession, LocalPlayback) {
        guard let runtime, let sourceURL = loadedURL, let url = URL(string: option.video.url) else {
            throw PluginError.execution("The video's plugin is no longer available")
        }
        let maxHeight = preferences.defaults.object(forKey: PlaybackPreferenceKey.maxVideoHeight) as? Int ?? 1080
        let source = option.video
        let spec = HLSPresentationSpec(
            identity: [live ? "live-v1" : "hls-v1", runtime.id, sourceURL, source.name].joined(separator: "|"),
            url: url, signer: Self.urlSigner(for: source, runtime: runtime),
            refresh: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.refreshedURLSigner(for: source)
            },
            maxHeight: maxHeight, language: Locale.current.language.languageCode?.identifier
        )
        return live
            ? try await VODSession.start(live: spec, downloads: mediaDownloads, server: mediaServer,
                                         transport: PluginContentTransport(runtime: runtime), info: downloadInfo(live: true))
            : try await VODSession.start(hls: spec, downloads: mediaDownloads, server: mediaServer,
                                         transport: PluginContentTransport(runtime: runtime), subtitles: localSubtitles(), info: downloadInfo(live: false))
    }

    /// How the downloads list names this video.
    private func downloadInfo(live: Bool) -> DownloadInfo? {
        guard let details, let runtime, let sourceURL = loadedURL else { return nil }
        return DownloadInfo(id: "\(runtime.id)|\(sourceURL)", title: details.item.name, contentURL: sourceURL,
                            thumbnail: details.item.thumbnailURL, isLive: live)
    }

    /// The one place playback invokes a plugin's request modifier, so how
    /// plugins are called (plugin containment) can change here alone.
    nonisolated private static func modifyRequest(runtime: PluginRuntime, modifier handle: Int, url: URL,
                                                  headers: [String: String]) async throws -> ContainedRequest {
        try await runtime.modifyRequest(handle: handle, url: url, headers: headers)
    }

    /// Signs any URL of an HLS presentation through the source's request
    /// modifier (once per request), or plainly.
    nonisolated private static func urlSigner(for source: MediaSource, runtime: PluginRuntime) -> UpstreamURLSigner {
        guard let modifier = source.requestModifier else { return .plain() }
        let handle = modifier.handle
        return UpstreamURLSigner { url, range in
            var headers: [String: String] = [:]
            if let range { headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound - 1)" }
            return try await modifyRequest(runtime: runtime, modifier: handle, url: url, headers: headers).urlRequest
        }
    }

    private func refreshedURLSigner(for source: MediaSource) async throws -> (UpstreamURLSigner, URL) {
        guard let runtime, let sourceURL = loadedURL else { throw CancellationError() }
        let data = try await runtime.callRaw("getContentDetails", [sourceURL], kind: "details")
        guard case .video(let refreshed) = try await PluginRuntime.decodeOffMain(ContentDetails.self, from: data) else {
            throw PluginError.execution("The plugin stopped returning video details")
        }
        let candidates = ([refreshed.live, refreshed.hls].compactMap { $0 } + refreshed.videoSources).filter(\.isHLS)
        guard let match = candidates.first(where: { $0.name == source.name }) ?? candidates.first else {
            throw PluginError.execution("The plugin no longer offers this stream")
        }
        guard let url = URL(string: match.url) else { throw PluginError.execution("Invalid stream URL") }
        return (Self.urlSigner(for: match, runtime: runtime), url)
    }

    private func trackSpec(_ source: MediaSource, role: MediaTrackRole, runtime: PluginRuntime,
                           sourceURL: String, declaredDuration: Double?) throws -> VODTrackSpec {
        guard let signer = Self.signer(for: source, runtime: runtime) else {
            throw PluginError.execution("Invalid media URL")
        }
        // The plugin's format ID names the bytes exactly; names and bitrates can
        // change between details calls for the same format.
        let format = source.formatID.map { ["format", $0, source.container, source.language] }
            ?? [source.name, source.container, source.codec, String(source.bitrate), "\(source.width)x\(source.height)", source.language]
        let identity = (["vod-v2", runtime.id, sourceURL, role.rawValue, source.pluginType] + format).joined(separator: "|")
        return VODTrackSpec(
            role: role, identity: identity, signer: signer,
            refresh: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.refreshedSigner(for: source)
            },
            indexHint: source.indexRange, container: source.container, codec: source.codec,
            bandwidth: source.bitrate, width: source.width, height: source.height,
            declaredDuration: source.duration > 0 ? Double(source.duration) : declaredDuration,
            transport: PluginContentTransport(runtime: runtime),
            rendition: role == .audio ? HLSPlaylist.Rendition(
                groupID: "audio", name: PlaybackSelector.audioLabel(for: source),
                language: Self.languageTag(source.language), isDefault: true, uri: nil, autoselect: true,
                characteristics: source.characteristics.isEmpty ? nil : source.characteristics.joined(separator: ",")
            ) : nil
        )
    }

    /// Builds each upstream request through the plugin's request modifier,
    /// once per request as Grayjay does (YouTube's modifier carries the range
    /// in the URL and numbers the requests).
    nonisolated private static func signer(for source: MediaSource, runtime: PluginRuntime) -> UpstreamRequestSigner? {
        guard let url = URL(string: source.url), url.scheme == "https" || url.scheme == "http" else { return nil }
        guard let modifier = source.requestModifier else { return .plain(url) }
        let handle = modifier.handle
        return UpstreamRequestSigner { range in
            let rangeValue = "\(range.lowerBound)-\(range.upperBound - 1)"
            let modified = try await modifyRequest(runtime: runtime, modifier: handle, url: url,
                                                   headers: ["Range": "bytes=" + rangeValue])
            let target = modified.url
            var request = modified.urlRequest
            let headers = modified.headers
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
                if self.vodSession === session { self.setIfChanged(\.pipeline, snapshot) }
            }
        }
    }

    private func stopMedia(session: VODSession?, presentation: URL?) async {
        if let session { await session.stop() }
        if let presentation { await mediaProxy.release(presentation) }
    }

    /// The player failed while playing local data (the loopback server only
    /// ever waits for bytes, so this is the player giving up, e.g. on a
    /// This system cannot decode the chosen format: reloading would fail the
    /// same way, so the user is told which format and what to do instead.
    private func mediaUnplayable(_ message: String) {
        if confirmingGeneration == playGeneration {
            confirmationFailure = message
            return
        }
        unplayable = true
        let codec = selected.map { MediaFormatNames.describe(codec: $0.video.codec, container: $0.video.container) } ?? "this format"
        Logger.player.error("media_unplayable codec=\(codec, privacy: .public) message=\(message)")
        errorMessage = "This device can't play \(codec). Choose another quality from the player's menu."
    }

    /// timeout during a long outage). Reload the same local media at the
    /// same position instead of showing an error; the download carries on.
    private func playerFailed(_ message: String) {
        if confirmingGeneration == playGeneration {
            // The stream being switched to failed: the switch restores the previous one.
            confirmationFailure = message
            return
        }
        // Away from the foreground (a suspension may have closed the sockets
        // it serves from), local media is rebuilt when the app is back, after
        // its listeners are: reloading now would fail the same way.
        if !ApplicationActivity.isActive, currentPlayback != nil {
            Logger.player.notice("local_playback_failed_in_background message=\(message)")
            recoverOnResume = true
            return
        }
        guard let playback = currentPlayback, playback.origin == .mediaCache || playback.origin == .generatedMedia else {
            errorMessage = message
            return
        }
        localRecoveryAttempts += 1
        let attempt = localRecoveryAttempts
        isRecovering = true
        let position = backend?.currentTime ?? playbackTime
        let autoplay = playbackRequested
        let generation = playGeneration
        Logger.player.notice("local_playback_recover attempt=\(attempt) position=\(position) reason=\(message, privacy: .public)")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(30, Double(attempt * attempt))))
            guard let self else { return }
            // Every way out ends the recovery: a flag left set showed
            // "Reconnecting" over a player that was playing again.
            defer { if generation == self.playGeneration { self.isRecovering = false } }
            guard generation == self.playGeneration, let backend = self.backend else { return }
            do {
                // The loopback server may have lost its socket (app suspended).
                if playback.origin == .mediaCache { _ = try? await self.mediaServer.ensureListening() }
                try await backend.load(playback.request, resumeAt: position > 0 ? position : nil, autoplay: autoplay)
                backend.setPlaybackRate(self.playbackRate)
            } catch is CancellationError {
            } catch MediaBackendLoadError.superseded {
            } catch {
                Logger.player.error("local_playback_recover_failed attempt=\(attempt) message=\(error.localizedDescription)")
                guard generation == self.playGeneration else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: resolving sources

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
            identity: [runtime.id, loadedURL ?? "", "pair", video.formatID ?? video.name, String(video.height), video.codec,
                       audio.formatID ?? audio.name, audio.language, String(audio.bitrate)].joined(separator: "|"),
            subtitles: localSubtitles(),
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
            identity: [runtime.id, loadedURL ?? "", "single", source.formatID ?? source.name, String(source.height), source.codec,
                       source.language, String(source.bitrate)].joined(separator: "|"),
            subtitles: localSubtitles(),
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

    /// Writes `value` only when it differs: an `@Observable` setter notifies
    /// on every write, so an equal value would still redraw its readers.
    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<PlayerModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        // Only what changed is written (`setIfChanged`): every write of an
        // observed value wakes what reads it, equal or not.
        setIfChanged(\.duration, authoritativeDuration)
        let activity = backend?.activity ?? .paused
        setIfChanged(\.engineActivity, activity)
        setIfChanged(\.isPlaying, activity.wantsToPlay)
        if isPlaying, seconds > playbackTime {
            startup?.firstFrame(at: seconds)
            if seconds - playbackTime < 2 { localRecoveryAttempts = 0 }
        }
        setIfChanged(\.playbackTime, seconds)
        if Date().timeIntervalSince(lastHistoryWrite) >= 4.5, let details, let library, seconds > 1 {
            lastHistoryWrite = Date()
            library.recordProgress(SavedVideo(details.item), seconds: seconds)
        }
        refreshBufferingMessage()
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

    /// The plugin's subtitles, offered to the player as SUBTITLES renditions
    /// of the local presentation. Each is fetched (through the plugin) only
    /// when the player first asks for it.
    private func localSubtitles() -> [LocalSubtitle] {
        guard let runtime, let details else { return [] }
        return details.subtitles.map { source in
            LocalSubtitle(name: source.name.isEmpty ? (source.language ?? "Subtitles") : source.name,
                          language: Self.languageTag(source.language),
                          characteristics: Self.describesSound(source.name)
                              ? "public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound" : nil,
                          webVTT: { try await Self.loadSubtitle(source, runtime: runtime) })
        }
    }

    /// A BCP 47 tag ("en", "pt-BR"), or nil for anything else a plugin calls a language.
    nonisolated static func languageTag(_ language: String?) -> String? {
        guard let language, language.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil
        else { return nil }
        return language
    }

    /// Subtitles for the deaf and hard of hearing (they describe sounds, not only speech).
    nonisolated static func describesSound(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["sdh", "[cc]", "(cc)", "closed caption", "hard of hearing"].contains { lowered.contains($0) }
    }

    /// A subtitle's text as WebVTT: the plugin's loader, else its URL fetched
    /// through the plugin's contained content session.
    nonisolated private static func loadSubtitle(_ source: SubtitleSource, runtime: PluginRuntime) async throws -> String {
        var text: String?
        if let handle = source.getSubtitlesHandle {
            for attempt in 0..<3 where text?.isEmpty ?? true {
                if attempt > 0 { try await Task.sleep(for: .milliseconds(500)) }
                if let data = try? await runtime.callHandle(handle, "getSubtitles") {
                    text = try? await PluginRuntime.decodeOffMain(String.self, from: data)
                }
            }
        }
        // Some plugins expose both a convenience loader and the underlying URL.
        // A generated loader can expire independently, so fall back to the URL.
        if text?.isEmpty ?? true, let url = source.url.flatMap(URL.init(string:)) {
            text = String(data: try await runtime.fetchReferenced(url), encoding: .utf8)
        }
        guard let text, !text.isEmpty else { throw PluginError.execution("The subtitles could not be loaded") }
        return LocalSubtitle.webVTT(from: text)
    }

    /// Chapters and skippable segments, when the plugin offers them. A failure
    /// leaves the bar without chapters; playback does not depend on them.
    private func loadChapters(sourceURL: String) async {
        guard let runtime, runtime.has("getContentChapters") else { return }
        do {
            let data = try await runtime.callRaw("getContentChapters", [sourceURL, NSNull()])
            let decoded = try await PluginRuntime.decodeOffMain([PlaybackChapter].self, from: data)
            guard loadedURL == sourceURL else { return }
            chapters = decoded.filter { $0.timeEnd > $0.timeStart }.sorted { $0.timeStart < $1.timeStart }
        } catch {
            Logger.player.notice("chapters_unavailable message=\(error.localizedDescription)")
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

    /// After moving between the inline and full-screen surfaces. The same
    /// player moves without pausing, so normally nothing is done: touching
    /// the rate (or the audio session behind `play`) while it plays is
    /// audible. Only if a surface did pause it is playback resumed.
    func restorePlaybackAfterSurfaceTransfer() {
        guard playbackRequested, let backend, backend.activity == .paused else { return }
        playByUser()
    }

    /// The player is gone for good (its tab or window closed): also drops what
    /// its surface prepared, whose controls refer back to this model.
    func close() {
        teardown()
        preparedFullscreen = nil
    }

    func teardown() {
        // Every load in flight belongs to the media being torn down.
        playGeneration &+= 1
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
        watchdog?.cancel()
        watchdog = nil
        watchdogStalled = false
        engineActivity = .paused
        recoverOnResume = false
        unplayable = false
        pictureInPictureState = .unsupported
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
        chapters = []
        isRecovering = false
        playbackTime = 0; duration = 0; declaredDuration = 0; isPlaying = false; isFullscreen = false
        playbackRequested = false
        embeddedSubtitleChoice = nil; switchAnnouncement = nil
        didFinishCurrentItem = false
    }
}
