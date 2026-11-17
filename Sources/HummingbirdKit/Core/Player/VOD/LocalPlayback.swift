import Foundation
import AdvancedVideoPlayerKit

/// The only way Hummingbird builds a `PlayRequest`.
///
/// VOD is never streamed from upstream: the player reads every on-demand
/// video from this device (the loopback media server, which serves the media
/// cache). A `LocalPlayback` for VOD can only be made from loopback URLs, so
/// handing the player an upstream URL needs one of the explicitly named
/// exceptions below, which review can find. `PlaybackSourcesAreLocalTests`
/// fails the build's tests if any other file constructs a `PlayRequest`.
struct LocalPlayback: Sendable {
    enum Origin: Sendable, Equatable {
        /// Served from the media cache (`MediaCache` via `LocalMediaServer`).
        case mediaCache
        /// Served from plugin-generated media (`PluginMediaProxy`).
        case generatedMedia
        /// A live stream, which cannot be downloaded ahead.
        case live
        /// Upstream adaptive HLS for on-demand video. Not yet downloaded into
        /// the cache: known debt against the download-first design.
        case uncachedAdaptiveHLS
    }

    enum Failure: Error, LocalizedError {
        case notLocal(String)
        var errorDescription: String? {
            switch self {
            case .notLocal(let host): "Refusing to play on-demand media from \(host) directly; it must come from the media cache."
            }
        }
    }

    let request: PlayRequest
    let origin: Origin

    enum LocalServer: Sendable { case mediaCache, generatedMedia }

    /// Media read from this device. Throws unless every URL is a loopback URL.
    init(video: URL, audio: URL? = nil, servedBy server: LocalServer) throws {
        for url in [video, audio].compactMap({ $0 }) where !Self.isLoopback(url) {
            throw Failure.notLocal(url.host ?? url.scheme ?? "an unknown origin")
        }
        request = PlayRequest(video: ResolvedMedia(url: video), audio: audio.map { ResolvedMedia(url: $0) }, isLive: false)
        origin = switch server {
        case .mediaCache: .mediaCache
        case .generatedMedia: .generatedMedia
        }
    }

    private init(request: PlayRequest, origin: Origin) {
        self.request = request
        self.origin = origin
    }

    /// A live stream, played from upstream.
    static func live(_ media: ResolvedMedia) -> LocalPlayback {
        LocalPlayback(request: PlayRequest(video: media, audio: nil, isLive: true), origin: .live)
    }

    /// Upstream adaptive HLS for on-demand video. Hummingbird does not yet
    /// download HLS VOD into the cache; this exception names that debt.
    static func uncachedAdaptiveHLS(_ media: ResolvedMedia) -> LocalPlayback {
        LocalPlayback(request: PlayRequest(video: media, audio: nil, isLive: false), origin: .uncachedAdaptiveHLS)
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "file" else { return false }
        if url.isFileURL { return true }
        return ["127.0.0.1", "::1", "[::1]", "localhost"].contains(url.host ?? "")
    }
}
