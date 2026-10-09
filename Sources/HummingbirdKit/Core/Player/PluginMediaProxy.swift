import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Exposes plugin-generated DASH media as a loopback fMP4 HLS presentation.
/// The player requests ordinary HLS URLs while segment bytes remain owned by
/// the plugin's request executor.
actor PluginMediaProxy {
    static let shared = PluginMediaProxy()

    private struct Presentation: Sendable {
        let runtime: PluginRuntime
        let executor: Int
        let master: String
        let video: String
        let audio: String?
    }

    private var presentations: [String: Presentation] = [:]
    private var order: [String] = []
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var starting: Task<Channel, Error>?

    private init() {}

    func register(manifest: String, runtime: PluginRuntime, executor: Int) async throws -> URL {
        let channel = try await serverChannel()
        guard let address = channel.localAddress, let port = address.port else {
            throw PluginError.execution("The media proxy did not receive a loopback port")
        }
        let id = UUID().uuidString.lowercased()
        let base = "http://127.0.0.1:\(port)/\(id)"
        let playlists = try DashToHLS.convert(manifest, baseURL: base)
        presentations[id] = Presentation(runtime: runtime, executor: executor,
                                           master: playlists.master, video: playlists.video,
                                           audio: playlists.audio)
        order.append(id)
        while order.count > 8, let expired = order.first {
            order.removeFirst()
            presentations[expired] = nil
        }
        guard let url = URL(string: "\(base)/master.m3u8") else {
            throw PluginError.execution("Could not construct the generated media URL")
        }
        return url
    }

    private func serverChannel() async throws -> Channel {
        if let channel { return channel }
        if let starting { return try await starting.value }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let task = Task<Channel, Error> {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelInitializer { child in
                    child.pipeline.configureHTTPServerPipeline().flatMap {
                        child.pipeline.addHandler(HTTPHandler(proxy: self))
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0).get()
            return channel
        }
        starting = task
        do {
            let result = try await task.value
            channel = result
            starting = nil
            return result
        } catch {
            starting = nil
            throw error
        }
    }

    private func response(for uri: String) async -> (HTTPResponseStatus, String, Data) {
        guard let components = URLComponents(string: uri) else { return (.badRequest, "text/plain", Data()) }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return (.notFound, "text/plain", Data()) }
        let presentation = presentations[parts[0]]
        guard let presentation else { return (.notFound, "text/plain", Data()) }
        switch parts.dropFirst().joined(separator: "/") {
        case "master.m3u8": return (.ok, "application/vnd.apple.mpegurl", Data(presentation.master.utf8))
        case "video.m3u8": return (.ok, "application/vnd.apple.mpegurl", Data(presentation.video.utf8))
        case "audio.m3u8":
            guard let audio = presentation.audio else { return (.notFound, "text/plain", Data()) }
            return (.ok, "application/vnd.apple.mpegurl", Data(audio.utf8))
        default:
            guard parts.count >= 4, ["video", "audio"].contains(parts[1]) else {
                return (.notFound, "text/plain", Data())
            }
            var upstream = "https://grayjay.internal/" + parts.dropFirst().joined(separator: "/")
            if let query = components.percentEncodedQuery { upstream += "?" + query }
            do {
                let data = try await presentation.runtime.callHandleBytes(
                    presentation.executor, "executeRequest",
                    [upstream, [String: String]()]
                )
                let contentType = upstream.contains(".webm") ? "video/webm" : "video/mp4"
                return (.ok, contentType, data)
            } catch {
                return (.badGateway, "text/plain", Data(error.localizedDescription.utf8))
            }
        }
    }

    private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        private let proxy: PluginMediaProxy
        private var uri: String?

        init(proxy: PluginMediaProxy) { self.proxy = proxy }

        private final class ContextBox: @unchecked Sendable {
            let value: ChannelHandlerContext
            init(_ value: ChannelHandlerContext) { self.value = value }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head): uri = head.uri
            case .body: break
            case .end:
                let uri = uri ?? "/"
                self.uri = nil
                let context = ContextBox(context)
                Task {
                    let (status, contentType, data) = await proxy.response(for: uri)
                    context.value.eventLoop.execute {
                        var headers = HTTPHeaders()
                        headers.add(name: "Content-Type", value: contentType)
                        headers.add(name: "Content-Length", value: String(data.count))
                        headers.add(name: "Access-Control-Allow-Origin", value: "*")
                        context.value.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil)
                        var buffer = context.value.channel.allocator.buffer(capacity: data.count)
                        buffer.writeBytes(data)
                        context.value.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        context.value.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                    }
                }
            }
        }
    }
}

