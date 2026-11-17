import Foundation
import AdvancedVideoPlayerKit

/// What Hummingbird hands the platform player, and where it comes from.
///
/// On-demand video is never streamed from upstream: the player reads it from
/// this device (the loopback media server, which serves the media cache, or
/// the generated-media proxy). `PlayRequest` can only be built through
/// AdvancedVideoPlayerKit's factories, whose on-demand form accepts only local
/// URLs, so bypassing the cache does not compile. The one exception is a live
/// stream, and it can only be made from a live playback option.
struct LocalPlayback: Sendable {
    enum Origin: Sendable, Equatable {
        /// Served from the media cache (`MediaCache` via `LocalMediaServer`).
        case mediaCache
        /// Served from plugin-generated media (`PluginMediaProxy`).
        case generatedMedia
        /// A live stream, which cannot be downloaded ahead.
        case live
    }

    enum LocalServer: Sendable { case mediaCache, generatedMedia }

    struct NotLive: Error, LocalizedError {
        var errorDescription: String? { "Only live streams play directly from their source." }
    }

    let request: PlayRequest
    let origin: Origin

    /// Media read from this device. Throws unless every URL is local.
    init(video: URL, audio: URL? = nil, servedBy server: LocalServer) throws {
        request = try PlayRequest.local(video: video, audio: audio)
        origin = switch server {
        case .mediaCache: .mediaCache
        case .generatedMedia: .generatedMedia
        }
    }

    private init(live media: ResolvedMedia) {
        request = PlayRequest.live(media)
        origin = .live
    }

    /// A live stream, played from upstream. Only a live option qualifies.
    static func live(_ media: ResolvedMedia, for option: PlaybackOption) throws -> LocalPlayback {
        guard option.kind == .live else { throw NotLive() }
        return LocalPlayback(live: media)
    }
}
