import Foundation
import Observation
import SwiftOpenUI

public struct MediaTrack: Hashable, Sendable {
    public enum Kind: String, Sendable { case video, audio, subtitles }
    /// Accessibility characteristics a menu shows as badges.
    public enum Characteristic: String, Sendable, Hashable {
        /// Closed captions or subtitles for the deaf and hard of hearing (describe sounds too).
        case closedCaptions
        /// An audio description of the video.
        case audioDescription
        /// Forced subtitles (shown even with subtitles off: signs, foreign dialogue).
        case forced
    }
    public let id: String
    public let kind: Kind
    public let language: String?
    public let label: String?
    public let characteristics: Set<Characteristic>

    public init(id: String, kind: Kind, language: String? = nil, label: String? = nil,
                characteristics: Set<Characteristic> = []) {
        self.id = id
        self.kind = kind
        self.language = language
        self.label = label
        self.characteristics = characteristics
    }

    /// The name a menu shows, with CC and AD badges.
    public func menuTitle(fallback: String) -> String {
        var title = label ?? language ?? fallback
        if characteristics.contains(.audioDescription) { title += " · AD" }
        if characteristics.contains(.closedCaptions) { title += " · CC" }
        if characteristics.contains(.forced) { title += " · Forced" }
        return title
    }
}

public struct ResolvedMedia: Sendable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// What a backend plays. Built only through `local(video:audio:isLive:)` (the
/// memberwise initializer is internal to this module), which accepts only
/// local (loopback or file) URLs: nothing, live streams included, can be
/// handed to a backend from upstream.
public struct PlayRequest: Sendable {
    public let video: ResolvedMedia
    public let audio: ResolvedMedia?
    public let isLive: Bool

    init(video: ResolvedMedia, audio: ResolvedMedia? = nil, isLive: Bool = false) {
        self.video = video
        self.audio = audio
        self.isLive = isLive
    }

    public enum NotLocal: Error, LocalizedError {
        case upstream(String)
        public var errorDescription: String? {
            switch self {
            case .upstream(let host): "Media from \(host) must be played from the local media cache."
            }
        }
    }

    /// Media read from this device. Throws unless every URL is a loopback HTTP
    /// URL or a file URL. `isLive` marks a live recording still growing.
    public static func local(video: URL, audio: URL? = nil, isLive: Bool = false) throws -> PlayRequest {
        for url in [video, audio].compactMap({ $0 }) where !isLocal(url) {
            throw NotLocal.upstream(url.host ?? url.scheme ?? "an unknown origin")
        }
        return PlayRequest(video: ResolvedMedia(url: video), audio: audio.map { ResolvedMedia(url: $0) }, isLive: isLive)
    }

    public static func isLocal(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        guard url.scheme == "http" else { return false }
        return ["127.0.0.1", "::1", "localhost"].contains(url.host ?? "")
    }
}

public enum MediaBackendLoadError: Error { case superseded }

/// Where Picture in Picture stands. Controls show a PiP button unless it is
/// `unsupported`, enable it only when it can act (`possible`, `active`), and
/// show a spinner while it changes (`starting`, `stopping`): never a button that
/// pretends.
public enum PictureInPictureState: Sendable, Equatable {
    /// This backend or platform has no Picture in Picture.
    case unsupported
    /// Supported, but not right now (no media yet, or the surface is not on screen).
    case unavailable
    case possible
    case starting
    case active
    case stopping
}

/// What the player is really doing, never what it was asked to do.
public enum PlaybackActivity: Equatable, Sendable {
    case paused
    case playing
    /// Asked to play but not advancing, with the reason shown to the user
    /// ("Buffering", "Waiting for the network", "Stalled").
    case waiting(String)

    /// Playing, or trying to.
    public var wantsToPlay: Bool { self != .paused }

    public var waitingReason: String? {
        if case .waiting(let reason) = self { return reason }
        return nil
    }
}

/// A change to playback that did not come from the app's own controls. The
/// engine reports every one; the host decides what it means for the
/// user's intent, so the UI, intent, Now Playing and history stay in step.
public enum ExternalPlaybackEvent: Equatable, Sendable {
    /// The user played or paused outside the app's controls (lock screen,
    /// Control Center, headphones, CarPlay, Siri, the system player UI,
    /// Picture in Picture).
    case play
    case pause
    case togglePlayPause
    case seek(to: Double)
    case skip(by: Double)
    /// A call, an alarm or another app took the audio (the engine paused).
    case interruptionBegan
    /// The interruption ended; `shouldResume`: the system says playback may resume.
    case interruptionEnded(shouldResume: Bool)
    /// The output went away (headphones unplugged); the engine paused.
    case outputLost
}

