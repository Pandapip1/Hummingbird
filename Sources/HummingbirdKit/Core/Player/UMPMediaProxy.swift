import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

actor UMPMediaProxy {
    static let shared = UMPMediaProxy()
    private struct Presentation { let session: UMPSession }
    private var items: [String: Presentation] = [:]
    private var order: [String] = []
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var starting: Task<Channel, Error>?

    func register(source: MediaSource, maximumHeight: Int = 1080, language: String? = nil) async throws -> URL {
        let session = try UMPSession(source: source, maximumHeight: maximumHeight, language: language)
        try await session.prepare()
        let channel = try await serverChannel(); guard let port = channel.localAddress?.port else { throw UMPSessionError.invalidSource }
        let id = UUID().uuidString.lowercased(); items[id] = .init(session: session); order.append(id)
        while order.count > 4 { items[order.removeFirst()] = nil }
        return URL(string: "http://127.0.0.1:\(port)/\(id)/master.m3u8")!
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
        switch parts[1] {
        case "master.m3u8":
            let codecs = [snapshots.video.format.codecs, snapshots.audio.format.codecs].compactMap { $0 }.joined(separator: ",")
            var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(base)/audio.m3u8\"\n"
            text += "#EXT-X-STREAM-INF:BANDWIDTH=\(max(1, snapshots.video.format.bitrate + snapshots.audio.format.bitrate)),CODECS=\"\(codecs)\",RESOLUTION=\(snapshots.video.format.width)x\(snapshots.video.format.height),AUDIO=\"audio\"\n\(base)/video.m3u8\n"
            return (.ok, "application/vnd.apple.mpegurl", Data(text.utf8))
        case "video.m3u8", "audio.m3u8":
            do { try await item.session.pump() } catch { /* Existing buffered media remains playable. */ }
            let current = await item.session.snapshots(), video = parts[1] == "video.m3u8"
            return (.ok, "application/vnd.apple.mpegurl", playlist(video ? current.video : current.audio, base: base, kind: video ? "video" : "audio"))
        case "video", "audio":
            guard parts.count == 3 else { return (.notFound, "text/plain", Data()) }; let video = parts[1] == "video", track = video ? snapshots.video : snapshots.audio
            do {
                if parts[2] == "init.mp4" { return (.ok, track.format.mimeType, try await item.session.initialization(video: video)) }
                guard parts[2].hasSuffix(".m4s"), let n = Int(parts[2].dropLast(4)) else { return (.notFound, "text/plain", Data()) }
                return (.ok, track.format.mimeType, try await item.session.segment(video: video, sequence: n))
            } catch { return (.badGateway, "text/plain", Data(error.localizedDescription.utf8)) }
        default: return (.notFound, "text/plain", Data())
        }
    }

    private func playlist(_ track: UMPSession.TrackSnapshot, base: String, kind: String) -> Data {
        let target = max(1, Int(ceil(track.segments.map(\.duration).max() ?? 1))); let first = track.segments.first?.sequence ?? 0
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(first)\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-MAP:URI=\"\(base)/\(kind)/init.mp4\"\n"
        for segment in track.segments { text += "#EXTINF:\(String(format: "%.6f", segment.duration)),\n\(base)/\(kind)/\(segment.sequence).m4s\n" }
        if track.isComplete { text += "#EXT-X-ENDLIST\n" }
        return Data(text.utf8)
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart; typealias OutboundOut = HTTPServerResponsePart
        let proxy: UMPMediaProxy; var uri = "/"; init(proxy: UMPMediaProxy) { self.proxy = proxy }
        final class Box: @unchecked Sendable { let context: ChannelHandlerContext; init(_ context: ChannelHandlerContext) { self.context = context } }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) { case .head(let h): uri = h.uri; case .body: break; case .end:
                let uri = uri, box = Box(context); Task { let (status, type, body) = await proxy.response(uri); box.context.eventLoop.execute { var headers = HTTPHeaders(); headers.add(name: "Content-Type", value: type); headers.add(name: "Content-Length", value: String(body.count)); box.context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil); var buffer = box.context.channel.allocator.buffer(capacity: body.count); buffer.writeBytes(body); box.context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil); box.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil) } }
            }
        }
    }
}
