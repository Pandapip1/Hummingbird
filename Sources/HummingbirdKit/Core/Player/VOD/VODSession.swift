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

/// What to download for an on-demand HLS presentation.
struct HLSPresentationSpec: Sendable {
    /// Stable identity of the presentation (plugin, content URL, source).
    var identity: String
    var url: URL
    var signer: UpstreamURLSigner
    /// Fresh request signing and playlist URL after the old ones expired.
    var refresh: (@Sendable () async throws -> (UpstreamURLSigner, URL))?
    var maxHeight: Int
    var language: String?
}

/// One on-demand video a player is watching, served from the media cache.
///
/// Starting a session holds every track's download in the foreground (the
/// downloads themselves belong to `MediaDownloads`), waits only for what the
/// player needs first (each file's layout, or the HLS playlists), and returns
/// a `LocalPlayback` pointing at the loopback server:
/// - Fragmented MP4 files become a byte-range HLS presentation (video and
///   audio as separate renditions of one asset); other files are served whole
///   with range support.
/// - Upstream HLS is rewritten to local URIs; every segment, map and key is
///   downloaded into the cache.
/// Stopping the session releases the downloads, which continue in the
/// background until the video is fully cached.
actor VODSession {
    private let server: LocalMediaServer
    private let downloads: MediaDownloads
    private var heldTracks: [String] = []
    private var heldRenditions: [String] = []
    private var presentationID: String?
    private var trackStates: [MediaTrackRole: MediaTrackPipelineState] = [:]
    private var order: [MediaTrackRole] = []
    private let continuation: AsyncStream<MediaPipelineSnapshot>.Continuation
    nonisolated let states: AsyncStream<MediaPipelineSnapshot>

    private init(server: LocalMediaServer, downloads: MediaDownloads) {
        self.server = server
        self.downloads = downloads
        let stream = AsyncStream.makeStream(of: MediaPipelineSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        states = stream.stream
        continuation = stream.continuation
    }

    // MARK: files

    /// Starts (or joins) the download of `video` (and `audio`, when separate)
    /// and returns the session with the playback to load.
    static func start(video: VODTrackSpec, audio: VODTrackSpec?, downloads: MediaDownloads,
                      server: LocalMediaServer) async throws -> (VODSession, LocalPlayback) {
        let session = VODSession(server: server, downloads: downloads)
        do {
            return (session, try await session.beginFiles([video, audio].compactMap { $0 }))
        } catch {
            await session.stop()
            throw error
        }
    }

    private func beginFiles(_ specs: [VODTrackSpec]) async throws -> LocalPlayback {
        var downloaders: [TrackDownloader] = []
        for spec in specs {
            let downloader = try await downloads.hold(spec)
            heldTracks.append(spec.identity)
            downloaders.append(downloader)
            order.append(spec.role)
            let role = spec.role
            _ = await downloader.observe { [weak self] state in
                Task { await self?.update(role, state) }
            }
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
            let base = try await register(presentation)
            Logger.mediaCache.info("vod_presentation kind=indexed tracks=\(tracks.count)")
            return try LocalPlayback(video: base.appendingPathComponent("master.m3u8"), servedBy: .mediaCache)
        }
        var names: [String] = []
        for (index, spec) in specs.enumerated() {
            let name = "\(spec.role.rawValue).\(Self.fileExtension(for: spec.container, role: spec.role))"
            names.append(name)
            presentation.files[name] = .init(downloader: downloaders[index],
                                             contentType: spec.container.isEmpty ? "application/octet-stream" : spec.container)
        }
        let base = try await register(presentation)
        Logger.mediaCache.info("vod_presentation kind=file tracks=\(names.count)")
        return try LocalPlayback(video: base.appendingPathComponent(names[0]),
                                 audio: names.count > 1 ? base.appendingPathComponent(names[1]) : nil,
                                 servedBy: .mediaCache)
    }

    // MARK: HLS

    /// Starts (or joins) the download of an on-demand HLS presentation: the
    /// best variant at or under `maxHeight` and its audio rendition.
    static func start(hls spec: HLSPresentationSpec, downloads: MediaDownloads, server: LocalMediaServer,
                      transport: any MediaTransport = URLSessionTransport(session: TrackDownloader.sharedSession))
        async throws -> (VODSession, LocalPlayback) {
        let session = VODSession(server: server, downloads: downloads)
        do {
            return (session, try await session.beginHLS(spec, transport: transport))
        } catch {
            await session.stop()
            throw error
        }
    }

    /// The chosen renditions' media playlists.
    private struct Selection: Sendable {
        var master: HLSPlaylist.Master?
        var variant: HLSPlaylist.Variant?
        var video: HLSPlaylist.Media
        var audio: HLSPlaylist.Media?
        var audioRendition: HLSPlaylist.Rendition?
    }

    private static func select(_ spec: HLSPresentationSpec, signer: UpstreamURLSigner,
                               transport: any MediaTransport) async throws -> Selection {
        let top = try await fetchText(spec.url, signer: signer, transport: transport)
        guard HLSPlaylist.isMaster(top.text) else {
            let media = try HLSPlaylist.parseMedia(top.text, base: top.url)
            return Selection(master: nil, variant: nil, video: media, audio: nil, audioRendition: nil)
        }
        let master = try HLSPlaylist.parseMaster(top.text, base: top.url)
        guard let variant = HLSPlaylist.bestVariant(master.variants, maxHeight: spec.maxHeight) else {
            throw HLSPlaylist.Failure.notAPlaylist
        }
        let videoText = try await fetchText(variant.uri, signer: signer, transport: transport)
        let video = try HLSPlaylist.parseMedia(videoText.text, base: videoText.url)
        var audio: HLSPlaylist.Media?
        let rendition = HLSPlaylist.bestAudio(master.audio, group: variant.audioGroup, language: spec.language)
        if let uri = rendition?.uri {
            let audioText = try await fetchText(uri, signer: signer, transport: transport)
            audio = try HLSPlaylist.parseMedia(audioText.text, base: audioText.url)
        }
        return Selection(master: master, variant: variant, video: video, audio: audio, audioRendition: rendition)
    }

    private func beginHLS(_ spec: HLSPresentationSpec, transport: any MediaTransport) async throws -> LocalPlayback {
        let selection = try await Self.select(spec, signer: spec.signer, transport: transport)
        if selection.video.isEndless || selection.audio?.isEndless == true { throw HLSPlaylist.Failure.live }
        let variantKey = selection.variant.map { "\($0.height)p-\($0.bandwidth)-\($0.codecs)" } ?? "single"
        let audioKey = selection.audioRendition.map { "\($0.groupID)-\($0.language ?? "")-\($0.name)" }

        var presentation = LocalMediaServer.Presentation()
        let renditions: [(MediaTrackRole, String, HLSPlaylist.Media, String)] =
            [(selection.audio == nil ? .muxed : .video, "v", selection.video, "\(spec.identity)|hls|video|\(variantKey)")]
            + (selection.audio.map { [(.audio, "a", $0, "\(spec.identity)|hls|audio|\(audioKey ?? "")")] } ?? [])
        for (role, prefix, media, identity) in renditions {
            let cache = downloads.cache
            let scheduler = downloads.scheduler
            let refresh: (@Sendable () async throws -> (UpstreamURLSigner, [HLSPlaylist.Resource]))? = spec.refresh.map { refresh in
                { @Sendable in
                    let (signer, url) = try await refresh()
                    var current = spec
                    current.url = url
                    let fresh = try await Self.select(current, signer: signer, transport: transport)
                    let refreshed = role == .audio ? fresh.audio : fresh.video
                    guard let refreshed else { throw HLSPlaylist.Failure.notAPlaylist }
                    return (signer, refreshed.resources)
                }
            }
            let downloader = await downloads.hold(rendition: identity) {
                HLSRenditionDownloader(role: role, cache: cache, identity: identity, media: media,
                                       signer: spec.signer, refresh: refresh, transport: transport,
                                       scheduler: scheduler)
            }
            heldRenditions.append(identity)
            order.append(role)
            await downloader.observe { [weak self] state in
                Task { await self?.update(role, state) }
            }
            presentation.playlists["\(prefix).m3u8"] = HLSPlaylist.localMedia(media) { "\(prefix)/\($0)" }
            for index in media.resources.indices {
                presentation.objects["\(prefix)/\(index)"] = .init(
                    downloader: downloader, index: index, contentType: await downloader.contentType(of: index)
                )
            }
        }
        let entry: String
        if let variant = selection.variant {
            presentation.playlists["master.m3u8"] = HLSPlaylist.localMaster(
                variant: variant, videoPlaylist: "v.m3u8",
                audio: selection.audio == nil ? nil : selection.audioRendition,
                audioPlaylist: selection.audio == nil ? nil : "a.m3u8"
            )
            entry = "master.m3u8"
        } else {
            entry = "v.m3u8"
        }
        let base = try await register(presentation)
        Logger.mediaCache.info("vod_presentation kind=hls renditions=\(renditions.count)")
        return try LocalPlayback(video: base.appendingPathComponent(entry), servedBy: .mediaCache)
    }

    /// Fetches a playlist, retrying transient failures a few times.
    private static func fetchText(_ url: URL, signer: UpstreamURLSigner,
                                  transport: any MediaTransport) async throws -> (text: String, url: URL) {
        let policy = DownloadRetryPolicy()
        var attempt = 0
        while true {
            do {
                let (data, response) = try await transport.data(for: try await signer.sign(url, nil))
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw TrackDownloadError.unexpectedResponse("playlist status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                return (String(decoding: data, as: UTF8.self), http.url ?? url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt < 5 else { throw error }
                try await Task.sleep(for: .seconds(policy.delay(afterAttempt: attempt)))
            }
        }
    }

    // MARK: lifetime

    private func register(_ presentation: LocalMediaServer.Presentation) async throws -> URL {
        let (id, base) = try await server.register(presentation)
        presentationID = id
        return base
    }

    /// Stops serving. The downloads continue in the background (see
    /// `MediaDownloads`) until the video is fully cached.
    func stop() async {
        if let presentationID { await server.unregister(presentationID) }
        presentationID = nil
        for identity in heldTracks { await downloads.release(track: identity) }
        for identity in heldRenditions { await downloads.release(rendition: identity) }
        heldTracks.removeAll()
        heldRenditions.removeAll()
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
