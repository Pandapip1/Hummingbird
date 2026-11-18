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
    /// The track is the transcode stage's output (re-encoded, complete).
    var isTranscoded = false
    /// The transport for this track's upstream bytes; nil uses the downloads'
    /// shared one. Plugin media passes `PluginContentTransport` (the plugin's
    /// contained content session).
    var transport: (any MediaTransport)?
    /// How an audio track is listed in the local master: its name, language
    /// and characteristics (an audio description is marked as one).
    var rendition: HLSPlaylist.Rendition?
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
    private var heldRecordings: [String] = []
    private var info: DownloadInfo?
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
    /// and returns the session with the playback to load. `subtitles` become
    /// SUBTITLES renditions when the tracks are served as HLS (fragmented
    /// MP4); whole files have no master playlist to carry them.
    static func start(video: VODTrackSpec, audio: VODTrackSpec?, subtitles: [LocalSubtitle] = [], downloads: MediaDownloads,
                      server: LocalMediaServer, info: DownloadInfo? = nil) async throws -> (VODSession, LocalPlayback) {
        let session = VODSession(server: server, downloads: downloads)
        await session.setInfo(info)
        do {
            return (session, try await session.beginFiles([video, audio].compactMap { $0 }, subtitles: subtitles))
        } catch {
            await session.stop()
            throw error
        }
    }

    private func beginFiles(_ specs: [VODTrackSpec], subtitles: [LocalSubtitle]) async throws -> LocalPlayback {
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
        // Every MP4 is served as HLS: indexed fragmented files as byte-range
        // segments, progressive files remuxed to fragments as they download.
        // Only what cannot be read as MP4 (WebM…) is served as a whole file.
        var video: CachedHLS.MasterEntry?
        var audio: CachedHLS.MasterEntry?
        var duration: Double?
        var servedAsHLS = true
        for (index, spec) in specs.enumerated() where servedAsHLS {
            switch layouts[index] {
            case .indexed(let layout):
                let name = spec.role.rawValue
                let track = CachedHLS.Track(role: spec.role, layout: layout, fileName: "\(name).mp4",
                                            playlistName: "\(name).m3u8", codec: spec.codec,
                                            bandwidth: spec.bandwidth, width: spec.width, height: spec.height)
                presentation.playlists[track.playlistName] = CachedHLS.mediaPlaylist(track)
                presentation.files[track.fileName] = .init(downloader: downloaders[index],
                                                           contentType: spec.role == .audio ? "audio/mp4" : "video/mp4")
                if spec.role == .audio { audio = track.entry } else { video = track.entry }
                duration = duration ?? layout.timeline.segments.reduce(0) { $0 + $1.duration }
            case .progressive:
                guard let movie = try await Self.remuxableMovie(downloaders[index]) else { servedAsHLS = false; continue }
                // A file with both tracks (muxed) gives the video and, without a separate audio file, the audio.
                var wanted: [(ProgressiveMP4.Kind, Bool)] = spec.role == .audio ? [(.audio, true)] : [(.video, false)]
                if spec.role != .audio, specs.count == 1 { wanted.append((.audio, true)) }
                for (kind, isAudio) in wanted {
                    guard let track = movie.track(kind) else {
                        if !isAudio { servedAsHLS = false }
                        continue
                    }
                    let prefix = isAudio ? "ra" : "rv"
                    let remuxed = RemuxedTrack(movie: movie, track: track, downloader: downloaders[index])
                    presentation.remuxed[prefix] = remuxed
                    presentation.playlists["\(prefix).m3u8"] = remuxed.playlist(prefix: prefix)
                    // A muxed file's codec string names both tracks: leave CODECS out then.
                    let entry = CachedHLS.MasterEntry(playlistName: "\(prefix).m3u8",
                                                      codec: specs.count == 1 ? "" : spec.codec,
                                                      bandwidth: spec.bandwidth, width: track.width, height: track.height)
                    if isAudio { audio = entry } else { video = entry }
                    duration = duration ?? remuxed.duration
                }
            }
        }
        if servedAsHLS, let video {
            let legible = LocalSubtitle.add(subtitles, duration: duration ?? 0, to: &presentation)
            let separateAudio = specs.count > 1 ? specs[1].rendition : nil
            presentation.playlists["master.m3u8"] = CachedHLS.masterPlaylist(
                video: video, audio: audio, audioRendition: separateAudio, subtitles: legible
            )
            let base = try await register(presentation)
            Logger.mediaCache.info("vod_presentation kind=hls tracks=\(specs.count) remuxed=\(presentation.remuxed.count)")
            return try LocalPlayback(video: base.appendingPathComponent("master.m3u8"), servedBy: .mediaCache)
        }
        presentation = LocalMediaServer.Presentation()
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
                      transport: (any MediaTransport)? = nil,
                      subtitles: [LocalSubtitle] = [],
                      info: DownloadInfo? = nil)
        async throws -> (VODSession, LocalPlayback) {
        let session = VODSession(server: server, downloads: downloads)
        await session.setInfo(info)
        let transport = if let transport { transport } else { await downloads.currentTransport }
        do {
            return (session, try await session.beginHLS(spec, transport: transport, subtitles: subtitles))
        } catch {
            await session.stop()
            throw error
        }
    }

    /// The movie of a progressive MP4 or QuickTime file, read from the cache
    /// (its `moov` may come last: that is fetched first), or nil when the file
    /// cannot be remuxed and is served whole.
    private static func remuxableMovie(_ downloader: TrackDownloader) async throws -> ProgressiveMP4.Movie? {
        let read: (Range<Int64>) async throws -> Data = { range in
            try await downloader.waitUntilAvailable(range)
            guard let data = try await downloader.read(range) else { throw ProgressiveMP4.Failure.malformed("cache lost bytes") }
            return data
        }
        do {
            let total = try await downloader.totalBytesWhenKnown()
            let moov = try await ProgressiveMP4.locateMovie(total: total, read: read)
            let movie = try ProgressiveMP4.parseMovie([UInt8](try await read(moov)))
            return movie.track(.video) != nil || movie.track(.audio) != nil ? movie : nil
        } catch let failure as ProgressiveMP4.Failure {
            Logger.mediaCache.info("remux_unavailable reason=\(String(describing: failure), privacy: .public)")
            return nil
        }
    }

    /// The chosen renditions' media playlists.
    private struct Selection: Sendable {
        var master: HLSPlaylist.Master?
        var variant: HLSPlaylist.Variant?
        var video: HLSPlaylist.Media
        var audio: HLSPlaylist.Media?
        var audioRendition: HLSPlaylist.Rendition?
        /// The variant's subtitle renditions with their media playlists, and its closed captions.
        var subtitles: [(HLSPlaylist.Rendition, HLSPlaylist.Media)] = []
        var closedCaptions: [HLSPlaylist.Rendition] = []
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
        // Subtitles are optional: one that cannot be read is left out, never failing playback.
        var subtitles: [(HLSPlaylist.Rendition, HLSPlaylist.Media)] = []
        if let group = HLSPlaylist.attribute("SUBTITLES", in: variant.attributes) {
            for subtitle in master.subtitles where subtitle.groupID == group {
                guard let uri = subtitle.uri,
                      let text = try? await fetchText(uri, signer: signer, transport: transport, attempts: 3),
                      let media = try? HLSPlaylist.parseMedia(text.text, base: text.url) else { continue }
                subtitles.append((subtitle, media))
            }
        }
        let captionGroup = HLSPlaylist.attribute("CLOSED-CAPTIONS", in: variant.attributes)
        return Selection(master: master, variant: variant, video: video, audio: audio, audioRendition: rendition,
                         subtitles: subtitles, closedCaptions: master.closedCaptions.filter { $0.groupID == captionGroup })
    }

    private func beginHLS(_ spec: HLSPresentationSpec, transport: any MediaTransport,
                          subtitles plugin: [LocalSubtitle] = []) async throws -> LocalPlayback {
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
        // The source's own subtitles, downloaded like every other rendition.
        var legible: [(HLSPlaylist.Rendition, String)] = []
        for (index, (rendition, media)) in selection.subtitles.enumerated() {
            let prefix = "t\(index)"
            let identity = "\(spec.identity)|hls|subtitles|\(rendition.groupID)-\(rendition.language ?? "")-\(rendition.name)"
            let cache = downloads.cache
            let scheduler = downloads.scheduler
            let downloader = await downloads.hold(rendition: identity) {
                HLSRenditionDownloader(role: .subtitles, cache: cache, identity: identity, media: media,
                                       signer: spec.signer, refresh: nil, transport: transport, scheduler: scheduler)
            }
            heldRenditions.append(identity)
            presentation.playlists["\(prefix).m3u8"] = HLSPlaylist.localMedia(media) { "\(prefix)/\($0)" }
            for resource in media.resources.indices {
                presentation.objects["\(prefix)/\(resource)"] = .init(
                    downloader: downloader, index: resource, contentType: await downloader.contentType(of: resource)
                )
            }
            var local = rendition
            local.groupID = LocalSubtitle.groupID
            legible.append((local, "\(prefix).m3u8"))
        }
        // The plugin's subtitles (WebVTT it provides apart from the stream).
        legible += LocalSubtitle.add(plugin, duration: selection.video.duration, to: &presentation)
        let entry: String
        // A single media playlist gets a master of its own when there are subtitles to offer.
        let single = legible.isEmpty ? nil
            : HLSPlaylist.Variant(uri: spec.url, bandwidth: 1, width: 0, height: 0, codecs: "", audioGroup: nil, attributes: "")
        if let variant = selection.variant ?? single {
            presentation.playlists["master.m3u8"] = HLSPlaylist.localMaster(
                variant: variant, videoPlaylist: "v.m3u8",
                audio: selection.audio == nil ? nil : selection.audioRendition,
                audioPlaylist: selection.audio == nil ? nil : "a.m3u8",
                subtitles: legible, closedCaptions: selection.closedCaptions
            )
            entry = "master.m3u8"
        } else {
            entry = "v.m3u8"
        }
        let base = try await register(presentation)
        Logger.mediaCache.info("vod_presentation kind=hls renditions=\(renditions.count)")
        return try LocalPlayback(video: base.appendingPathComponent(entry), servedBy: .mediaCache)
    }

    // MARK: live

    /// Starts (or joins) recording a live HLS stream: the best variant at or
    /// under `maxHeight` and its audio rendition, each recorded into the
    /// cache and served as a growing local playlist (see `LiveHLSRecorder`).
    static func start(live spec: HLSPresentationSpec, downloads: MediaDownloads, server: LocalMediaServer,
                      transport: (any MediaTransport)? = nil,
                      info: DownloadInfo? = nil)
        async throws -> (VODSession, LocalPlayback) {
        let session = VODSession(server: server, downloads: downloads)
        await session.setInfo(info)
        let transport = if let transport { transport } else { await downloads.currentTransport }
        do {
            return (session, try await session.beginLive(spec, transport: transport))
        } catch {
            await session.stop()
            throw error
        }
    }

    /// The live playlists to record: the chosen variant and audio rendition.
    private struct LiveSelection: Sendable {
        var variant: HLSPlaylist.Variant?
        var videoURL: URL
        var audio: HLSPlaylist.Rendition?
        /// Closed captions carried in the video (kept: they cost nothing to record).
        var closedCaptions: [HLSPlaylist.Rendition] = []
        /// The variant's subtitle renditions, recorded like the rest.
        var subtitles: [HLSPlaylist.Rendition] = []
    }

    private static func selectLive(_ spec: HLSPresentationSpec, signer: UpstreamURLSigner,
                                   transport: any MediaTransport) async throws -> LiveSelection {
        let top = try await fetchText(spec.url, signer: signer, transport: transport)
        guard HLSPlaylist.isMaster(top.text) else { return LiveSelection(variant: nil, videoURL: top.url, audio: nil) }
        let master = try HLSPlaylist.parseMaster(top.text, base: top.url)
        guard let variant = HLSPlaylist.bestVariant(master.variants, maxHeight: spec.maxHeight) else {
            throw HLSPlaylist.Failure.notAPlaylist
        }
        let captionGroup = HLSPlaylist.attribute("CLOSED-CAPTIONS", in: variant.attributes)
        return LiveSelection(variant: variant, videoURL: variant.uri,
                             audio: HLSPlaylist.bestAudio(master.audio, group: variant.audioGroup, language: spec.language),
                             closedCaptions: master.closedCaptions.filter { $0.groupID == captionGroup },
                             subtitles: master.subtitles.filter {
                                 $0.uri != nil && $0.groupID == HLSPlaylist.attribute("SUBTITLES", in: variant.attributes)
                             })
    }

    private func beginLive(_ spec: HLSPresentationSpec, transport: any MediaTransport) async throws -> LocalPlayback {
        let selection = try await Self.selectLive(spec, signer: spec.signer, transport: transport)
        let variantKey = selection.variant.map { "\($0.height)p-\($0.bandwidth)" } ?? "single"
        var renditions: [(MediaTrackRole, String, URL, String)] = [
            (selection.audio?.uri == nil ? .muxed : .video, "v", selection.videoURL, "\(spec.identity)|live|video|\(variantKey)"),
        ]
        if let audio = selection.audio, let uri = audio.uri {
            renditions.append((.audio, "a", uri, "\(spec.identity)|live|audio|\(audio.groupID)-\(audio.language ?? "")"))
        }
        var presentation = LocalMediaServer.Presentation()
        for (role, prefix, url, identity) in renditions {
            let cache = downloads.cache
            let scheduler = downloads.scheduler
            let refresh: (@Sendable () async throws -> (UpstreamURLSigner, URL))? = spec.refresh.map { refresh in
                { @Sendable in
                    let (signer, masterURL) = try await refresh()
                    var current = spec
                    current.url = masterURL
                    let fresh = try await Self.selectLive(current, signer: signer, transport: transport)
                    let next: URL? = role == .audio ? fresh.audio?.uri : fresh.videoURL
                    guard let url = next else { throw HLSPlaylist.Failure.notAPlaylist }
                    return (signer, url)
                }
            }
            let recorder = await downloads.hold(recording: identity) {
                LiveHLSRecorder(role: role, cache: cache, identity: identity, playlistURL: url, signer: spec.signer,
                                refresh: refresh, transport: transport, scheduler: scheduler)
            }
            heldRecordings.append(identity)
            order.append(role)
            await recorder.observe { [weak self] state in
                Task { await self?.update(role, state) }
            }
            try await recorder.waitForFirstPoll()
            presentation.live[prefix] = recorder
        }
        // Subtitles are recorded too, as their own growing playlists.
        var legible: [(HLSPlaylist.Rendition, String)] = []
        for (index, subtitle) in selection.subtitles.enumerated() {
            guard let url = subtitle.uri else { continue }
            let prefix = "t\(index)"
            let identity = "\(spec.identity)|live|subtitles|\(subtitle.groupID)-\(subtitle.language ?? "")-\(subtitle.name)"
            let cache = downloads.cache
            let scheduler = downloads.scheduler
            let recorder = await downloads.hold(recording: identity) {
                LiveHLSRecorder(role: .subtitles, cache: cache, identity: identity, playlistURL: url, signer: spec.signer,
                                refresh: nil, transport: transport, scheduler: scheduler)
            }
            heldRecordings.append(identity)
            // Not waited for: subtitles never hold up the start of a live stream.
            presentation.live[prefix] = recorder
            var local = subtitle
            local.groupID = LocalSubtitle.groupID
            legible.append((local, "\(prefix).m3u8"))
        }
        let entry: String
        if let variant = selection.variant {
            let audio = renditions.count > 1 ? selection.audio : nil
            presentation.playlists["master.m3u8"] = HLSPlaylist.localMaster(
                variant: variant, videoPlaylist: "v.m3u8", audio: audio, audioPlaylist: audio == nil ? nil : "a.m3u8",
                subtitles: legible, closedCaptions: selection.closedCaptions
            )
            entry = "master.m3u8"
        } else {
            entry = "v.m3u8"
        }
        let base = try await register(presentation)
        Logger.mediaCache.info("vod_presentation kind=live renditions=\(renditions.count)")
        return try LocalPlayback(video: base.appendingPathComponent(entry), servedBy: .mediaCache, isLive: true)
    }

    /// Fetches a playlist, retrying with backoff until it arrives or the
    /// caller is cancelled (or, given `attempts`, until that many failed: for
    /// optional playlists such as subtitles).
    private static func fetchText(_ url: URL, signer: UpstreamURLSigner, transport: any MediaTransport,
                                  attempts: Int? = nil) async throws -> (text: String, url: URL) {
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
                if let attempts, attempt >= attempts { throw error }
                // Never gives up while wanted: a slow or absent network is waiting, not failure.
                Logger.mediaCache.notice("playlist_retry attempt=\(attempt)")
                try await Task.sleep(for: .seconds(policy.delay(afterAttempt: attempt)))
            }
        }
    }

    // MARK: lifetime

    private func setInfo(_ info: DownloadInfo?) { self.info = info }

    private func register(_ presentation: LocalMediaServer.Presentation) async throws -> URL {
        if let info {
            await downloads.describe(info, tracks: heldTracks, renditions: heldRenditions, recordings: heldRecordings)
        }
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
        for identity in heldRecordings { await downloads.release(recording: identity) }
        heldRecordings.removeAll()
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
