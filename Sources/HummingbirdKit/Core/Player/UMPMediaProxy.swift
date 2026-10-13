import Foundation
import DebugKit
import NIOCore
import NIOHTTP1
import NIOPosix

actor UMPMediaProxy {
    static let shared = UMPMediaProxy()
    private struct Presentation {
        let session: UMPSession
        let cache: UMPMediaCache.Handle
        let failure: @Sendable (UMPSessionError) -> Void
        var reportedFailure = false
    }
    private var items: [String: Presentation] = [:]
    private var order: [String] = []
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var starting: Task<Channel, Error>?

    func register(source: MediaSource, maximumHeight: Int = 1080, language: String? = nil,
                  progress: (@Sendable (UMPPreparationProgress) -> Void)? = nil,
                  refreshToken: (@Sendable () async throws -> String)? = nil,
                  reloadOnBlockedBootstrap: Bool = false,
                  failure: @escaping @Sendable (UMPSessionError) -> Void = { _ in }) async throws -> URL {
        let session = try UMPSession(source: source, maximumHeight: maximumHeight, language: language,
                                     progress: progress, reloadOnBlockedBootstrap: reloadOnBlockedBootstrap)
        // The initial POT bootstraps the executor, while YouTube may require a
        // freshly minted continuation POT before it releases media. Start that
        // mint alongside preparation so a blocked bootstrap retry can use it;
        // waiting until prepare() returns creates a circular wait.
        let tokenRefreshTask = refreshToken.map { refreshToken in
            Task {
                let token = try await refreshToken()
                await session.replacePoToken(token)
            }
        }
        defer { tokenRefreshTask?.cancel() }
        try await session.prepare()
        try await tokenRefreshTask?.value
        let cache = try await UMPMediaCache.shared.open(await session.cacheDescriptor())
        let channel = try await serverChannel(); guard let port = channel.localAddress?.port else { throw UMPSessionError.invalidSource }
        let id = UUID().uuidString.lowercased()
        items[id] = .init(session: session, cache: cache, failure: failure)
        order.append(id)
        while order.count > 4 { items[order.removeFirst()] = nil }
        let url = URL(string: "http://127.0.0.1:\(port)/\(id)/master.m3u8")!
        DebugServer.record("ump_proxy", "registered", fields: ["url": url.absoluteString])
        return url
    }

    private func serverChannel() async throws -> Channel {
        if let channel { return channel }; if let starting { return try await starting.value }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1); self.group = group
        let task = Task<Channel, Error> { try await ServerBootstrap(group: group).serverChannelOption(ChannelOptions.backlog, value: 16).childChannelInitializer { child in child.pipeline.configureHTTPServerPipeline().flatMap { child.pipeline.addHandler(Handler(proxy: self)) } }.childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1).bind(host: "127.0.0.1", port: 0).get() }
        starting = task
        do { let value = try await task.value; channel = value; starting = nil; return value } catch { starting = nil; throw error }
    }

    private func response(_ uri: String) async -> (HTTPResponseStatus, String, Data) {
        let parts = (URLComponents(string: uri)?.path ?? "").split(separator: "/").map(String.init)
        guard parts.count >= 2, let item = items[parts[0]] else { return (.notFound, "text/plain", Data()) }
        let base = "/\(parts[0])"
        let snapshots = await item.session.snapshots()
        DebugServer.record("ump_proxy", "request", fields: ["path": parts.dropFirst().joined(separator: "/")])
        switch parts[1] {
        case "master.m3u8":
            let codecs = [snapshots.video.format.codecs, snapshots.audio.format.codecs].compactMap { $0 }.joined(separator: ",")
            var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(base)/audio.m3u8\"\n"
            text += "#EXT-X-STREAM-INF:BANDWIDTH=\(max(1, snapshots.video.format.bitrate + snapshots.audio.format.bitrate)),CODECS=\"\(codecs)\",RESOLUTION=\(snapshots.video.format.width)x\(snapshots.video.format.height),AUDIO=\"audio\"\n\(base)/video.m3u8\n"
            DebugServer.record("ump_proxy", "master", fields: ["playlist": text])
            return (.ok, "application/vnd.apple.mpegurl", Data(text.utf8))
        case "video.m3u8", "audio.m3u8":
            let video = parts[1] == "video.m3u8"
            let initialTrack = video ? snapshots.video : snapshots.audio
            // A known-final VOD playlist already exposes its stable timeline;
            // media requests drive lazy SABR fetching. Polling here can produce
            // valid empty responses and must not poison the session before the
            // player asks for its next segment.
            if initialTrack.finalSegment == nil {
                do { try await item.session.pump() }
                catch let error as UMPSessionError { reportFailure(for: parts[0], error: error) }
                catch { /* Existing buffered media remains playable. */ }
            }
            let current = await item.session.snapshots()
            let track = video ? current.video : current.audio
            DebugServer.record("ump_proxy", "playlist", fields: [
                "kind": video ? "video" : "audio",
                "segments": String(track.segments.count),
                "first": String(track.segments.first?.sequence ?? -1),
                "firstStart": String(track.segments.first?.start ?? -1),
                "firstDuration": String(track.segments.first?.duration ?? -1),
                "hasInit": String(track.hasInitialization),
            ])
            let data = Self.playlist(track, base: base, kind: video ? "video" : "audio")
            DebugServer.record("ump_proxy", "playlist_text", fields: [
                "kind": video ? "video" : "audio",
                "playlist": String(data: data, encoding: .utf8) ?? "",
            ])
            return (.ok, "application/vnd.apple.mpegurl", data)
        case "video", "audio":
            guard parts.count == 3 else { return (.notFound, "text/plain", Data()) }; let video = parts[1] == "video", track = video ? snapshots.video : snapshots.audio
            do {
                if parts[2] == "init.mp4" {
                    let cacheName = video ? "video-init" : "audio-init"
                    if let cached = try? await UMPMediaCache.shared.read(item.cache, name: cacheName) {
                        return (.ok, track.format.mimeType, cached)
                    }
                    let data = try await item.session.initialization(video: video)
                    try? await UMPMediaCache.shared.write(data, to: item.cache, name: cacheName)
                    DebugServer.record("ump_proxy", "init", fields: ["kind": video ? "video" : "audio", "bytes": String(data.count)])
                    return (.ok, track.format.mimeType, data)
                }
                guard parts[2].hasSuffix(".m4s"), let n = Int(parts[2].dropLast(4)) else { return (.notFound, "text/plain", Data()) }
                if ProcessInfo.processInfo.environment["HUMMINGBIRD_PLUGIN_VERBOSE"] == "1" {
                    print("[native ump proxy] request kind=\(video ? "video" : "audio") sequence=\(n)")
                }
                let cacheName = "\(video ? "video" : "audio")-\(n)"
                if let cached = try? await UMPMediaCache.shared.read(item.cache, name: cacheName) {
                    DebugServer.record("ump_proxy", "cache_hit", fields: ["kind": video ? "video" : "audio", "sequence": String(n)])
                    return (.ok, track.format.mimeType, cached)
                }
                let cachedRange = await UMPMediaCache.shared.contiguousRange(
                    item.cache,
                    namePrefix: video ? "video-" : "audio-"
                )
                await item.session.noteCachedRange(video: video, range: cachedRange)
                let data = try await item.session.segment(video: video, sequence: n)
                try? await UMPMediaCache.shared.write(data, to: item.cache, name: cacheName)
                if ProcessInfo.processInfo.environment["HUMMINGBIRD_PLUGIN_VERBOSE"] == "1" {
                    print("[native ump proxy] response kind=\(video ? "video" : "audio") sequence=\(n) bytes=\(data.count)")
                }
                DebugServer.record("ump_proxy", "segment", fields: ["kind": video ? "video" : "audio", "sequence": String(n), "bytes": String(data.count)])
                return (.ok, track.format.mimeType, data)
            } catch let error as UMPSessionError {
                if ProcessInfo.processInfo.environment["HUMMINGBIRD_PLUGIN_VERBOSE"] == "1" {
                    print("[native ump proxy] failure path=\(parts.dropFirst().joined(separator: "/")) error=\(error.localizedDescription)")
                }
                reportFailure(for: parts[0], error: error)
                return (.badGateway, "text/plain", Data(error.localizedDescription.utf8))
            } catch {
                return (.badGateway, "text/plain", Data(error.localizedDescription.utf8))
            }
        default: return (.notFound, "text/plain", Data())
        }
    }

    private func reportFailure(for id: String, error: UMPSessionError) {
        guard var item = items[id], !item.reportedFailure else { return }
        item.reportedFailure = true
        items[id] = item
        DebugServer.record("ump_proxy", "terminal_failure", fields: ["message": error.localizedDescription])
        item.failure(error)
    }

    static func playlist(_ track: UMPSession.TrackSnapshot, base: String, kind: String) -> Data {
        let target = max(1, Int(ceil(track.segments.map(\.duration).max() ?? 1))); let first = track.segments.first?.sequence ?? 0
        let playlistType = track.finalSegment == nil ? "EVENT" : "VOD"
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(first)\n#EXT-X-PLAYLIST-TYPE:\(playlistType)\n#EXT-X-MAP:URI=\"\(base)/\(kind)/init.mp4\"\n"
        let known = Dictionary(uniqueKeysWithValues: track.segments.map { ($0.sequence, $0.duration) })
        let last = track.finalSegment ?? track.segments.last?.sequence ?? first - 1
        let estimated = track.presentationDuration.map { $0 / Double(max(1, last - first + 1)) }
            ?? track.segments.map(\.duration).reduce(0, +) / Double(max(1, track.segments.count))
        if last >= first {
            // VOD clients need the complete known timeline in order to seek
            // beyond the initial SABR buffer. Missing segments are fetched on
            // demand by `UMPSession.segment`; the corrected buffered-range
            // request then advances the server to the requested window.
            for sequence in first...last {
                let duration = known[sequence] ?? estimated
                text += "#EXTINF:\(String(format: "%.6f", max(0.001, duration))),\n\(base)/\(kind)/\(sequence).m4s\n"
            }
        }
        // Once SABR has declared the final segment the complete addressable VOD
        // timeline is stable, even though individual fragments remain lazily
        // fetched. Mark it final so AVFoundation does not wait for playlist
        // updates before starting or seeking.
        if track.finalSegment != nil { text += "#EXT-X-ENDLIST\n" }
        return Data(text.utf8)
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart; typealias OutboundOut = HTTPServerResponsePart
        let proxy: UMPMediaProxy; var uri = "/"; init(proxy: UMPMediaProxy) { self.proxy = proxy }
        final class Box: @unchecked Sendable { let context: ChannelHandlerContext; init(_ context: ChannelHandlerContext) { self.context = context } }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) { case .head(let h): uri = h.uri; case .body: break; case .end:
                let uri = uri, box = Box(context); Task { let (status, type, body) = await proxy.response(uri); box.context.eventLoop.execute { var headers = HTTPHeaders(); headers.add(name: "Content-Type", value: type); headers.add(name: "Content-Length", value: String(body.count)); headers.add(name: "Cache-Control", value: "no-store, no-cache, must-revalidate"); headers.add(name: "Pragma", value: "no-cache"); box.context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil); var buffer = box.context.channel.allocator.buffer(capacity: body.count); buffer.writeBytes(body); box.context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil); box.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil) } }
            }
        }
    }
}
