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

    struct Presentation: Sendable {
        var playlists: [String: String] = [:]
        var files: [String: ServedFile] = [:]
    }

    private typealias Connection = NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>

    private var presentations: [String: Presentation] = [:]
    private var port: Int?
    private var starting: Task<Int, Error>?
    private var listener: Task<Void, Never>?

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
        case notFound
    }

    private func route(_ path: String) -> Route {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, let presentation = presentations[parts[0]] else { return .notFound }
        if let playlist = presentation.playlists[parts[1]] { return .playlist(playlist) }
        if let file = presentation.files[parts[1]] { return .file(file) }
        return .notFound
    }

    // MARK: server

    private func serverPort() async throws -> Int {
        if let port { return port }
        if let starting { return try await starting.value }
        let task = Task<Int, Error> {
            let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: 0) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                        return try Connection(wrappingChannelSynchronously: channel)
                    }
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
            starting = nil
            return value
        } catch {
            starting = nil
            throw error
        }
    }

    private func listen(on server: NIOAsyncChannel<Connection, Never>) {
        // The server lives as long as the stores that own it (the process).
        listener = Task {
            do {
                try await withThrowingDiscardingTaskGroup { group in
                    try await server.executeThenClose { inbound in
                        for try await connection in inbound {
                            group.addTask { await self.serve(connection) }
                        }
                    }
                }
            } catch {
                Logger.mediaCache.error("server_stopped message=\(error.localizedDescription)")
            }
        }
    }

    private nonisolated func serve(_ connection: Connection) async {
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
                        try await self.respond(to: requestHead, outbound: outbound)
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            // The player closing a connection mid-response is routine.
            Logger.mediaCache.debug("connection_closed message=\(error.localizedDescription)")
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
            try await file.downloader.waitUntilAvailable(piece)
            guard let data = try await file.downloader.read(piece) else {
                throw TrackDownloadError.unexpectedResponse("cache lost bytes")
            }
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: data))))
            offset = piece.upperBound
        }
        try await outbound.write(.end(nil))
        outcome = "served"
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
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
