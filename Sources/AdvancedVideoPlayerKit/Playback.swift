import Foundation

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

public struct PlayRequest: Sendable {
    public var video: ResolvedMedia
    public var audio: ResolvedMedia?
    public var isLive: Bool

    public init(video: ResolvedMedia, audio: ResolvedMedia? = nil, isLive: Bool = false) {
        self.video = video
        self.audio = audio
        self.isLive = isLive
    }
}

public enum MediaBackendLoadError: Error { case superseded }

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
    var pictureInPictureSupported: Bool { get }
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
    var pictureInPictureSupported: Bool { false }
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func setPlaybackRate(_: Float) {}
}

/// The state/actions required by the reusable control surface.
@MainActor
public protocol AdvancedVideoPlayerControlling: AnyObject, Observable {
    var title: String { get }
    var playbackTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var playbackRate: Float { get }
    var pictureInPictureSupported: Bool { get }
    func togglePlayback()
    func skip(by seconds: Double)
    func seek(to seconds: Double)
    func setPlaybackRate(_ rate: Float)
    func startPictureInPicture()
    func toggleFullscreen()
}
