import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class PlayerModel {
    private(set) var player: AVPlayer?
    private(set) var options: [PlaybackOption] = []
    private(set) var selected: PlaybackOption?
    private(set) var errorMessage: String?
    private(set) var isPreparing = false
    private(set) var subtitleText: String?
    private(set) var subtitleChoice: SubtitleSource?
    private(set) var subtitleSources: [SubtitleSource] = []

    @ObservationIgnored private var cues: [SubtitleCue] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var details: VideoDetails?
    @ObservationIgnored private var runtime: PluginRuntime?
    @ObservationIgnored private var library: LibraryStore?
    @ObservationIgnored private var trackerTask: Task<Void, Never>?
    @ObservationIgnored private var trackerHandle: Int?
    @ObservationIgnored private var lastHistoryWrite = Date.distantPast
    @ObservationIgnored private var itemObserver: NSObjectProtocol?

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
        options = PlaybackSelector.options(for: details, preferredLanguage: Locale.current.language.languageCode?.identifier)
        guard let choice = PlaybackSelector.best(options, maxHeight: maxHeight, preferAdaptive: preferAdaptive) else {
            errorMessage = options.isEmpty
                ? "This video has no source iOS can play (it offers only WebM, DASH or DRM-protected streams)."
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
        let position = player?.currentTime().seconds
        await play(option, resumeAt: position, duration: details?.item.duration)
    }

    private func play(_ option: PlaybackOption, resumeAt: Double?, duration: Int?) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let item = try await makeItem(for: option)
            attach(item: item, resumeAt: resumeAt, duration: duration, autoplay: true)
            selected = option
        } catch {
            errorMessage = (error as? PluginError)?.localizedDescription ?? error.localizedDescription
        }
    }

    // MARK: building items

    private struct ModifiedRequest: Decodable {
        var url: String?
        var headers: [String: String]?
    }

    private func asset(for source: MediaSource) async throws -> AVURLAsset {
        guard var url = URL(string: source.url) else { throw PluginError.execution("Invalid media URL") }
        var headers: [String: String] = [:]
        if let ref = source.requestModifier, let runtime {
            // The modifier runs once, for the initial request. AVPlayer then reuses its headers for later range requests.
            let data = try await runtime.callHandle(ref.handle, "modifyRequest", [source.url, [String: String]()])
            if let mod = try? JSONDecoder().decode(ModifiedRequest.self, from: data) {
                if let u = mod.url, let nu = URL(string: u) { url = nu }
                headers = mod.headers ?? [:]
            }
        }
        // This option key is not exposed in the public headers but is the long-standing way to set request headers.
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        return AVURLAsset(url: url, options: options)
    }

    private func makeItem(for option: PlaybackOption) async throws -> AVPlayerItem {
        let videoAsset = try await asset(for: option.video)
        guard let audioSource = option.audio else { return AVPlayerItem(asset: videoAsset) }

        // Separate video and audio files are combined into one composition so AVPlayer plays them in sync.
        let audioAsset = try await asset(for: audioSource)
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

    private func attach(item: AVPlayerItem, resumeAt: Double?, duration: Int?, autoplay: Bool) {
        removeObservers()
        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        player = p
        if let resumeAt, resumeAt > 5, selected?.kind != .live {
            // Restart from the beginning if the viewer was already near the end.
            if let duration, Double(duration) - resumeAt < 15 {} else {
                p.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        itemObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finished() }
        }
        if autoplay { p.play() }
    }

    // MARK: ticking

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
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
                let (seconds, playing) = await MainActor.run { (self.player?.currentTime().seconds ?? 0, (self.player?.rate ?? 0) > 0) }
                guard seconds.isFinite else { continue }
                if first && hasInit { _ = try? await runtime.callHandle(handle, "onInit", [seconds]) }
                else { _ = try? await runtime.callHandle(handle, "onProgress", [Int(seconds), playing]) }
                first = false
                if let next = await runtime.intProperty(handle: handle, "nextRequest") { interval = max(100, next) }
            }
        }
    }

    // MARK: teardown

    private func removeObservers() {
        if let t = timeObserver { player?.removeTimeObserver(t); timeObserver = nil }
        if let o = itemObserver { NotificationCenter.default.removeObserver(o); itemObserver = nil }
    }

    func teardown() {
        trackerTask?.cancel(); trackerTask = nil
        if let h = trackerHandle, let rt = runtime {
            Task { if await rt.hasMember(handle: h, "onConcluded") { _ = try? await rt.callHandle(h, "onConcluded", [-1]) } }
        }
        trackerHandle = nil
        if let seconds = player?.currentTime().seconds, seconds.isFinite, seconds > 1, let details, let library {
            library.recordProgress(SavedVideo(details.item), seconds: seconds)
        }
        library?.flushHistory()
        removeObservers()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        cues = []; subtitleText = nil; subtitleChoice = nil
    }
}
