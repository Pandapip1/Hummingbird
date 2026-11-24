import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os
import Synchronization

/// Exposes plugin-generated DASH media as a loopback fMP4 HLS presentation.
/// The player requests ordinary HLS URLs while segment bytes remain owned by
/// the plugin's request executor.
actor PluginMediaProxy {
    typealias PrefetchExecutorFactory = @Sendable () async throws -> (PluginRuntime, Int)

    private struct Presentation: Sendable {
        let runtime: PluginRuntime
        let executor: Int
        let audioRuntime: PluginRuntime?
        let audioExecutor: Int?
        var master: String
        let video: String?
        let audio: String?
        let cache: UMPMediaCache.Handle?
        let resources: [DashToHLS.Resource]
        let prefetchExecutorFactory: PrefetchExecutorFactory?
        let failure: @Sendable (PluginError) -> Void
        /// Plugin subtitles as SUBTITLES renditions: their playlists and WebVTT texts by name.
        var subtitlePlaylists: [String: String] = [:]
        var subtitleTexts: [String: OnceText] = [:]
        /// WebM tracks, remuxed to fragmented MP4 segment by segment as served.
        var webm: [String: WebMTimeline] = [:]

        /// Offers `subtitles` as SUBTITLES renditions of the master (absolute loopback URIs under `base`).
        mutating func addSubtitles(_ subtitles: [LocalSubtitle], base: String, duration: Double) {
            guard !subtitles.isEmpty, let variant = master.range(of: "#EXT-X-STREAM-INF:") else { return }
            var legible: [(HLSPlaylist.Rendition, String)] = []
            for (index, subtitle) in subtitles.enumerated() {
                let playlist = LocalSubtitle.playlistName(index), text = LocalSubtitle.textName(index)
                subtitlePlaylists[playlist] = LocalSubtitle.mediaPlaylist(textName: "\(base)/\(text)", duration: duration)
                subtitleTexts[text] = OnceText(subtitle.webVTT)
                legible.append((subtitle.rendition, "\(base)/\(playlist)"))
            }
            let lines = HLSPlaylist.legibleRenditions(subtitles: legible)
            master.insert(contentsOf: lines.lines, at: variant.lowerBound)
            if let streamInf = master.range(of: "#EXT-X-STREAM-INF:"),
               let lineEnd = master[streamInf.upperBound...].firstIndex(of: "\n") {
                master.insert(contentsOf: lines.variantAttributes, at: lineEnd)
            }
        }
    }

    private var presentations: [String: Presentation] = [:]
    /// WebM DASH tracks being remuxed, by "<presentation>/<video|audio>".
    private var webmTracks: [String: WebMDashTrack] = [:]
    private var order: [String] = []
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    /// The port the player's URLs name: kept when the listener is bound again.
    private var boundPort: Int?
    /// Accepted connections, so a suspension (and its simulation) can close them.
    private let connections = OpenConnections()
    private var starting: Task<Channel, Error>?
    private var foregroundRequests = 0
    private var lastForegroundRequest: Date?
    private let mediaCache: UMPMediaCache

    /// One proxy serves every window of a set of stores (`AppDataStores`),
    /// caching media in their caches directory.
    init(cache: UMPMediaCache) {
        mediaCache = cache
        LoopbackLifecycle.shared.register(self)
    }

    func register(manifest: String, runtime: PluginRuntime, executor: Int, prefetch: Bool = true,
                  useCache: Bool = true,
                  identity: String? = nil,
                  subtitles: [LocalSubtitle] = [],
                  cacheAllocationBytes: Int64? = nil,
                  prefetchExecutorFactory: PrefetchExecutorFactory? = nil,
                  failure: @escaping @Sendable (PluginError) -> Void = { _ in }) async throws -> URL {
        let channel = try await serverChannel()
        guard let address = channel.localAddress, let port = address.port else {
            throw PluginError.execution("The media proxy did not receive a loopback port")
        }
        let id = UUID().uuidString.lowercased()
        let base = "http://127.0.0.1:\(port)/\(id)"
        let playlists = try DashToHLS.convert(manifest, baseURL: base)
        // v2 invalidates entries that may have been populated by an isolated
        // executor belonging to a different generated source rendition.
        // Generated manifests embed per-session URLs: keyed by them, a video
        // never found its cached bytes again. The stable identity (content and
        // format) keys the cache when the caller has one.
        let cacheKey = "generated-dash-v2:" + (identity ?? manifest) + (cacheAllocationBytes.map { ":test-allocation:\($0)" } ?? "")
        let cache = try await useCache ? mediaCache.open(.init(
            key: cacheKey,
            allocationBytes: cacheAllocationBytes ?? playlists.estimatedBytes,
            isExact: false
        )) : nil
        presentations[id] = Presentation(runtime: runtime, executor: executor,
                                           audioRuntime: nil, audioExecutor: nil,
                                           master: playlists.master, video: playlists.video,
                                           audio: playlists.audio, cache: cache,
                                           resources: playlists.resources,
                                           prefetchExecutorFactory: prefetchExecutorFactory,
                                           failure: failure)
        presentations[id]?.webm = playlists.webm
        if playlists.video != nil { presentations[id]?.addSubtitles(subtitles, base: base, duration: playlists.duration) }
        retain(id)
        let playlistName = playlists.video == nil ? "audio.m3u8" : "master.m3u8"
        guard let url = URL(string: "\(base)/\(playlistName)") else {
            throw PluginError.execution("Could not construct the generated media URL")
        }
        if prefetch {
            // Download-first: the whole presentation is fetched from the start.
            // Foreground (player) requests still take the shared executor first.
            Task(priority: .utility) { await self.prefetch(id: id) }
        }
        return url
    }

    /// Registers separately generated video and audio DASH presentations as a
    /// single HLS asset. AVFoundation cannot insert HLS tracks into an
    /// AVMutableComposition, so generated streams must be paired at the
    /// playlist/proxy layer instead.
    func register(videoManifest: String, videoRuntime: PluginRuntime, videoExecutor: Int,
                  audioManifest: String, audioRuntime: PluginRuntime, audioExecutor: Int,
                  identity: String? = nil,
                  subtitles: [LocalSubtitle] = [],
                  failure: @escaping @Sendable (PluginError) -> Void = { _ in }) async throws -> URL {
        let channel = try await serverChannel()
        guard let port = channel.localAddress?.port else {
            throw PluginError.execution("The media proxy did not receive a loopback port")
        }
        let id = UUID().uuidString.lowercased()
        let base = "http://127.0.0.1:\(port)/\(id)"
        let playlists = try DashToHLS.convert(videoManifest + "\n" + audioManifest, baseURL: base)
        // Generated manifests embed per-session URLs, so the stable identity
        // (content and formats) keys the cache when the caller has one.
        let cacheKey = "generated-dash-pair-v1:" + (identity ?? videoManifest + "\n" + audioManifest)
        let cache = try await mediaCache.open(.init(key: cacheKey, allocationBytes: playlists.estimatedBytes, isExact: false))
        presentations[id] = Presentation(
            runtime: videoRuntime, executor: videoExecutor,
            audioRuntime: audioRuntime, audioExecutor: audioExecutor,
            master: playlists.master, video: playlists.video, audio: playlists.audio,
            cache: cache, resources: playlists.resources,
            prefetchExecutorFactory: nil, failure: failure
        )
        presentations[id]?.webm = playlists.webm
        presentations[id]?.addSubtitles(subtitles, base: base, duration: playlists.duration)
        retain(id)
        guard let url = URL(string: "\(base)/master.m3u8") else {
            throw PluginError.execution("Could not construct the generated media URL")
        }
        Task(priority: .utility) { await self.prefetch(id: id) }
        return url
    }

    private func prefetch(id: String) async {
        guard let presentation = presentations[id] else { return }
        let prefetchRuntime: PluginRuntime
        let prefetchExecutor: Int
        if let factory = presentation.prefetchExecutorFactory {
            do {
                (prefetchRuntime, prefetchExecutor) = try await factory()
            } catch let error as PluginError {
                presentation.failure(error)
                return
            } catch {
                return
            }
        } else {
            prefetchRuntime = presentation.runtime
            prefetchExecutor = presentation.executor
        }
        let usesIsolatedRuntime = presentation.prefetchExecutorFactory != nil
        defer {
            if prefetchRuntime !== presentation.runtime {
                Task { await prefetchRuntime.stop() }
            }
        }
        for resource in presentation.resources {
            guard presentations[id] != nil, !Task.isCancelled else { return }
            while !usesIsolatedRuntime && (foregroundRequests > 0 || foregroundWasRecentlyActive) {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
            if let cache = presentation.cache,
               (try? await mediaCache.read(cache, name: resource.upstream)) != nil {
                continue
            }
            do {
                let prefetchSignpost = OSSignposter.mediaProxy.beginInterval(
                    "UMPPrefetch", id: OSSignposter.mediaProxy.makeSignpostID()
                )
                let data: Data
                do {
                    let (runtime, executor) = usesIsolatedRuntime
                        ? (prefetchRuntime, prefetchExecutor)
                        : Self.executor(for: resource.upstream, in: presentation)
                    data = try await fetchSegment(presentation: id, runtime: runtime, executor: executor,
                                                  upstream: resource.upstream)
                    OSSignposter.mediaProxy.endInterval("UMPPrefetch", prefetchSignpost, "bytes=\(data.count)")
                } catch {
                    OSSignposter.mediaProxy.endInterval("UMPPrefetch", prefetchSignpost, "failed")
                    throw error
                }
                if let cache = presentation.cache {
                    do {
                        try await mediaCache.write(data, to: cache, name: resource.upstream)
                    } catch {
                        Logger.mediaProxy.error("cache_write_failed prefetch=true message=\(error.localizedDescription)")
                        return
                    }
                }
            } catch let error as PluginError {
                presentation.failure(error)
                return
            } catch {
                return
            }
        }
    }

    /// Fetches one generated segment through the plugin's executor. Failures
    /// other than the plugin asking to be reloaded are retried with backoff for
    /// as long as the presentation is registered: the player waits (buffers)
    /// rather than getting an error.
    private func fetchSegment(presentation id: String, runtime: PluginRuntime, executor: Int,
                              upstream: String) async throws -> Data {
        let policy = DownloadRetryPolicy()
        var attempt = 0
        while true {
            do {
                return try await runtime.callHandleBytes(executor, "executeRequest", [upstream, [String: String]()])
            } catch let error as PluginError {
                if case .reloadRequired = error { throw error }
                attempt += 1
                guard presentations[id] != nil else { throw error }
                let delay = policy.delay(afterAttempt: attempt)
                Logger.mediaProxy.notice("segment_retry attempt=\(attempt) delay=\(delay) message=\(error.localizedDescription)")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// The executor that owns a generated resource: paired presentations keep
    /// separate video and audio executors.
    private static func executor(for upstream: String, in presentation: Presentation) -> (PluginRuntime, Int) {
        let isAudio = URL(string: upstream)?.pathComponents.dropFirst().first == "audio"
        if isAudio, let runtime = presentation.audioRuntime, let executor = presentation.audioExecutor {
            return (runtime, executor)
        }
        return (presentation.runtime, presentation.executor)
    }

    /// Presentations live until their player releases them.
    private func retain(_ id: String) {
        order.append(id)
        // A safety net for presentations whose player never released them.
        while order.count > 64, let expired = order.first {
            order.removeFirst()
            presentations[expired] = nil
            webmTracks = webmTracks.filter { !$0.key.hasPrefix("\(expired)/") }
        }
    }

    /// Stops serving and prefetching the presentation at `url`. Cached
    /// segments stay.
    func release(_ url: URL) {
        guard let id = url.pathComponents.dropFirst().first else { return }
        presentations[id] = nil
        order.removeAll { $0 == id }
        webmTracks = webmTracks.filter { !$0.key.hasPrefix("\(id)/") }
    }

    /// The listening channel, bound again if it died (a suspended app's
    /// socket is closed by iOS) on the port its playlists already name.
    private func serverChannel() async throws -> Channel {
        if let channel, channel.isActive { return channel }
        if let starting { return try await starting.value }
        let group = self.group ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let wanted = boundPort
        let task = Task<Channel, Error> {
            if let wanted, let channel = try? await self.bind(group: group, port: wanted) { return channel }
            return try await self.bind(group: group, port: 0)
        }
        starting = task
        do {
            let result = try await task.value
            channel = result
            boundPort = result.localAddress?.port
            starting = nil
            return result
        } catch {
            starting = nil
            throw error
        }
    }

    private nonisolated func bind(group: MultiThreadedEventLoopGroup, port: Int) async throws -> Channel {
        let connections = self.connections
        return try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                connections.add(child)
                return child.pipeline.configureHTTPServerPipeline().flatMap {
                    child.pipeline.addHandler(HTTPHandler(proxy: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port).get()
    }

    private func response(for uri: String) async -> (HTTPResponseStatus, String, Data) {
        let signposter = OSSignposter.mediaProxy
        let signpost = signposter.beginInterval("ProxyRequest", id: signposter.makeSignpostID())
        var status = HTTPResponseStatus.internalServerError
        defer { signposter.endInterval("ProxyRequest", signpost, "status=\(status.code)") }
        let result = await route(uri)
        status = result.0
        if status != .ok {
            Logger.mediaProxy.error("proxy_response status=\(status.code) path=\(URLComponents(string: uri)?.path ?? "", privacy: .public)")
        }
        return result
    }

    private func route(_ uri: String) async -> (HTTPResponseStatus, String, Data) {
        guard let components = URLComponents(string: uri) else { return (.badRequest, "text/plain", Data()) }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return (.notFound, "text/plain", Data()) }
        let presentation = presentations[parts[0]]
        guard let presentation else { return (.notFound, "text/plain", Data()) }
        switch parts.dropFirst().joined(separator: "/") {
        case "master.m3u8": return (.ok, "application/vnd.apple.mpegurl", Data(presentation.master.utf8))
        case "video.m3u8":
            guard let video = presentation.video else { return (.notFound, "text/plain", Data()) }
            return (.ok, "application/vnd.apple.mpegurl", Data(video.utf8))
        case "audio.m3u8":
            guard let audio = presentation.audio else { return (.notFound, "text/plain", Data()) }
            return (.ok, "application/vnd.apple.mpegurl", Data(audio.utf8))
        case let name where presentation.subtitlePlaylists[name] != nil:
            return (.ok, "application/vnd.apple.mpegurl", Data((presentation.subtitlePlaylists[name] ?? "").utf8))
        case let name where presentation.subtitleTexts[name] != nil:
            // A subtitle the plugin cannot provide is missing; playback goes on without it.
            guard let text = try? await presentation.subtitleTexts[name]?.value() else { return (.notFound, "text/plain", Data()) }
            return (.ok, "text/vtt", Data(text.utf8))
        default:
            guard parts.count >= 4, ["video", "audio"].contains(parts[1]) else {
                return (.notFound, "text/plain", Data())
            }
            lastForegroundRequest = Date()
            var upstream = "https://grayjay.internal/" + parts.dropFirst().joined(separator: "/")
            if let query = components.percentEncodedQuery { upstream += "?" + query }
            do {
                let data = try await rawSegment(id: parts[0], presentation: presentation, kind: parts[1], upstream: upstream)
                // WebM segments become fragmented MP4 here, every platform alike;
                // the cache keeps the bytes as the plugin returned them.
                if let timeline = presentation.webm[parts[1]] {
                    let remuxed = try await remuxWebM(id: parts[0], presentation: presentation, kind: parts[1],
                                                      timeline: timeline, upstream: upstream, data: data)
                    return (.ok, "video/mp4", remuxed)
                }
                return (.ok, "video/mp4", data)
            } catch let error as PluginError {
                presentation.failure(error)
                return (.badGateway, "text/plain", Data(error.localizedDescription.utf8))
            } catch let error as Matroska.Failure {
                // A format MP4 cannot carry (Vorbis) is said by name, not retried.
                Logger.mediaProxy.error("webm_remux_failed reason=\(String(describing: error), privacy: .public)")
                presentation.failure(.execution(error.localizedDescription))
                return (.badGateway, "text/plain", Data(error.localizedDescription.utf8))
            } catch {
                return (.badGateway, "text/plain", Data(error.localizedDescription.utf8))
            }
        }
    }

    /// A segment's bytes as the plugin returned them: from the cache, or
    /// fetched through the plugin's executor (and cached).
    private func rawSegment(id: String, presentation: Presentation, kind: String, upstream: String) async throws -> Data {
        if let cache = presentation.cache,
           let cached = try await mediaCache.read(cache, name: upstream) {
            OSSignposter.mediaProxy.emitEvent("UMPCacheHit", "track=\(kind, privacy: .public) bytes=\(cached.count)")
            return cached
        }
        foregroundRequests += 1
        defer { foregroundRequests -= 1 }
        let (requestRuntime, requestExecutor) = Self.executor(for: upstream, in: presentation)
        let segment = OSSignposter.mediaProxy.beginInterval(
            "UMPSegment", id: OSSignposter.mediaProxy.makeSignpostID(), "track=\(kind, privacy: .public)"
        )
        let data: Data
        do {
            data = try await fetchSegment(presentation: id, runtime: requestRuntime,
                                          executor: requestExecutor, upstream: upstream)
            OSSignposter.mediaProxy.endInterval("UMPSegment", segment, "bytes=\(data.count)")
        } catch {
            OSSignposter.mediaProxy.endInterval("UMPSegment", segment, "failed")
            throw error
        }
        if let cache = presentation.cache {
            // Cache exhaustion must never turn successfully fetched media
            // into a 502 response. The cache is an optimization; AVPlayer
            // still needs the bytes the plugin already returned.
            do {
                try await mediaCache.write(data, to: cache, name: upstream)
            } catch {
                Logger.mediaProxy.error("cache_write_failed prefetch=false message=\(error.localizedDescription)")
            }
        }
        return data
    }

    /// One WebM DASH segment (`upstream`, whose bytes are `data`) as fragmented MP4.
    private func remuxWebM(id: String, presentation: Presentation, kind: String, timeline: WebMTimeline,
                           upstream: String, data: Data) async throws -> Data {
        let key = WebMTimeline.requestKey(upstream)
        let remuxer: WebMDashTrack
        if let known = webmTracks["\(id)/\(kind)"] {
            remuxer = known
        } else {
            // The sample description needs the headers and the first keyframe.
            let initialization = key == timeline.initialization ? data
                : try await rawSegment(id: id, presentation: presentation, kind: kind,
                                       upstream: Self.loopbackUpstream(timeline.initializationUpstream))
            let firstKey = WebMTimeline.requestKey(timeline.firstMediaUpstream)
            let first = key == firstKey ? data
                : try await rawSegment(id: id, presentation: presentation, kind: kind,
                                       upstream: Self.loopbackUpstream(timeline.firstMediaUpstream))
            remuxer = try WebMDashTrack(initialization: [UInt8](initialization), firstSegment: [UInt8](first))
            webmTracks["\(id)/\(kind)"] = remuxer
        }
        if key == timeline.initialization { return remuxer.initializationSegment() }
        guard let index = timeline.index[key] else { throw Matroska.Failure.malformed("unknown segment") }
        return try remuxer.mediaSegment([UInt8](data), index: index, start: timeline.starts[index],
                                        duration: timeline.durations[index])
    }

    /// A manifest URL as the proxy names it (the host requests arrive under).
    private static func loopbackUpstream(_ manifestURL: String) -> String {
        "https://grayjay.internal" + WebMTimeline.requestKey(manifestURL)
    }

    /// AVPlayer issues startup and seek requests as short bursts with tiny gaps.
    /// Treat those gaps as foreground activity so whole-file prefetch cannot
    /// repeatedly take the serial JavaScript executor between adjacent segments.
    private var foregroundWasRecentlyActive: Bool {
        guard let lastForegroundRequest else { return false }
        return Date().timeIntervalSince(lastForegroundRequest) < 2
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
    struct Resource: Sendable { let upstream: String }
    struct Result {
        let master: String
        let video: String?
        let audio: String?
        let resources: [Resource]
        /// The WebM tracks ("video", "audio"), remuxed segment by segment as served.
        var webm: [String: WebMTimeline] = [:]
        let estimatedBytes: Int64
        /// The presentation's length (the longest track), for subtitle playlists.
        var duration: Double = 0
    }
    fileprivate struct Track {
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
        /// The adaptation set's `lang`.
        /// The segments are WebM (remuxed to fragmented MP4 as they are served).
        var isWebM = false
        var language: String? = nil
        /// DASH `Role` "description" or an audio-purpose Accessibility of 1: an audio description.
        var describesVideo = false
    }

    static func convert(_ mpd: String, baseURL: String) throws -> Result {
        let sets = matches(#"<AdaptationSet\b([^>]*)>([\s\S]*?)</AdaptationSet>"#, in: mpd)
        let tracks = sets.compactMap { values -> Track? in
            let attributes = values[0]
            let body = values[1]
            let representationAttributes = firstMatch(#"<Representation\b([^>]*)>"#, in: body)?.first
            let kind = attribute("contentType", in: attributes)
                ?? attribute("mimeType", in: attributes)?.split(separator: "/").first.map(String.init)
                ?? representationAttributes.flatMap { attribute("mimeType", in: $0) }?
                    .split(separator: "/").first.map(String.init)
            guard let kind else { return nil }
            var track = parseTrack(kind: kind, body: body)
            track?.isWebM = (attributes + " " + (representationAttributes ?? "")).contains("webm")
            track?.language = attribute("lang", in: attributes)
            track?.describesVideo = body.contains("value=\"description\"")
                || body.range(of: #"AudioPurposeCS:2007"\s+value="1""#, options: .regularExpression) != nil
            return track
        }
        let video = tracks.first(where: { $0.kind == "video" })
        let audio = tracks.first(where: { $0.kind == "audio" })
        guard video != nil || audio != nil else {
            throw PluginError.execution("The generated DASH manifest has no playable tracks")
        }
        let videoPlaylist = video.map { mediaPlaylist($0, baseURL: baseURL) }
        let audioPlaylist = audio.map { mediaPlaylist($0, baseURL: baseURL) }
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n"
        if video != nil, audio != nil {
            // Language and audio-description characteristics carry over from the DASH adaptation set.
            let rendition = HLSPlaylist.Rendition(
                groupID: "audio", name: audio?.describesVideo == true ? "Audio Description" : "Audio",
                language: audio?.language, isDefault: true, uri: nil, autoselect: true,
                characteristics: audio?.describesVideo == true ? "public.accessibility.describes-video" : nil
            )
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",\(rendition.attributes(uri: "\(baseURL)/audio.m3u8"))\n"
        }
        let selectedTracks = [video, audio].compactMap { $0 }
        let codecs = selectedTracks.map(\.codec).joined(separator: ",")
        let bandwidth = selectedTracks.reduce(0) { $0 + $1.bandwidth }
        master += "#EXT-X-STREAM-INF:BANDWIDTH=\(max(1, bandwidth))"
        // A WebM track's DASH codec ("vp9") is not an MP4 codec string, and the
        // exact one is known only from its initialization segment: no CODECS then.
        if !selectedTracks.contains(where: \.isWebM) { master += ",CODECS=\"\(codecs)\"" }
        if let video {
            master += ",RESOLUTION=\(video.width)x\(video.height)"
            if audio != nil { master += ",AUDIO=\"audio\"" }
            master += "\n\(baseURL)/video.m3u8\n"
        } else {
            master += "\n\(baseURL)/audio.m3u8\n"
        }
        let resources = selectedTracks.flatMap { track -> [Resource] in
            [Resource(upstream: track.initialization)] + track.durations.indices.map { offset in
                Resource(upstream: track.media.replacingOccurrences(
                    of: "$Number$", with: String(track.startNumber + offset)
                ))
            }
        }
        let estimatedBytes = selectedTracks.reduce(Int64(0)) { total, track in
            let seconds = track.durations.reduce(0, +)
            return total + Int64(ceil(Double(max(track.bandwidth, 1)) * seconds / 8 * 2.0))
        }
        var result = Result(master: master, video: videoPlaylist, audio: audioPlaylist,
                            resources: resources, estimatedBytes: max(estimatedBytes, 16 * 1_024 * 1_024),
                            duration: selectedTracks.map { $0.durations.reduce(0, +) }.max() ?? 0)
        for track in selectedTracks where track.isWebM {
            result.webm[track.kind] = WebMTimeline(track)
        }
        return result
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

/// Where one WebM DASH track's segments lie in time, by request: the proxy
/// remuxes each to fragmented MP4 as it serves it (`WebMDashTrack`).
struct WebMTimeline: Sendable {
    /// `requestKey` of the initialization segment.
    let initialization: String
    let initializationUpstream: String
    let firstMediaUpstream: String
    /// `requestKey` of each media segment: its index.
    let index: [String: Int]
    let starts: [Double]
    let durations: [Double]

    fileprivate init(_ track: DashToHLS.Track) {
        initializationUpstream = track.initialization
        initialization = Self.requestKey(track.initialization)
        let media = track.durations.indices.map {
            track.media.replacingOccurrences(of: "$Number$", with: String(track.startNumber + $0))
        }
        firstMediaUpstream = media.first ?? track.initialization
        index = Dictionary(media.enumerated().map { (Self.requestKey($0.element), $0.offset) }, uniquingKeysWith: { first, _ in first })
        var start = 0.0
        starts = track.durations.map { duration in defer { start += duration }; return start }
        durations = track.durations
    }

    /// A segment's identity in requests: its path and query (the host differs
    /// between the manifest and the loopback request).
    static func requestKey(_ upstream: String) -> String {
        guard let url = URL(string: upstream) else { return upstream }
        return url.path + (url.query.map { "?" + $0 } ?? "")
    }
}

/// A WebM DASH track's segments as fragmented MP4: the initialization
/// segment's headers and the first keyframe give the sample description;
/// each media segment's clusters become one fragment.
struct WebMDashTrack: Sendable {
    let file: Matroska.File
    let track: Matroska.TrackInfo
    let description: Matroska.SampleDescription

    init(initialization: [UInt8], firstSegment: [UInt8]) throws {
        file = try Matroska.initialization(initialization)
        guard let track = file.tracks.first(where: { $0.kind != .other }) else {
            throw Matroska.Failure.malformed("no audio or video track")
        }
        self.track = track
        var keyframe: [UInt8] = []
        if track.codecID == "V_VP9" || track.codecID == "V_VP8",
           let frame = try Matroska.frames(in: firstSegment, trackNumber: track.number).first(where: \.isKey) {
            keyframe = Array(firstSegment[frame.data])
        }
        description = try Matroska.sampleDescription(track, firstFrame: keyframe)
    }

    func initializationSegment() -> Data {
        Matroska.initializationSegment(file: file, track: track, description: description,
                                       timescale: Matroska.timescale(for: file.timecodeScale))
    }

    /// Media segment `index` (0-based), from its DASH start and duration in seconds.
    func mediaSegment(_ bytes: [UInt8], index: Int, start: Double, duration: Double) throws -> Data {
        let units = 1e9 / Double(file.timecodeScale)
        let segment = Matroska.Segment(start: UInt64(max(0, start * units).rounded()),
                                       end: UInt64(max(0, (start + duration) * units).rounded()),
                                       bytes: 0..<Int64(bytes.count))
        return try Matroska.fragment(clusters: bytes, file: file, track: track, segment: segment,
                                     sequence: UInt32(index + 1))
    }
}

extension PluginMediaProxy: SuspendedResource {
    /// Binds again on the same port: the presentations' playlists name it.
    func resumeAfterSuspension() async -> PortMove? {
        guard let before = boundPort else { return nil }
        let reachable = await LoopbackLifecycle.accepts(port: before)
        if let open = channel, !(open.isActive && reachable) {
            Logger.mediaProxy.notice("proxy_unreachable port=\(before)")
            open.close(promise: nil)
            channel = nil
        }
        guard let after = try? await serverChannel().localAddress?.port else {
            Logger.mediaProxy.error("proxy_resume_failed")
            return nil
        }
        guard after != before else { return nil }
        Logger.mediaProxy.fault("proxy_port_moved from=\(before) to=\(after)")
        return PortMove(from: before, to: after)
    }

    func reclaimAsSuspensionWould() async {
        let open = connections.takeAll()
        try? await channel?.close()
        for child in open { try? await child.close() }
    }
}
