import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import os

/// Serves cached VOD tracks to the player over loopback HTTP.
///
/// A file request for bytes that are not cached yet waits for the
/// downloader (which moves those bytes to the front of its queue) instead of
/// failing, so a network outage looks like buffering to the player and never
/// like a broken track. Built on NIO's async channels: each connection is a
/// structured task, writes apply back-pressure, and nothing here needs
/// unchecked sendability.
actor LocalMediaServer {
    struct ServedFile: Sendable {
        let downloader: TrackDownloader
        let contentType: String
    }

    /// One cached HLS resource (segment, map or key), served whole.
    struct ServedObject: Sendable {
        let downloader: HLSRenditionDownloader
        let index: Int
        let contentType: String
    }

    /// Text made on request (a plugin subtitle as WebVTT), served whole.
    struct ServedText: Sendable {
        let contentType: String
        let text: OnceText
    }

    struct Presentation: Sendable {
        var playlists: [String: String] = [:]
        var texts: [String: ServedText] = [:]
        var files: [String: ServedFile] = [:]
        var objects: [String: ServedObject] = [:]
        /// Live renditions by path prefix: `<prefix>.m3u8` is their growing
        /// playlist, `<prefix>/<id>` their recorded resources.
        var live: [String: LiveHLSRecorder] = [:]
        /// Progressive files served as fragmented MP4, by path prefix:
        /// `<prefix>/init.mp4` and `<prefix>/<n>.m4s` (see `ProgressiveMP4`).
        var remuxed: [String: RemuxedTrack] = [:]
    }

    private typealias Connection = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>

    private var presentations: [String: Presentation] = [:]
    private var port: Int?
    private var starting: Task<Int, Error>?
    private var lastPort: Int?
    private var listener: Task<Void, Never>?
    /// The listening channel, so a dead one can be noticed and replaced.
    private var serverChannel: (any Channel)?
    /// Times the listener was re-established (tests, diagnostics).
    private(set) var restarts = 0
    /// Accepted connections, so a suspension (and its simulation) can close them.
    private var connections: [ObjectIdentifier: any Channel] = [:]
    /// Reclaimed as a suspension does: nothing is bound again until the app resumes.
    private var suspended = false

    init() {
        LoopbackLifecycle.shared.register(self)
    }

    /// Registers a presentation; returns its base URL (ending in `/`).
    func register(_ presentation: Presentation) async throws -> (id: String, base: URL) {
        let port = try await serverPort()
        let id = UUID().uuidString.lowercased()
        presentations[id] = presentation
        guard let base = URL(string: "http://127.0.0.1:\(port)/\(id)/") else {
            throw TrackDownloadError.unexpectedResponse("loopback URL")
        }
        return (id, base)
    }

    func unregister(_ id: String) {
        presentations[id] = nil
    }

    private enum Route: Sendable {
        case playlist(String)
        case file(ServedFile)
        case object(ServedObject)
        case text(ServedText)
        case remuxed(RemuxedTrack, String)
        case livePlaylist(LiveHLSRecorder, String)
        case liveObject(LiveHLSRecorder, String)
        case notFound
    }

    private func route(_ path: String) -> Route {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, let presentation = presentations[parts[0]] else { return .notFound }
        let name = parts.dropFirst().joined(separator: "/")
        if let playlist = presentation.playlists[name] { return .playlist(playlist) }
        if let file = presentation.files[name] { return .file(file) }
        if let object = presentation.objects[name] { return .object(object) }
        if let text = presentation.texts[name] { return .text(text) }
        for (prefix, track) in presentation.remuxed where name.hasPrefix("\(prefix)/") {
            return .remuxed(track, String(name.dropFirst(prefix.count + 1)))
        }
        for (prefix, recorder) in presentation.live {
            if name == "\(prefix).m3u8" { return .livePlaylist(recorder, prefix) }
            if name.hasPrefix("\(prefix)/") { return .liveObject(recorder, String(name.dropFirst(prefix.count + 1))) }
        }
        return .notFound
    }

    // MARK: server

    private func serverPort() async throws -> Int {
        if let port { return port }
        if let starting { return try await starting.value }
        let previous = lastPort
        let task = Task<Int, Error> {
            // Rebinding the port the player already knows keeps its URLs valid.
            let server: NIOAsyncChannel<Connection, Never>
            if let previous, let rebound = try? await Self.bind(port: previous) {
                server = rebound
            } else {
                server = try await Self.bind(port: 0)
            }
            guard let port = server.channel.localAddress?.port else {
                throw TrackDownloadError.unexpectedResponse("no loopback port")
            }
            self.listen(on: server)
            return port
        }
        starting = task
        do {
            let value = try await task.value
            port = value
            lastPort = value
            starting = nil
            return value
        } catch {
            starting = nil
            throw error
        }
    }

    private static func bind(port: Int) async throws -> NIOAsyncChannel<Connection, Never> {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try Connection(wrappingChannelSynchronously: channel)
                }
            }
    }

    /// The server lives as long as the stores that own it (the process). If
    /// its socket dies (iOS reclaims sockets of a suspended app), it is bound
    /// again, on the same port, so the player's URLs keep working.
    private func listen(on server: NIOAsyncChannel<Connection, Never>) {
        serverChannel = server.channel
        let channel = server.channel
        listener = Task {
            do {
                try await withThrowingDiscardingTaskGroup { group in
                    try await server.executeThenClose { inbound in
                        for try await connection in inbound {
                            group.addTask { await self.serve(connection) }
                        }
                    }
                }
                Logger.mediaCache.error("server_stopped")
            } catch {
                Logger.mediaCache.error("server_stopped message=\(error.localizedDescription)")
            }
            await self.listenerEnded(channel)
        }
    }

    private func listenerEnded(_ channel: any Channel) async {
        guard serverChannel === channel else { return }
        serverChannel = nil
        port = nil
        restarts += 1
        // A suspended app runs nothing: the listener comes back when it resumes.
        guard !suspended else { return }
        let previous = lastPort
        // Bind again until it works: the player may be waiting on it.
        var delay = Duration.milliseconds(100)
        while port == nil, !Task.isCancelled {
            do {
                let value = try await serverPort()
                Logger.mediaCache.notice("server_restarted port_kept=\(value == previous)")
                return
            } catch {
                Logger.mediaCache.error("server_restart_failed message=\(error.localizedDescription)")
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(5))
            }
        }
    }

    /// Re-establishes the listener if its socket died (the app was suspended);
    /// the app calls this when it becomes active. Returns the port.
    @discardableResult
    func ensureListening() async throws -> Int {
        // A suspended app's socket can be dead while NIO still thinks it is
        // open: connect to it to know.
        if let channel = serverChannel, let port, !(await Self.accepts(port: port)) {
            Logger.mediaCache.notice("server_unreachable port=\(port)")
            channel.close(promise: nil)
            await listenerEnded(channel)
        } else if let channel = serverChannel, !channel.isActive {
            channel.close(promise: nil)
            await listenerEnded(channel)
        }
        return try await serverPort()
    }

    /// Whether a loopback connection to `port` is accepted within a second.
    private static func accepts(port: Int) async -> Bool {
        do {
            let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(1))
                .connect(host: "127.0.0.1", port: port).get()
            try? await channel.close()
            return true
        } catch {
            return false
        }
    }

    /// Closes the listening socket as iOS does to a suspended app (tests).
    func simulateSocketReclaim() async {
        try? await serverChannel?.close()
    }

    private func track(_ channel: any Channel) { connections[ObjectIdentifier(channel)] = channel }
    private func untrack(_ channel: any Channel) { connections[ObjectIdentifier(channel)] = nil }

    private nonisolated func serve(_ connection: Connection) async {
        let channel = connection.channel
        await track(channel)
        defer { Task { await self.untrack(channel) } }
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                for try await part in inbound {
                    switch part {
                    case .head(let requestHead): head = requestHead
                    case .body: break
                    case .end:
                        guard let requestHead = head else { continue }
                        head = nil
                        try await self.respondUntilClosed(requestHead, channel: channel, outbound: outbound)
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            // The player closing a connection mid-response is routine.
            Logger.mediaCache.debug("connection_closed message=\(error.localizedDescription)")
        }
    }

    /// A request whose connection the player closes (it seeked, gave up or
    /// timed out) is cancelled, so it stops steering the download.
    private nonisolated func respondUntilClosed(_ request: HTTPRequestHead, channel: any Channel,
                                                outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let response = Task { try await self.respond(to: request, outbound: outbound) }
        channel.closeFuture.whenComplete { _ in response.cancel() }
        try await withTaskCancellationHandler {
            try await response.value
        } onCancel: {
            response.cancel()
        }
    }

    private nonisolated func respond(to request: HTTPRequestHead,
                                     outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let path = URLComponents(string: request.uri)?.path ?? request.uri
        switch await route(path) {
        case .notFound:
            try await send(status: .notFound, contentType: "text/plain", body: Data(), request: request, outbound: outbound)
        case .playlist(let text):
            try await send(status: .ok, contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8),
                           request: request, outbound: outbound)
        case .file(let file):
            try await sendFile(file, request: request, outbound: outbound)
        case .remuxed(let track, let name):
            guard let data = try await track.resource(name) else {
                try await send(status: .notFound, contentType: "text/plain", body: Data(), request: request, outbound: outbound)
                return
            }
            try await send(status: .ok, contentType: "video/mp4", body: data, request: request, outbound: outbound)
        case .text(let served):
            // A text that cannot be made (the plugin failed) is missing, not broken:
            // the player leaves that subtitle unavailable and plays on.
            guard let text = try? await served.text.value() else {
                try await send(status: .notFound, contentType: "text/plain", body: Data(), request: request, outbound: outbound)
                return
            }
            try await send(status: .ok, contentType: served.contentType, body: Data(text.utf8), request: request, outbound: outbound)
        case .livePlaylist(let recorder, let prefix):
            // Low-latency blocking reload: hold the response until the asked-for
            // segment or part is recorded.
            let query = URLComponents(string: request.uri)?.queryItems ?? []
            if let msn = query.first(where: { $0.name == "_HLS_msn" })?.value.flatMap({ Int($0) }) {
                let part = query.first(where: { $0.name == "_HLS_part" })?.value.flatMap { Int($0) }
                await recorder.waitForPlaylist(msn: msn, part: part)
            }
            let text = await recorder.localPlaylist(prefix: prefix)
            try await send(status: .ok, contentType: "application/vnd.apple.mpegurl", body: Data(text.utf8),
                           request: request, outbound: outbound)
        case .liveObject(let recorder, let id):
            try await recorder.waitForResource(id)
            let data = try await recorder.readResource(id)
            try await send(status: .ok, contentType: await recorder.contentType(of: id), body: data,
                           request: request, outbound: outbound)
        case .object(let object):
            try await object.downloader.waitForResource(object.index)
            let data = try await object.downloader.readResource(object.index)
            let total = Int64(data.count)
            if let header = request.headers.first(name: "Range"), let range = Self.parseRange(header, total: total) {
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: object.contentType)
                headers.add(name: "Content-Length", value: String(range.count))
                headers.add(name: "Content-Range", value: "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)")
                try await outbound.write(.head(HTTPResponseHead(version: request.version, status: .partialContent, headers: headers)))
                if request.method != .HEAD {
                    try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))))))
                }
                try await outbound.write(.end(nil))
            } else {
                try await send(status: .ok, contentType: object.contentType, body: data, request: request, outbound: outbound)
            }
        }
    }

    private nonisolated func send(status: HTTPResponseStatus, contentType: String, body: Data,
                                  request: HTTPRequestHead,
                                  outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.count))
        try await outbound.write(.head(HTTPResponseHead(version: request.version, status: status, headers: headers)))
        if request.method != .HEAD, !body.isEmpty {
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: body))))
        }
        try await outbound.write(.end(nil))
    }

    private nonisolated func sendFile(_ file: ServedFile, request: HTTPRequestHead,
                                      outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>) async throws {
        let total = try await file.downloader.totalBytesWhenKnown()
        let requested = request.headers.first(name: "Range").flatMap { Self.parseRange($0, total: total) }
        if request.headers.first(name: "Range") != nil, requested == nil {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Range", value: "bytes */\(total)")
            headers.add(name: "Content-Length", value: "0")
            try await outbound.write(.head(HTTPResponseHead(version: request.version, status: .rangeNotSatisfiable, headers: headers)))
            try await outbound.write(.end(nil))
            return
        }
        let range = requested ?? 0..<total
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: file.contentType)
        headers.add(name: "Accept-Ranges", value: "bytes")
        headers.add(name: "Content-Length", value: String(range.count))
        if requested != nil {
            headers.add(name: "Content-Range", value: "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)")
        }
        let status: HTTPResponseStatus = requested == nil ? .ok : .partialContent
        try await outbound.write(.head(HTTPResponseHead(version: request.version, status: status, headers: headers)))
        guard request.method != .HEAD else {
            try await outbound.write(.end(nil))
            return
        }
        let signposter = OSSignposter.mediaCache
        let signpost = signposter.beginInterval("VODServe", id: signposter.makeSignpostID(),
                                                "role=\(file.downloader.role.rawValue, privacy: .public) offset=\(range.lowerBound) bytes=\(range.count)")
        var outcome = "closed"
        defer { signposter.endInterval("VODServe", signpost, "\(outcome, privacy: .public)") }
        let step: Int64 = 256 * 1_024
        var offset = range.lowerBound
        while offset < range.upperBound {
            let piece = offset..<min(range.upperBound, offset + step)
            let waitStarted = ContinuousClock.now
            do {
                try await file.downloader.waitUntilAvailable(piece)
            } catch {
                Self.logWait(since: waitStarted, role: file.downloader.role.rawValue, offset: piece.lowerBound, outcome: "abandoned")
                throw error
            }
            Self.logWait(since: waitStarted, role: file.downloader.role.rawValue, offset: piece.lowerBound, outcome: "served")
            guard let data = try await file.downloader.read(piece) else {
                throw TrackDownloadError.unexpectedResponse("cache lost bytes")
            }
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: data))))
            offset = piece.upperBound
        }
        try await outbound.write(.end(nil))
        outcome = "served"
    }

    /// Logs a player request that had to wait for bytes (over half a second).
    private static func logWait(since start: ContinuousClock.Instant, role: String, offset: Int64, outcome: StaticString) {
        let waited = start.duration(to: .now)
        guard waited > .milliseconds(500) else { return }
        let ms = Int(waited.components.seconds * 1_000 + waited.components.attoseconds / 1_000_000_000_000_000)
        Logger.mediaCache.notice("local_request_wait role=\(role, privacy: .public) offset=\(offset) ms=\(ms) outcome=\(outcome, privacy: .public)")
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n`; one range only.
    static func parseRange(_ value: String, total: Int64) -> Range<Int64>? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes="), total > 0 else { return nil }
        let spec = trimmed.dropFirst(6)
        guard !spec.contains(",") else { return nil }
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let first = bounds[0].trimmingCharacters(in: .whitespaces)
        let last = bounds[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let suffix = Int64(last), suffix > 0 else { return nil }
            return max(0, total - suffix)..<total
        }
        guard let start = Int64(first), start < total else { return nil }
        if last.isEmpty { return start..<total }
        guard let end = Int64(last), end >= start else { return nil }
        return start..<(min(end, total - 1) + 1)
    }
}

extension TrackDownloader {
    /// The track's length, waiting for the downloader to learn it.
    func totalBytesWhenKnown() async throws -> Int64 {
        while true {
            if let total = knownTotalBytes { return total }
            if isStopped { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

extension LocalMediaServer: SuspendedResource {
    func resumeAfterSuspension() async -> PortMove? {
        suspended = false
        _ = try? await ensureListening()
        return nil
    }

    func reclaimAsSuspensionWould() async {
        suspended = true
        let open = Array(connections.values)
        connections = [:]
        try? await serverChannel?.close()
        for channel in open { try? await channel.close() }
    }
}
