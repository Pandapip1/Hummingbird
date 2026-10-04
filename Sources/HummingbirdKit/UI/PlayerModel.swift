import Foundation
import Observation
import SwiftOpenUI

@MainActor
@Observable
final class PlayerModel {
    /// The platform player. The view layer reads it to draw the video surface (see `PlayerSurface`).
    private(set) var backend: MediaBackend?
    var hasMedia: Bool { backend != nil && selected != nil }
    private(set) var options: [PlaybackOption] = []
    private(set) var selected: PlaybackOption?
    private(set) var errorMessage: String?
    private(set) var isPreparing = false
    private(set) var subtitleText: String?
    private(set) var subtitleChoice: SubtitleSource?
    private(set) var subtitleSources: [SubtitleSource] = []
    var tracks: [MediaTrack] { backend?.tracks ?? [] }
    var pictureInPictureSupported: Bool { backend?.pictureInPictureSupported ?? false }
    private(set) var playbackTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isFullscreen = false
    var title: String { details?.item.name ?? "" }

    @ObservationIgnored private var cues: [SubtitleCue] = []
    @ObservationIgnored private var details: VideoDetails?
    @ObservationIgnored private var runtime: PluginRuntime?
    @ObservationIgnored private var library: LibraryStore?
    @ObservationIgnored private var trackerTask: Task<Void, Never>?
    @ObservationIgnored private var trackerHandle: Int?
    @ObservationIgnored private var lastHistoryWrite = Date.distantPast
    @ObservationIgnored private var presentFullscreenAction: (() -> Void)?
    @ObservationIgnored private var dismissFullscreenAction: (() -> Void)?

    // MARK: loading

    func load(details: VideoDetails, runtime: PluginRuntime, library: LibraryStore) async {
        teardown()
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
            .filter { engine.canPlay($0) }
        guard let choice = PlaybackSelector.best(options, maxHeight: maxHeight, preferAdaptive: preferAdaptive) else {
            errorMessage = options.isEmpty
                ? "This video has no source this device can play (it offers only formats the player does not support, such as WebM, DASH or DRM-protected streams)."
                : "No playable source found."
            return
        }
        let saved = SavedVideo(details.item)
        let resume = library.position(for: saved)
        await play(choice, resumeAt: resume, duration: details.item.duration)

        if let first = details.subtitles.first(where: { $0.language?.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") == true }),
           UserDefaults.standard.bool(forKey: "showSubtitlesByDefault") {
            await chooseSubtitle(first)
        }
        await startTracker()
    }

    func select(_ option: PlaybackOption) async {
        let position = backend?.currentTime
        await play(option, resumeAt: position, duration: details?.item.duration)
    }

    func selectTrack(_ track: MediaTrack?) { backend?.selectTrack(track) }
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
            isPlaying = true
        }
    }
    func skip(by seconds: Double) {
        seek(to: playbackTime + seconds)
    }
    func seek(to seconds: Double) {
        guard let backend else { return }
        let target = min(max(0, seconds), duration > 0 ? duration : .greatestFiniteMagnitude)
        backend.seek(to: target)
    }

    private func play(_ option: PlaybackOption, resumeAt: Double?, duration: Int?) async {
        guard let backend else { return }
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
            try await backend.load(request, resumeAt: start, autoplay: true)
            selected = option
            playbackTime = backend.currentTime
            self.duration = backend.duration
            isPlaying = backend.isPlaying
        } catch {
            errorMessage = (error as? PluginError)?.localizedDescription ?? error.localizedDescription
        }
    }

    // MARK: resolving sources

    private struct ModifiedRequest: Decodable {
        var url: String?
        var headers: [String: String]?
    }

    private func resolve(_ source: MediaSource) async throws -> ResolvedMedia {
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
        if let details, let library { library.recordProgress(SavedVideo(details.item), seconds: 0); library.flushHistory() }
    }

    // MARK: subtitles

    func chooseSubtitle(_ sub: SubtitleSource?) async {
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
        if let seconds = backend?.currentTime, seconds.isFinite, seconds > 1, let details, let library {
            library.recordProgress(SavedVideo(details.item), seconds: seconds)
        }
        library?.flushHistory()
        dismissFullscreen()
        removeFullscreenPresenter()
        backend?.stop()
        backend = nil
        selected = nil
        playbackTime = 0; duration = 0; isPlaying = false; isFullscreen = false
        cues = []; subtitleText = nil; subtitleChoice = nil
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