enum DashToHLS {
    struct Result { let master: String; let video: String; let audio: String? }
    private struct Track {
        let kind: String
        let codec: String
        let bandwidth: Int
        let width: Int
        let height: Int
        let timescale: Double
        let startNumber: Int
        let initialization: String
        let media: String
        let durations: [Double]
    }

    static func convert(_ mpd: String, baseURL: String) throws -> Result {
        let sets = matches(#"<AdaptationSet\b[^>]*contentType="([^"]+)"[^>]*>([\s\S]*?)</AdaptationSet>"#, in: mpd)
        let tracks = sets.compactMap { parseTrack(kind: $0[0], body: $0[1]) }
        guard let video = tracks.first(where: { $0.kind == "video" }) else {
            throw PluginError.execution("The generated DASH manifest has no video track")
        }
        let audio = tracks.first(where: { $0.kind == "audio" })
        let videoPlaylist = mediaPlaylist(video, baseURL: baseURL)
        let audioPlaylist = audio.map { mediaPlaylist($0, baseURL: baseURL) }
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
        if audio != nil {
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(baseURL)/audio.m3u8\"\n"
        }
        let codecs = ([video.codec] + [audio?.codec].compactMap { $0 }).joined(separator: ",")
        master += "#EXT-X-STREAM-INF:BANDWIDTH=\(max(1, video.bandwidth + (audio?.bandwidth ?? 0))),CODECS=\"\(codecs)\",RESOLUTION=\(video.width)x\(video.height)"
        if audio != nil { master += ",AUDIO=\"audio\"" }
        master += "\n\(baseURL)/video.m3u8\n"
        return Result(master: master, video: videoPlaylist, audio: audioPlaylist)
    }

    private static func parseTrack(kind: String, body: String) -> Track? {
        guard let representation = firstMatch(#"<Representation\b([^>]*)>"#, in: body)?.first,
              let templateMatch = firstMatch(#"<SegmentTemplate\b([^>]*)>([\s\S]*?)</SegmentTemplate>"#, in: body) else { return nil }
        let template = templateMatch[0]
        let timeline = templateMatch[1]
        let timescale = Double(attribute("timescale", in: template) ?? "1") ?? 1
        var durations: [Double] = []
        for values in matches(#"<S\b([^>]*)/?>"#, in: timeline) {
            let attrs = values[0]
            guard let raw = attribute("d", in: attrs), let duration = Double(raw) else { continue }
            let repeats = max(0, Int(attribute("r", in: attrs) ?? "0") ?? 0)
            durations.append(contentsOf: repeatElement(duration / timescale, count: repeats + 1))
        }
        guard !durations.isEmpty,
              let initialization = attribute("initialization", in: template),
              let media = attribute("media", in: template) else { return nil }
        return Track(kind: kind,
                     codec: attribute("codecs", in: representation) ?? "",
                     bandwidth: Int(attribute("bandwidth", in: representation) ?? "0") ?? 0,
                     width: Int(attribute("width", in: representation) ?? "0") ?? 0,
                     height: Int(attribute("height", in: representation) ?? "0") ?? 0,
                     timescale: timescale,
                     startNumber: Int(attribute("startNumber", in: template) ?? "1") ?? 1,
                     initialization: initialization, media: media, durations: durations)
    }

    private static func mediaPlaylist(_ track: Track, baseURL: String) -> String {
        let target = max(1, Int(ceil(track.durations.max() ?? 1)))
        var result = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:\(track.startNumber)\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        result += "#EXT-X-MAP:URI=\"\(localURL(track.initialization, baseURL: baseURL))\"\n"
        for (offset, duration) in track.durations.enumerated() {
            let number = track.startNumber + offset
            let media = track.media.replacingOccurrences(of: "$Number$", with: String(number))
            result += "#EXTINF:\(String(format: "%.6f", duration)),\n\(localURL(media, baseURL: baseURL))\n"
        }
        return result + "#EXT-X-ENDLIST\n"
    }

    private static func localURL(_ upstream: String, baseURL: String) -> String {
        guard let url = URL(string: upstream) else { return upstream }
        var result = baseURL + url.path
        if let query = url.query { result += "?" + query }
        return result
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        firstMatch("\\b" + NSRegularExpression.escapedPattern(for: name) + #"="([^"]*)""#, in: text)?.first
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? { matches(pattern, in: text).first }
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }
}
