import Foundation
import AdvancedVideoPlayerKit

/// What Hummingbird hands the platform player, and where it comes from.
///
/// Nothing plays from upstream, live streams included: the player reads
/// everything from this device (the loopback media server, which serves the
/// media cache, or the generated-media proxy). `PlayRequest` can only be built
/// through AdvancedVideoPlayerKit's `local` factory, which accepts only local
/// URLs, so handing a player an upstream URL does not compile.
struct LocalPlayback: Sendable {
    enum Origin: Sendable, Equatable {
        /// Served from the media cache (`MediaCache` via `LocalMediaServer`).
        case mediaCache
        /// Served from plugin-generated media (`PluginMediaProxy`).
        case generatedMedia
    }

    enum LocalServer: Sendable { case mediaCache, generatedMedia }

    let request: PlayRequest
    let origin: Origin

    /// Media read from this device. Throws unless every URL is local.
    /// `isLive` marks a live recording that is still growing.
    init(video: URL, audio: URL? = nil, servedBy server: LocalServer, isLive: Bool = false) throws {
        request = try PlayRequest.local(video: video, audio: audio, isLive: isLive)
        origin = switch server {
        case .mediaCache: .mediaCache
        case .generatedMedia: .generatedMedia
        }
    }
}
