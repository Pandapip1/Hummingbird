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

/// What a backend plays. Built only through the factories below (the
/// memberwise initializer is internal to this module), so on-demand media can
/// reach a backend only as local (loopback or file) URLs: handing a backend an
/// upstream URL for on-demand video does not compile outside the named
/// exceptions.
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
            case .upstream(let host): "On-demand media from \(host) must be played from the local media cache."
            }
        }
    }

    /// On-demand media read from this device. Throws unless every URL is a
    /// loopback HTTP URL or a file URL.
    public static func local(video: URL, audio: URL? = nil) throws -> PlayRequest {
        for url in [video, audio].compactMap({ $0 }) where !isLocal(url) {
            throw NotLocal.upstream(url.host ?? url.scheme ?? "an unknown origin")
        }
        return PlayRequest(video: ResolvedMedia(url: video), audio: audio.map { ResolvedMedia(url: $0) })
    }

    /// A live stream, which cannot be downloaded ahead and plays from upstream.
    public static func live(_ media: ResolvedMedia) -> PlayRequest {
        PlayRequest(video: media, isLive: true)
    }

    public static func isLocal(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        guard url.scheme == "http" else { return false }
        return ["127.0.0.1", "::1", "localhost"].contains(url.host ?? "")
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
    /// False until playable media is loaded. The controls stay disabled until
    /// then (the host shows its own progress), never pretending to play.
    var isMediaReady: Bool { get }
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
