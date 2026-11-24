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

    /// The same media at the ports `moves` gave its servers, or nil when none moved.
    func moved(_ moves: [PortMove]) -> LocalPlayback? {
        func rebased(_ url: URL) -> URL? {
            guard let port = url.port, let move = moves.first(where: { $0.from == port }),
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.port = move.to
            return components.url
        }
        let video = rebased(request.video.url)
        let audio = request.audio.flatMap { rebased($0.url) }
        guard video != nil || audio != nil else { return nil }
        return try? LocalPlayback(video: video ?? request.video.url, audio: audio ?? request.audio?.url,
                                  servedBy: origin == .mediaCache ? .mediaCache : .generatedMedia,
                                  isLive: request.isLive)
    }
}
