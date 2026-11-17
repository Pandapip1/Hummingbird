import Foundation
import Observation

public struct MediaTrack: Hashable, Sendable {
    public enum Kind: String, Sendable { case video, audio, subtitles }
    public let id: String
    public let kind: Kind
    public let language: String?
    public let label: String?

    public init(id: String, kind: Kind, language: String? = nil, label: String? = nil) {
        self.id = id
        self.kind = kind
        self.language = language
        self.label = label
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

/// Platform playback engine contract. Applications can supply AVFoundation,
/// GStreamer, VLC, or test implementations without changing player UI.
@MainActor
public protocol MediaBackend: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var onTick: (@MainActor (Double) -> Void)? { get set }
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
    var pictureInPictureState: PictureInPictureState { get }
    func togglePlayback()
    func skip(by seconds: Double)
    func seek(to seconds: Double)
    func setPlaybackRate(_ rate: Float)
    func startPictureInPicture()
    func stopPictureInPicture()
    func toggleFullscreen()
}
