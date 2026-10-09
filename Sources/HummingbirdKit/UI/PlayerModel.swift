import Foundation
import Observation
import SwiftOpenUI
import AdvancedVideoPlayerKit

enum SubtitleColorChoice: String, CaseIterable, Sendable {
    case white, yellow, green, cyan

    var label: String { rawValue.capitalized }
    var color: Color {
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

@MainActor
@Observable
final class PlayerModel: AdvancedVideoPlayerControlling {
    /// The platform player. The view layer reads it to draw the video surface (see `PlayerSurface`).
    private(set) var backend: MediaBackend?
    var hasMedia: Bool { backend != nil && selected != nil }
    private(set) var loadedURL: String?
    private(set) var options: [PlaybackOption] = []
    private(set) var selected: PlaybackOption?
    private(set) var errorMessage: String?
    private(set) var isPreparing = false
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
    private(set) var subtitleColorChoice = SubtitleColorChoice(
        rawValue: UserDefaults.standard.string(forKey: "subtitleColor") ?? "white"
    ) ?? .white
    private(set) var subtitleSizeChoice = SubtitleSizeChoice(
        rawValue: UserDefaults.standard.double(forKey: "subtitleSize")
    ) ?? .medium
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

    init(backend: MediaBackend? = nil) {
        self.backend = backend
    }

    // MARK: loading

    func load(details: VideoDetails, runtime: PluginRuntime, library: LibraryStore, sourceURL: String) async {
        teardown()
        loadedURL = sourceURL
        self.details = details
        self.subtitleSources = details.subtitles
        self.runtime = runtime
        self.library = library
        errorMessage = nil
        isPreparing = true
        defer { isPreparing = false }

        let maxHeight = UserDefaults.standard.object(forKey: "maxVideoHeight") as? Int ?? 1080
        let preferAdaptive = UserDefaults.standard.object(forKey: "preferAdaptive") as? Bool ?? true
        let engine = backend ?? makeMediaBackend()
        backend = engine
        engine.onTick = { [weak self] seconds in self?.tick(seconds) }
        engine.onEnded = { [weak self] in self?.finished() }
        engine.onFailure = { [weak self] message in self?.errorMessage = message }
        options = PlaybackSelector.options(for: details, preferredLanguage: Locale.current.language.languageCode?.identifier)
            .filter { _ in true }
        guard let choice = PlaybackSelector.best(options, maxHeight: maxHeight, preferAdaptive: preferAdaptive) else {
            errorMessage = options.isEmpty
                ? "This video has no source this device can play (it offers only formats the player does not support, such as WebM, DASH or DRM-protected streams)."
                : "No playable source found."
            return
        }
        let saved = SavedVideo(details.item)
        let resume = library.position(for: saved)
        guard await play(choice, resumeAt: resume, duration: details.item.duration) else { return }

        if let first = details.subtitles.first(where: { $0.language?.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") == true }),
           UserDefaults.standard.bool(forKey: "showSubtitlesByDefault") {
            await chooseSubtitle(first)
        }
        await startTracker()
    }

    func select(_ option: PlaybackOption) async {
        let position = backend?.currentTime
        let autoplay = backend?.isPlaying ?? true
        _ = await play(option, resumeAt: position, duration: details?.item.duration, autoplay: autoplay)
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
        } else {
            backend.play()
            backend.setPlaybackRate(playbackRate)
            isPlaying = true
        }
    }
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { backend?.setPlaybackRate(rate) }
    }
    func setSubtitleColor(_ choice: SubtitleColorChoice) {
        subtitleColorChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "subtitleColor")
    }
    func setSubtitleSize(_ choice: SubtitleSizeChoice) {
        subtitleSizeChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "subtitleSize")
    }
    func skip(by seconds: Double) {
        seek(to: playbackTime + seconds)
    }
    func seek(to seconds: Double) {
        guard let backend else { return }
        let target = min(max(0, seconds), duration > 0 ? duration : .greatestFiniteMagnitude)
        if duration <= 0 || target < duration - 0.5 { didFinishCurrentItem = false }
        backend.seek(to: target)
    }
    func replay() {
        guard let backend else { return }
        didFinishCurrentItem = false
        backend.seek(to: 0)
        backend.play()
        backend.setPlaybackRate(playbackRate)
        playbackTime = 0
        isPlaying = true
    }

