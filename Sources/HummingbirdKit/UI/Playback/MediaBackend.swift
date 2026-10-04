import Foundation
import SwiftOpenUI

/// A media URL with the request headers the plugin's `requestModifier` asked for.
struct ResolvedMedia: Sendable {
    var url: URL
    var headers: [String: String] = [:]
}

/// What a platform player is asked to play: one muxed/HLS stream, or separate video and audio files to play in sync.
struct PlayRequest: Sendable {
    var video: ResolvedMedia
    var audio: ResolvedMedia?
    var isLive: Bool
}

/// The platform media player behind `PlayerModel`. AVFoundation on Apple platforms, GTK's media stack elsewhere.
@MainActor
protocol MediaBackend: AnyObject {
    /// Seconds into the current item; NaN or 0 when nothing is loaded.
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    /// Called about every half second while an item is loaded.
    var onTick: (@MainActor (Double) -> Void)? { get set }
    var onEnded: (@MainActor () -> Void)? { get set }
    var onFailure: (@MainActor (String) -> Void)? { get set }
    var tracks: [MediaTrack] { get }
    func selectTrack(_ track: MediaTrack?)
    var pictureInPictureSupported: Bool { get }
    func startPictureInPicture()
    func stopPictureInPicture()

    /// Whether this backend can play the option. Apple's player can join separate audio and video; GTK's cannot.
    func canPlay(_ option: PlaybackOption) -> Bool
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws
    func play()
    func pause()
    func seek(to seconds: Double)
    /// Stops playback and releases the current item.
    func stop()
}

extension MediaBackend {
    var tracks: [MediaTrack] { [] }
    func selectTrack(_: MediaTrack?) {}
    var pictureInPictureSupported: Bool { false }
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
}
