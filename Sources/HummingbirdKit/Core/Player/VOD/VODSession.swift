import Foundation
import os

/// What to download for one track of an on-demand video.
struct VODTrackSpec: Sendable {
    var role: MediaTrackRole
    /// Stable identity of the track's bytes (plugin, content URL and format;
    /// never the expiring upstream URL). Keys the media cache.
    var identity: String
    var signer: UpstreamRequestSigner
    /// Asks the plugin for fresh playback details when the upstream URL expired.
    var refresh: (@Sendable () async throws -> UpstreamRequestSigner)?
    var indexHint: ClosedRange<Int64>?
    var container: String
    var codec: String
    var bandwidth: Int
    var width: Int
    var height: Int
    var declaredDuration: Double?
}

/// One on-demand video being downloaded into the media cache and served to
/// the player from it.
///
/// Starting a session starts every track's download at once, waits only for
/// each track's first bytes (its layout), and returns a `LocalPlayback`
/// pointing at the loopback server. Fragmented MP4 tracks become a byte-range
/// HLS presentation (video and audio as separate renditions of one asset);
/// other files are served whole with range support. The session's pipeline
/// state streams to the player model.
actor VODSession {
    private let server: LocalMediaServer
    private let downloaders: [TrackDownloader]
    private var presentationID: String?
    private var trackStates: [MediaTrackRole: MediaTrackPipelineState] = [:]
    private let order: [MediaTrackRole]
    private let continuation: AsyncStream<MediaPipelineSnapshot>.Continuation
    nonisolated let states: AsyncStream<MediaPipelineSnapshot>

    private init(server: LocalMediaServer, downloaders: [TrackDownloader]) {
        self.server = server
        self.downloaders = downloaders
        order = downloaders.map { $0.role }
        let stream = AsyncStream.makeStream(of: MediaPipelineSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        states = stream.stream
        continuation = stream.continuation
    }

    /// Starts downloading `video` (and `audio`, when separate) and returns
    /// the session with the playback to load.
    static func start(video: VODTrackSpec, audio: VODTrackSpec?, cache: MediaCache, server: LocalMediaServer,
                      transport: any MediaTransport = URLSessionTransport(session: TrackDownloader.sharedSession))
        async throws -> (VODSession, LocalPlayback) {
        let specs = [video, audio].compactMap { $0 }
        var downloaders: [TrackDownloader] = []
        for spec in specs {
            let track = try await cache.open(identity: spec.identity)
            downloaders.append(TrackDownloader(role: spec.role, cache: cache, track: track, signer: spec.signer,
                                               indexHint: spec.indexHint, declaredDuration: spec.declaredDuration,
                                               refreshSigner: spec.refresh, transport: transport))
        }
        let session = VODSession(server: server, downloaders: downloaders)
        do {
            let playback = try await session.begin(specs: specs)
            return (session, playback)
        } catch {
            await session.stop()
            throw error
        }
    }

    private func begin(specs: [VODTrackSpec]) async throws -> LocalPlayback {
        for downloader in downloaders {
            let role = downloader.role
            _ = await downloader.observe { [weak self] state in
                Task { await self?.update(role, state) }
            }
            await downloader.start()
        }
        let signposter = OSSignposter.mediaCache
        let signpost = signposter.beginInterval("VODStartup", id: signposter.makeSignpostID())
        defer { signposter.endInterval("VODStartup", signpost) }
        var layouts: [TrackLayout] = []
        for downloader in downloaders { layouts.append(try await downloader.trackLayout()) }

        var presentation = LocalMediaServer.Presentation()
        let indexed = layouts.compactMap { layout -> FragmentedMP4.Layout? in
            if case .indexed(let found) = layout { found } else { nil }
        }
        if indexed.count == layouts.count {
            var tracks: [CachedHLS.Track] = []
            for (index, spec) in specs.enumerated() {
                let name = spec.role.rawValue
                let track = CachedHLS.Track(role: spec.role, layout: indexed[index], fileName: "\(name).mp4",
                                            playlistName: "\(name).m3u8", codec: spec.codec,
                                            bandwidth: spec.bandwidth, width: spec.width, height: spec.height)
                tracks.append(track)
                presentation.playlists[track.playlistName] = CachedHLS.mediaPlaylist(track)
                presentation.files[track.fileName] = .init(downloader: downloaders[index],
                                                           contentType: spec.role == .audio ? "audio/mp4" : "video/mp4")
            }
            presentation.playlists["master.m3u8"] = CachedHLS.masterPlaylist(video: tracks[0], audio: tracks.count > 1 ? tracks[1] : nil)
            let (id, base) = try await server.register(presentation)
            presentationID = id
            Logger.mediaCache.info("vod_presentation kind=hls tracks=\(tracks.count)")
            return try LocalPlayback(video: base.appendingPathComponent("master.m3u8"), servedBy: .mediaCache)
        }
        var names: [String] = []
        for (index, spec) in specs.enumerated() {
            let name = "\(spec.role.rawValue).\(Self.fileExtension(for: spec.container, role: spec.role))"
            names.append(name)
            presentation.files[name] = .init(downloader: downloaders[index],
                                             contentType: spec.container.isEmpty ? "application/octet-stream" : spec.container)
        }
        let (id, base) = try await server.register(presentation)
        presentationID = id
        Logger.mediaCache.info("vod_presentation kind=file tracks=\(names.count)")
        return try LocalPlayback(video: base.appendingPathComponent(names[0]),
                                 audio: names.count > 1 ? base.appendingPathComponent(names[1]) : nil,
                                 servedBy: .mediaCache)
    }

    /// Stops downloading and serving. Everything downloaded stays cached.
    func stop() async {
        if let presentationID { await server.unregister(presentationID) }
        presentationID = nil
        for downloader in downloaders { await downloader.stop() }
        continuation.finish()
    }

    private func update(_ role: MediaTrackRole, _ state: MediaTrackPipelineState) {
        trackStates[role] = state
        continuation.yield(MediaPipelineSnapshot(tracks: order.compactMap { trackStates[$0] }))
    }

    static func fileExtension(for container: String, role: MediaTrackRole) -> String {
        switch container.lowercased() {
        case "video/mp4", "video/x-m4v", "video/m4v": "mp4"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
        case "video/quicktime", "video/mov": "mov"
        case "video/webm", "audio/webm": "webm"
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/aac", "audio/x-aac": "aac"
        case "video/3gpp": "3gp"
        default: role == .audio ? "m4a" : "mp4"
        }
    }
}