    private func play(_ option: PlaybackOption, resumeAt: Double?, duration: Int?, autoplay: Bool = true) async -> Bool {
        guard let backend else { return false }
        playGeneration &+= 1
        let generation = playGeneration
        isPreparing = true
        defer { isPreparing = false }
        do {
            let request = PlayRequest(video: try await resolve(option.video),
                                      audio: try await option.audio.asyncMap { try await resolve($0) },
                                      isLive: option.kind == .live)
            var start = resumeAt
            if let r = resumeAt {
                // Restart from the beginning if the viewer was already near the end, or has barely started.
                if r <= 5 || option.kind == .live { start = nil }
                else if let duration, Double(duration) - r < 15 { start = nil }
            }
            try await backend.load(request, resumeAt: start, autoplay: autoplay)
            backend.setPlaybackRate(playbackRate)
            didFinishCurrentItem = false
            // Media selections belong to the replaced AVPlayerItem. Do not show
            // a stale embedded-caption checkmark after a quality/source change.
            embeddedSubtitleChoice = nil
            selected = option
            if generation == playGeneration { errorMessage = nil }
            playbackTime = backend.currentTime
            self.duration = backend.duration
            isPlaying = backend.isPlaying
            return true
        } catch MediaBackendLoadError.superseded {
            return false
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = (error as? PluginError)?.localizedDescription ?? error.localizedDescription
            return false
        }
    }

    // MARK: resolving sources

    private struct ModifiedRequest: Decodable {
        var url: String?
        var headers: [String: String]?
    }

    private func resolve(_ source: MediaSource) async throws -> ResolvedMedia {
        if source.pluginType == "DashManifestRawSource", let handle = source.handle, let runtime {
            let manifestData = try await runtime.callHandle(handle, "generate")
            let manifest = try PluginRuntime.decode(String.self, from: manifestData)
            guard let executor = try await runtime.handleFromCall(handle, "getRequestExecutor") else {
                throw PluginError.execution("The generated media source did not provide a request executor")
            }
            let url = try await PluginMediaProxy.shared.register(
                manifest: manifest, runtime: runtime, executor: executor.handle
            )
            return ResolvedMedia(url: url, headers: [:])
        }
        guard var url = URL(string: source.url) else { throw PluginError.execution("Invalid media URL") }
        var headers: [String: String] = [:]
        if let ref = source.requestModifier, let runtime {
            // The modifier runs once, for the initial request. The player then reuses its headers for later range requests.
            let data = try await runtime.callHandle(ref.handle, "modifyRequest", [source.url, [String: String]()])
            if let mod = try? JSONDecoder().decode(ModifiedRequest.self, from: data) {
                if let u = mod.url, let nu = URL(string: u) { url = nu }
                headers = mod.headers ?? [:]
            }
        }
        return ResolvedMedia(url: url, headers: headers)
    }

    // MARK: ticking

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        duration = backend?.duration ?? 0
        isPlaying = backend?.isPlaying ?? false
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
            text = (try? await runtime.callHandle(h, "getSubtitles")).flatMap { try? JSONDecoder().decode(String.self, from: $0) }
        } else if let u = sub.url, let url = URL(string: u) {
            text = (try? await URLSession.shared.data(from: url)).flatMap { String(data: $0.0, encoding: .utf8) }
        }
        if let text { cues = SubtitleParser.parse(text) }
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

    func teardown() {
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
        removeFullscreenPresenter()
        backend?.stop()
        backend = nil
        loadedURL = nil
        selected = nil
        playbackTime = 0; duration = 0; isPlaying = false; isFullscreen = false
        cues = []; subtitleText = nil; subtitleChoice = nil; embeddedSubtitleChoice = nil
        didFinishCurrentItem = false
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