/// What the system's Now Playing shows (lock screen, Control Center).
public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var duration: Double
    public var position: Double
    public var rate: Float
    public init(title: String, duration: Double, position: Double, rate: Float) {
        self.title = title
        self.duration = duration
        self.position = position
        self.rate = rate
    }
}

/// Platform playback engine contract. Applications can supply AVFoundation,
/// GStreamer, VLC, or test implementations without changing player UI.
@MainActor
public protocol MediaBackend: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var onTick: (@MainActor (Double) -> Void)? { get set }
    /// The engine's real state; `onActivityChange` reports every change,
    /// including pauses the system makes on its own (interruptions, routes).
    var activity: PlaybackActivity { get }
    var onActivityChange: (@MainActor (PlaybackActivity) -> Void)? { get set }
    /// Changes from outside the app's controls; the engine never acts on them
    /// itself beyond what the system already did (see `ExternalPlaybackEvent`).
    var onExternalEvent: (@MainActor (ExternalPlaybackEvent) -> Void)? { get set }
    /// Publishes what the system's Now Playing shows (nil: nothing playing).
    func updateNowPlaying(_ nowPlaying: NowPlaying?)
    var onEnded: (@MainActor () -> Void)? { get set }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    var tracks: [MediaTrack] { get }
    func selectTrack(_ track: MediaTrack?)
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack?
    func setExternalSubtitle(_ url: URL?)
    var pictureInPictureState: PictureInPictureState { get }
    /// Called whenever `pictureInPictureState` changes.
    var onPictureInPictureChange: (@MainActor (PictureInPictureState) -> Void)? { get set }
    /// Called when the user returns from Picture in Picture to the app: the host
    /// brings the player's page (tab, window) back before PiP closes.
    var onRestoreFromPictureInPicture: (@MainActor () -> Void)? { get set }
    func startPictureInPicture()
    func stopPictureInPicture()
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws
    func play()
    func pause()
    func setPlaybackRate(_ rate: Float)
    func seek(to seconds: Double)
    func stop()
}

public extension MediaBackend {
    var duration: Double { 0 }
    var activity: PlaybackActivity { isPlaying ? .playing : .paused }
    var onActivityChange: (@MainActor (PlaybackActivity) -> Void)? { get { nil } set {} }
    var onExternalEvent: (@MainActor (ExternalPlaybackEvent) -> Void)? { get { nil } set {} }
    func updateNowPlaying(_: NowPlaying?) {}
    var tracks: [MediaTrack] { [] }
    func selectTrack(_: MediaTrack?) {}
    func selectedTrack(ofKind _: MediaTrack.Kind) -> MediaTrack? { nil }
    func setExternalSubtitle(_: URL?) {}
    var pictureInPictureState: PictureInPictureState { .unsupported }
    var onPictureInPictureChange: (@MainActor (PictureInPictureState) -> Void)? { get { nil } set {} }
    var onRestoreFromPictureInPicture: (@MainActor () -> Void)? { get { nil } set {} }
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func setPlaybackRate(_: Float) {}
}

/// The state/actions required by the reusable control surface.
@MainActor
public protocol AdvancedVideoPlayerControlling: AnyObject, Observable {
    var title: String { get }
    /// False until playable media is loaded. The controls stay disabled until
    /// then (the host shows its own progress), never pretending to play.
    var isMediaReady: Bool { get }
    var playbackTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var playbackRate: Float { get }
    /// Why playback that should be advancing is not (buffering, stalled,
    /// recovering); nil while it plays or is paused.
    var waitingReason: String? { get }
    /// What the seek bar shows: duration, chapters, pipeline lanes, flagged
    /// regions and the live window.
    var scrubberContent: ScrubberContent { get }
    /// Seeks to the live edge of a live stream.
    func jumpToLive()
    var pictureInPictureState: PictureInPictureState { get }
    func togglePlayback()
    func skip(by seconds: Double)
    func seek(to seconds: Double)
    func setPlaybackRate(_ rate: Float)
    func startPictureInPicture()
    func stopPictureInPicture()
    func toggleFullscreen()
    /// Subtitles on (in the viewer's language) or off: the captions key command.
    func toggleCaptions()
}
