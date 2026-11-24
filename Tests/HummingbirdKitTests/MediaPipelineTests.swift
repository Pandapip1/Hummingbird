import Foundation
import PlatformSupport
import XCTest
@testable import HummingbirdKit

/// The download-first VOD pipeline: range bookkeeping, fragmented-MP4
/// indexing, the downloader (parallel ranges, retries, source refresh,
/// resume), the loopback server, and source selection. Everything runs
/// against an in-process fake upstream and a temporary cache directory.
final class MediaPipelineTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func temporaryCache() -> MediaCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-media-\(UUID().uuidString)")
        directories.append(directory)
        return MediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: directory))
    }

    private let fastRetry = TrackDownloader.Configuration(
        pieceBytes: 256 * 1_024, urgentPieceBytes: 64 * 1_024, headerProbeBytes: 4_096, concurrentPieces: 3,
        retry: DownloadRetryPolicy(initialDelay: 0.01, maximumDelay: 0.05, refusalsBeforeRefresh: 1)
    )

    private struct TimedOut: Error {}

    /// Every asynchronous step is bounded, so a hang fails the test instead of the run.
    private func bounded<T: Sendable>(_ seconds: Double = 20,
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TimedOut() }
            return result
        }
    }

    // MARK: ranges

    func testRangeSetMergesAndFindsGaps() {
        var set = MediaRangeSet()
        set.insert(10..<20)
        set.insert(30..<40)
        set.insert(20..<25)
        XCTAssertEqual(set.ranges, [10..<25, 30..<40])
        XCTAssertTrue(set.contains(12..<24))
        XCTAssertFalse(set.contains(20..<31))
        XCTAssertEqual(set.gaps(in: 0..<50), [0..<10, 25..<30, 40..<50])
        XCTAssertEqual(set.contiguousBytes(from: 15), 10)
        set.insert(0..<100)
        XCTAssertEqual(set.ranges, [0..<100])
        XCTAssertEqual(set.byteCount, 100)
    }

    // MARK: fragmented MP4

    func testFragmentedMP4IndexBecomesSegmentTimeline() throws {
        let file = FakeMedia.fragmentedMP4(segmentSizes: [1_000, 2_000, 3_000], segmentMilliseconds: 2_000)
        guard case .layout(let layout) = FragmentedMP4.probe(file.data) else { return XCTFail("expected an index") }
        XCTAssertEqual(layout.initialization, 0..<file.initializationEnd)
        XCTAssertEqual(layout.timeline.segments.count, 3)
        XCTAssertEqual(layout.timeline.segments[0].bytes, file.firstSegmentOffset..<(file.firstSegmentOffset + 1_000))
        XCTAssertEqual(layout.timeline.segments[2].start, 4, accuracy: 0.0001)
        XCTAssertEqual(layout.timeline.duration, 6, accuracy: 0.0001)
        XCTAssertEqual(layout.timeline.totalBytes, Int64(file.data.count))

        let truncated = file.data.prefix(Int(file.initializationEnd) + 10)
        guard case .needBytes(let upTo) = FragmentedMP4.probe(truncated) else { return XCTFail("expected a request for more bytes") }
        XCTAssertGreaterThan(upTo, Int64(truncated.count))
    }

    func testNonFragmentedMP4IsServedAsAFile() {
        let plain = FakeMedia.box("ftyp", Data("isom\0\0\0\0".utf8))
            + FakeMedia.box("moov", FakeMedia.box("mvhd", Data(count: 100)))
            + FakeMedia.box("mdat", Data(count: 64))
        XCTAssertEqual(FragmentedMP4.probe(plain), .notIndexed)
    }

    func testCachedHLSPlaylistsUseByteRanges() throws {
        let file = FakeMedia.fragmentedMP4(segmentSizes: [1_000, 2_000], segmentMilliseconds: 5_000)
        guard case .layout(let layout) = FragmentedMP4.probe(file.data) else { return XCTFail("expected an index") }
        let video = CachedHLS.Track(role: .video, layout: layout, fileName: "video.mp4", playlistName: "video.m3u8",
                                    codec: "avc1.640028", bandwidth: 4_000_000, width: 1920, height: 1080)
        let audio = CachedHLS.Track(role: .audio, layout: layout, fileName: "audio.mp4", playlistName: "audio.m3u8",
                                    codec: "mp4a.40.2", bandwidth: 128_000, width: 0, height: 0)
        let media = CachedHLS.mediaPlaylist(video)
        XCTAssertTrue(media.contains("#EXT-X-MAP:URI=\"video.mp4\",BYTERANGE=\"\(file.initializationEnd)@0\""))
        XCTAssertTrue(media.contains("#EXT-X-BYTERANGE:1000@\(file.firstSegmentOffset)"))
        XCTAssertTrue(media.contains("#EXT-X-TARGETDURATION:5"))
        XCTAssertTrue(media.hasSuffix("#EXT-X-ENDLIST\n"))
        let master = CachedHLS.masterPlaylist(video: video, audio: audio)
        XCTAssertTrue(master.contains("CODECS=\"avc1.640028,mp4a.40.2\""))
        XCTAssertTrue(master.contains("RESOLUTION=1920x1080"))
        XCTAssertTrue(master.contains("URI=\"audio.m3u8\""))
        var unknownCodec = audio
        unknownCodec.codec = ""
        XCTAssertFalse(CachedHLS.masterPlaylist(video: video, audio: unknownCodec).contains("CODECS="),
                       "a partial CODECS list would make AVFoundation reject the variant")
    }

    /// Regression: the seek bar showed ~1.5x a YouTube video's length on the
    /// old progressive composition. With the cache, the length is the sum of
    /// the segment index's durations, the playlist says exactly that, and the
    /// presentation's length is the shorter of the video and audio tracks.
    func testDurationIsTheSegmentIndexLength() throws {
        let video = FakeMedia.fragmentedMP4(segmentSizes: [1_000, 1_000, 1_000], segmentMilliseconds: 5_005)
        let audio = FakeMedia.fragmentedMP4(segmentSizes: [100, 100, 100], segmentMilliseconds: 5_000)
        guard case .layout(let videoLayout) = FragmentedMP4.probe(video.data),
              case .layout(let audioLayout) = FragmentedMP4.probe(audio.data) else { return XCTFail("expected indexes") }
        XCTAssertEqual(videoLayout.timeline.duration, 15.015, accuracy: 0.0001)

        let track = CachedHLS.Track(role: .video, layout: videoLayout, fileName: "video.mp4", playlistName: "video.m3u8",
                                    codec: "", bandwidth: 1, width: 0, height: 0)
        let playlistSeconds = CachedHLS.mediaPlaylist(track)
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") }
            .reduce(0, +)
        XCTAssertEqual(playlistSeconds, videoLayout.timeline.duration, accuracy: 0.0001)

        let snapshot = MediaPipelineSnapshot(tracks: [
            MediaTrackPipelineState(role: .video, totalBytes: nil, timeline: videoLayout.timeline, declaredDuration: 99),
            MediaTrackPipelineState(role: .audio, totalBytes: nil, timeline: audioLayout.timeline, declaredDuration: 99),
        ])
        XCTAssertEqual(snapshot.mediaDuration ?? 0, 15, accuracy: 0.0001, "the shorter track, never the declared or estimated length")
        let unindexed = MediaPipelineSnapshot(tracks: [
            MediaTrackPipelineState(role: .muxed, totalBytes: 10, timeline: nil, declaredDuration: 99),
        ])
        XCTAssertNil(unindexed.mediaDuration)
    }

    // MARK: protocol details

    func testRangeAndContentRangeParsing() {
        XCTAssertEqual(LocalMediaServer.parseRange("bytes=0-99", total: 1_000), 0..<100)
        XCTAssertEqual(LocalMediaServer.parseRange("bytes=900-", total: 1_000), 900..<1_000)
        XCTAssertEqual(LocalMediaServer.parseRange("bytes=-100", total: 1_000), 900..<1_000)
        XCTAssertEqual(LocalMediaServer.parseRange("bytes=500-5000", total: 1_000), 500..<1_000)
        XCTAssertNil(LocalMediaServer.parseRange("bytes=1000-", total: 1_000))
        XCTAssertNil(LocalMediaServer.parseRange("bytes=0-1,5-6", total: 1_000))
        let parsed = TrackDownloader.parseContentRange("bytes 100-199/5000")
        XCTAssertEqual(parsed?.start, 100)
        XCTAssertEqual(parsed?.end, 199)
        XCTAssertEqual(parsed?.total, 5_000)
        XCTAssertNil(TrackDownloader.parseContentRange("bytes 0-1/*")?.total)
    }

    func testRetryPolicyBacksOffAndRefreshesRefusedURLs() {
        let policy = DownloadRetryPolicy()
        XCTAssertEqual(policy.delay(afterAttempt: 1), 0.5)
        XCTAssertEqual(policy.delay(afterAttempt: 3), 2)
        XCTAssertEqual(policy.delay(afterAttempt: 30), 30, "capped, never giving up")
        XCTAssertEqual(DownloadRetryPolicy.classify(status: 403), .refresh)
        XCTAssertEqual(DownloadRetryPolicy.classify(status: 410), .refresh)
        XCTAssertEqual(DownloadRetryPolicy.classify(status: 503), .retry)
        XCTAssertEqual(DownloadRetryPolicy.classify(status: 429), .retry)
    }

    func testOnDemandPlaybackMustBeLocal() throws {
        XCTAssertThrowsError(try LocalPlayback(video: try XCTUnwrap(URL(string: "https://rr1.googlevideo.com/videoplayback")),
                                               servedBy: .mediaCache))
        let local = try LocalPlayback(video: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/x/master.m3u8")),
                                      servedBy: .mediaCache)
        XCTAssertEqual(local.origin, .mediaCache)
        XCTAssertFalse(local.request.isLive)
    }

    // MARK: downloader

    /// A file with boxes after its last indexed segment (an `mfra`): its index
    /// is shorter than the file. That is the same file, so nothing is reset
    /// and nothing is downloaded twice.
    func testATrackWithDataAfterItsIndexIsNotDownloadedTwice() async throws {
        var file = FakeMedia.fragmentedMP4(segmentSizes: [300_000, 700_000], segmentMilliseconds: 4_000)
        let indexedBytes = Int64(file.data.count)
        file.data.append(FakeMedia.box("mfra", Data(count: 200)))
        let upstream = FakeUpstream(file: file.data, failures: 0)
        let cache = temporaryCache()
        let track = try await cache.open(identity: "trailing")
        let downloader = TrackDownloader(role: .video, cache: cache, track: track,
                                         signer: .plain(try XCTUnwrap(URL(string: "https://media.test/t.mp4"))),
                                         transport: upstream, configuration: fastRetry)
        await downloader.start()
        let layout = try await bounded { try await downloader.trackLayout() }
        guard case .indexed = layout else {
            return XCTFail("expected an indexed layout")
        }
        try await bounded { try await downloader.waitUntilAvailable(0..<indexedBytes) }
        let served = await upstream.bytesServed
        XCTAssertLessThan(served, Int64(file.data.count) + fastRetry.headerProbeBytes / 2,
                          "the header was not downloaded again after a reset (served \(served) of \(file.data.count))")
        await downloader.stop()
    }

    func testDownloaderFetchesWholeTrackThroughNetworkFailures() async throws {
        let file = FakeMedia.fragmentedMP4(segmentSizes: [300_000, 700_000, 1_200_000], segmentMilliseconds: 4_000)
        let upstream = FakeUpstream(file: file.data, failures: 4)
        let cache = temporaryCache()
        let track = try await cache.open(identity: "video")
        let downloader = TrackDownloader(role: .video, cache: cache, track: track,
                                         signer: .plain(try XCTUnwrap(URL(string: "https://media.test/v.mp4"))),
                                         transport: upstream, configuration: fastRetry)
        await downloader.start()
        let firstLayout = try await bounded { try await downloader.trackLayout() }
        guard case .indexed(let layout) = firstLayout else { return XCTFail("expected an indexed layout") }
        XCTAssertEqual(layout.timeline.segments.count, 3)
        let all = 0..<Int64(file.data.count)
        try await bounded { try await downloader.waitUntilAvailable(all) }
        let cached = try await downloader.read(all)
        XCTAssertEqual(cached, file.data)
        let state = await downloader.state
        XCTAssertEqual(state.timeRanges(for: .download).first?.upperBound ?? 0, 12, accuracy: 0.001)
        let requests = await upstream.requestCount
        XCTAssertGreaterThan(requests, 4, "pieces are fetched as separate ranges")
        await downloader.stop()

        // A second session for the same track makes no upstream requests.
        let offline = FakeUpstream(file: file.data, failures: .max)
        let reopened = try await cache.open(identity: "video")
        let resumed = TrackDownloader(role: .video, cache: cache, track: reopened,
                                      signer: .plain(try XCTUnwrap(URL(string: "https://media.test/v.mp4"))),
                                      transport: offline, configuration: fastRetry)
        await resumed.start()
        try await bounded { try await resumed.waitUntilAvailable(all) }
        let offlineRequests = await offline.requestCount
        XCTAssertEqual(offlineRequests, 0)
        await resumed.stop()
    }

    func testDownloaderRefreshesAnExpiredSource() async throws {
        let file = FakeMedia.fragmentedMP4(segmentSizes: [100_000, 100_000], segmentMilliseconds: 2_000)
        let upstream = FakeUpstream(file: file.data, failures: 0, refusedPath: "/expired")
        let refreshes = Counter()
        let cache = temporaryCache()
        let track = try await cache.open(identity: "audio")
        let fresh = try XCTUnwrap(URL(string: "https://media.test/fresh"))
        let downloader = TrackDownloader(
            role: .audio, cache: cache, track: track,
            signer: .plain(try XCTUnwrap(URL(string: "https://media.test/expired"))),
            refreshSigner: {
                await refreshes.increment()
                return .plain(fresh)
            },
            transport: upstream, configuration: fastRetry
        )
        await downloader.start()
        try await bounded { try await downloader.waitUntilAvailable(0..<Int64(file.data.count)) }
        let count = await refreshes.value
        XCTAssertEqual(count, 1)
        await downloader.stop()
    }

    func testDownloaderServesFilesWithoutAnIndex() async throws {
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        let upstream = FakeUpstream(file: data, failures: 1)
        let cache = temporaryCache()
        let track = try await cache.open(identity: "plain")
        let downloader = TrackDownloader(role: .muxed, cache: cache, track: track,
                                         signer: .plain(try XCTUnwrap(URL(string: "https://media.test/plain.mp4"))),
                                         transport: upstream, configuration: fastRetry)
        await downloader.start()
        let layout = try await bounded { try await downloader.trackLayout() }
        XCTAssertEqual(layout, .progressive)
        let total = await downloader.knownTotalBytes
        XCTAssertEqual(total, Int64(data.count), "learned from Content-Range")
        try await bounded { try await downloader.waitUntilAvailable(250_000..<300_000) }
        let tail = try await downloader.read(250_000..<300_000)
        XCTAssertEqual(tail, data.subdata(in: 250_000..<300_000))
        await downloader.stop()
    }

    /// Subtitles, closed captions and audio descriptions survive into the local
    /// master with their accessibility attributes, so the platform player
    /// offers, styles and selects them.
    func testAccessibilityRenditionsRoundTripThroughTheLocalMaster() throws {
        let source = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English AD",LANGUAGE="en",AUTOSELECT=YES,CHARACTERISTICS="public.accessibility.describes-video",URI="ad.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English SDH",LANGUAGE="en",AUTOSELECT=YES,FORCED=NO,CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound",URI="en.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Forced",LANGUAGE="de",FORCED=YES,URI="forced.m3u8"
        #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="CC1",LANGUAGE="en",INSTREAM-ID="CC1"
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud",SUBTITLES="subs",CLOSED-CAPTIONS="cc"
        v720.m3u8
        """
        let base = try XCTUnwrap(URL(string: "https://media.test/hls/master.m3u8"))
        let master = try HLSPlaylist.parseMaster(source, base: base)
        XCTAssertEqual(master.subtitles.count, 2)
        XCTAssertEqual(master.closedCaptions.first?.instreamID, "CC1")
        let description = try XCTUnwrap(master.audio.first)
        XCTAssertTrue(description.describesVideo)

        let local = HLSPlaylist.localMaster(
            variant: try XCTUnwrap(master.variants.first), videoPlaylist: "video.m3u8",
            audio: description, audioPlaylist: "audio.m3u8",
            subtitles: master.subtitles.enumerated().map { ($0.element, "subs-\($0.offset).m3u8") },
            closedCaptions: master.closedCaptions
        )
        let again = try HLSPlaylist.parseMaster(local, base: base)
        XCTAssertEqual(again.audio.first?.characteristics, description.characteristics)
        XCTAssertEqual(again.subtitles.map(\.characteristics), master.subtitles.map(\.characteristics))
        XCTAssertEqual(again.subtitles.map(\.forced), [false, true])
        XCTAssertEqual(again.subtitles.map(\.language), ["en", "de"])
        XCTAssertEqual(again.closedCaptions.first?.instreamID, "CC1")
        let variant = try XCTUnwrap(again.variants.first)
        XCTAssertTrue(variant.attributes.contains("SUBTITLES=\"subs\""))
        XCTAssertTrue(variant.attributes.contains("CLOSED-CAPTIONS=\"cc\""))
    }

    /// After sleep or suspension (requests failed while away, now in a long
    /// backoff), returning to the app retries at once.
    func testReturningFromSuspensionRetriesAtOnce() async throws {
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        let upstream = FakeUpstream(file: data, failures: 2)
        let cache = temporaryCache()
        let track = try await cache.open(identity: "suspended")
        var config = fastRetry
        config.retry = DownloadRetryPolicy(initialDelay: 60, maximumDelay: 60, refusalsBeforeRefresh: 2)
        let downloader = TrackDownloader(role: .muxed, cache: cache, track: track,
                                         signer: .plain(try XCTUnwrap(URL(string: "https://media.test/s.mp4"))),
                                         transport: upstream, configuration: config)
        await downloader.start()
        let started = ContinuousClock.now
        let retrying = Task {
            // The app becomes active (repeatedly, as each failed attempt backs off).
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(200))
                await downloader.retryNow()
            }
        }
        try await bounded(10) { try await downloader.waitUntilAvailable(0..<200_000) }
        retrying.cancel()
        XCTAssertLessThan(started.duration(to: .now), .seconds(10), "not the 60 s backoff")
        await downloader.stop()
    }

    /// Upstream problems are classified, counted and shown (Download
    /// health); a 429 is waited out; a URL about to expire is resolved again
    /// before it is refused.
    func testUpstreamIssuesAreClassifiedAndExpiringURLsRefreshedAhead() async throws {
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        let upstream = StatusUpstream(file: data, statuses: [429, 403])
        let cache = temporaryCache()
        let track = try await cache.open(identity: "health")
        let soon = Int(Date().timeIntervalSince1970) + 30
        let expiring = try XCTUnwrap(URL(string: "https://media.test/v.mp4?expire=\(soon)"))
        let fresh = try XCTUnwrap(URL(string: "https://media.test/v.mp4?expire=\(soon + 21_600)"))
        var config = fastRetry
        config.retry.refusalsBeforeRefresh = 1
        let downloader = TrackDownloader(role: .muxed, cache: cache, track: track, signer: .plain(expiring),
                                         refreshSigner: { .plain(fresh) },
                                         transport: upstream, configuration: config)
        await downloader.start()
        try await bounded { try await downloader.waitUntilAvailable(0..<300_000) }
        let state = await downloader.state
        let health = try XCTUnwrap(state.health)
        XCTAssertEqual(health.issueCounts[.rateLimited], 1)
        XCTAssertEqual(health.issueCounts[.forbidden], 1)
        XCTAssertGreaterThanOrEqual(health.issueCounts[.expired] ?? 0, 1, "the expiring URL was noticed")
        XCTAssertGreaterThanOrEqual(health.refreshes, 1, "and resolved again ahead of expiry")
        let urls = await upstream.urls
        XCTAssertTrue(urls.contains { $0.query?.contains("expire=\(soon + 21_600)") == true }, "later pieces use the fresh URL")
        await downloader.stop()

        XCTAssertEqual(PlayerModel.margin(ahead: 10, in: [0...30, 40...50]), 20)
        XCTAssertEqual(PlayerModel.margin(ahead: 35, in: [0...30, 40...50]), 0)
    }

    // MARK: session and loopback server

    /// Plugin subtitles are SUBTITLES renditions of the local presentation
    /// (the platform player styles, selects and shows them in Picture in
    /// Picture); a described audio track keeps its characteristics. The
    /// subtitle text is loaded only when the player asks for it, as WebVTT.
    func testPluginSubtitlesAreSubtitleRenditionsOfTheLocalPresentation() async throws {
        let video = FakeMedia.fragmentedMP4(segmentSizes: [200_000, 300_000], segmentMilliseconds: 5_000)
        let audio = FakeMedia.fragmentedMP4(segmentSizes: [20_000, 30_000], segmentMilliseconds: 5_000)
        let transport = FakeUpstream(files: ["/v": video.data, "/a": audio.data], failures: 0)
        let server = LocalMediaServer()
        let downloads = MediaDownloads(cache: temporaryCache(), transport: transport)
        func spec(_ role: MediaTrackRole, _ path: String, codec: String) throws -> VODTrackSpec {
            VODTrackSpec(role: role, identity: "subtitles-\(role.rawValue)",
                         signer: .plain(try XCTUnwrap(URL(string: "https://media.test" + path))),
                         refresh: nil, indexHint: nil, container: role == .audio ? "audio/mp4" : "video/mp4",
                         codec: codec, bandwidth: 1_000_000, width: 1280, height: 720, declaredDuration: 10)
        }
        let videoSpec = try spec(.video, "/v", codec: "avc1.64001f")
        var audioSpec = try spec(.audio, "/a", codec: "mp4a.40.2")
        audioSpec.rendition = HLSPlaylist.Rendition(groupID: "audio", name: "English · Audio Description", language: "en",
                                                    isDefault: true, uri: nil,
                                                    characteristics: "public.accessibility.describes-video")
        let describedAudio = audioSpec
        let loads = Counter()
        let subtitle = LocalSubtitle(name: "English", language: "en", characteristics: nil) {
            await loads.increment()
            return LocalSubtitle.webVTT(from: "1\n00:00:01,000 --> 00:00:02,500\nHello\n")
        }
        let (session, playback) = try await bounded {
            try await VODSession.start(video: videoSpec, audio: describedAudio, subtitles: [subtitle],
                                       downloads: downloads, server: server)
        }
        let loadsBefore = await loads.value
        XCTAssertEqual(loadsBefore, 0, "nothing is fetched until the player asks")
        let master = playback.request.video.url
        let masterText = String(decoding: try await bounded { try await URLSession.shared.data(from: master) }.0, as: UTF8.self)
        XCTAssertTrue(masterText.contains("TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"English\",LANGUAGE=\"en\""))
        XCTAssertTrue(masterText.contains("AUTOSELECT=YES"))
        XCTAssertTrue(masterText.contains("SUBTITLES=\"subs\""))
        XCTAssertTrue(masterText.contains("CHARACTERISTICS=\"public.accessibility.describes-video\""))
        let parsed = try HLSPlaylist.parseMaster(masterText, base: master)
        XCTAssertEqual(parsed.subtitles.count, 1)
        XCTAssertTrue(try XCTUnwrap(parsed.audio.first).describesVideo)

        let base = master.deletingLastPathComponent()
        let playlist = String(decoding: try await bounded { try await URLSession.shared.data(from: base.appendingPathComponent("s0.m3u8")) }.0,
                              as: UTF8.self)
        XCTAssertTrue(playlist.contains("#EXTINF:10.000000,\ns0.vtt"))
        let (vtt, response) = try await bounded { try await URLSession.shared.data(from: base.appendingPathComponent("s0.vtt")) }
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/vtt")
        XCTAssertEqual(String(decoding: vtt, as: UTF8.self), "WEBVTT\n\n00:00:01.000 --> 00:00:02.500\nHello\n\n")
        _ = try await bounded { try await URLSession.shared.data(from: base.appendingPathComponent("s0.vtt")) }
        let loadsAfter = await loads.value
        XCTAssertEqual(loadsAfter, 1, "loaded once")
        await session.stop()
    }

    /// Generated (DASH) media keeps the audio track's language and marks an
    /// audio description as one in the local master.
    func testGeneratedMediaKeepsAudioLanguageAndDescriptions() throws {
        let mpd = """
        <MPD><Period>
          <AdaptationSet contentType="video"><Representation codecs="avc1.64001f" bandwidth="1000000" width="1280" height="720">
            <SegmentTemplate timescale="1000" initialization="https://grayjay.internal/video/i.mp4" media="https://grayjay.internal/video/s.mp4?n=$Number$">
              <SegmentTimeline><S d="2000" r="1"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>
          <AdaptationSet contentType="audio" lang="de"><Role schemeIdUri="urn:mpeg:dash:role:2011" value="description"/>
            <Representation codecs="mp4a.40.2" bandwidth="128000">
            <SegmentTemplate timescale="1000" initialization="https://grayjay.internal/audio/i.mp4" media="https://grayjay.internal/audio/s.mp4?n=$Number$">
              <SegmentTimeline><S d="2000" r="1"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet>
        </Period></MPD>
        """
        let playlists = try DashToHLS.convert(mpd, baseURL: "http://127.0.0.1:1234/p")
        XCTAssertTrue(playlists.master.contains("LANGUAGE=\"de\""))
        XCTAssertTrue(playlists.master.contains("CHARACTERISTICS=\"public.accessibility.describes-video\""))
        XCTAssertEqual(playlists.duration, 4, accuracy: 0.001)
    }

    func testSessionServesSeparateTracksAsOneLocalHLSPresentation() async throws {
        let video = FakeMedia.fragmentedMP4(segmentSizes: [200_000, 300_000], segmentMilliseconds: 5_000)
        let audio = FakeMedia.fragmentedMP4(segmentSizes: [20_000, 30_000], segmentMilliseconds: 5_000)
        let transport = FakeUpstream(files: ["/v": video.data, "/a": audio.data], failures: 2)
        let cache = temporaryCache()
        let server = LocalMediaServer()
        let downloads = MediaDownloads(cache: cache, transport: transport)
        func spec(_ role: MediaTrackRole, _ path: String, codec: String) throws -> VODTrackSpec {
            VODTrackSpec(role: role, identity: "session-\(role.rawValue)",
                         signer: .plain(try XCTUnwrap(URL(string: "https://media.test" + path))),
                         refresh: nil, indexHint: nil, container: role == .audio ? "audio/mp4" : "video/mp4",
                         codec: codec, bandwidth: 1_000_000, width: 1280, height: 720, declaredDuration: 10)
        }
        let videoSpec = try spec(.video, "/v", codec: "avc1.64001f")
        let audioSpec = try spec(.audio, "/a", codec: "mp4a.40.2")
        let (session, playback) = try await bounded {
            try await VODSession.start(video: videoSpec, audio: audioSpec, downloads: downloads, server: server)
        }
        XCTAssertEqual(playback.origin, .mediaCache)
        XCTAssertNil(playback.request.audio, "separate tracks are one HLS asset, not a composition")
        let master = playback.request.video.url
        XCTAssertEqual(master.host, "127.0.0.1")

        let (masterData, _) = try await bounded { try await URLSession.shared.data(from: master) }
        let masterText = String(decoding: masterData, as: UTF8.self)
        XCTAssertTrue(masterText.contains("URI=\"audio.m3u8\""))
        let videoPlaylist = master.deletingLastPathComponent().appendingPathComponent("video.m3u8")
        let (playlistData, _) = try await bounded { try await URLSession.shared.data(from: videoPlaylist) }
        XCTAssertTrue(String(decoding: playlistData, as: UTF8.self).contains("#EXT-X-BYTERANGE:200000@\(video.firstSegmentOffset)"))

        var ranged = URLRequest(url: master.deletingLastPathComponent().appendingPathComponent("video.mp4"))
        let start = Int(video.firstSegmentOffset) + 1_000
        ranged.setValue("bytes=\(start)-\(start + 99_999)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await bounded { [ranged] in try await URLSession.shared.data(for: ranged) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(bytes, video.data.subdata(in: start..<(start + 100_000)))

        await session.stop()
    }

    /// Switching YouTube-style streams (byte-range fMP4 video + a shared audio
    /// track) mid-playback: the new format gets its own local presentation,
    /// the shared audio download is kept (not restarted or stopped), the new
    /// presentation serves the segment at the current position, and the old
    /// format keeps downloading at low priority after the old session ends.
    func testSwitchingFormatsKeepsAudioAndTheOldTrackDownloading() async throws {
        let high = FakeMedia.fragmentedMP4(segmentSizes: Array(repeating: 300_000, count: 6), segmentMilliseconds: 5_000)
        let low = FakeMedia.fragmentedMP4(segmentSizes: Array(repeating: 100_000, count: 6), segmentMilliseconds: 5_000)
        let audio = FakeMedia.fragmentedMP4(segmentSizes: Array(repeating: 20_000, count: 6), segmentMilliseconds: 5_000)
        let transport = FakeUpstream(files: ["/1080": high.data, "/720": low.data, "/a": audio.data], failures: 0)
        let downloads = MediaDownloads(cache: temporaryCache(), transport: transport)
        let server = LocalMediaServer()
        func spec(_ role: MediaTrackRole, _ path: String) throws -> VODTrackSpec {
            VODTrackSpec(role: role, identity: "switch-\(path)",
                         signer: .plain(try XCTUnwrap(URL(string: "https://media.test" + path))),
                         refresh: nil, indexHint: nil, container: role == .audio ? "audio/mp4" : "video/mp4",
                         codec: role == .audio ? "mp4a.40.2" : "avc1.64001f", bandwidth: 1_000_000,
                         width: 1920, height: 1080, declaredDuration: 30)
        }
        let audioSpec = try spec(.audio, "/a")
        let highSpec = try spec(.video, "/1080")
        let lowSpec = try spec(.video, "/720")
        let (first, _) = try await bounded {
            try await VODSession.start(video: highSpec, audio: audioSpec, downloads: downloads, server: server)
        }
        // References to the downloads (a hold, released at once).
        let sharedAudio = try await downloads.hold(audioSpec)
        await downloads.release(track: audioSpec.identity)
        let oldVideo = try await downloads.hold(highSpec)
        await downloads.release(track: "switch-/1080")

        // Switch to 720p: a new session; then the old one ends.
        let (second, playback) = try await bounded {
            try await VODSession.start(video: lowSpec, audio: audioSpec, downloads: downloads, server: server)
        }
        await first.stop()
        let audioAfter = try await downloads.hold(audioSpec)
        await downloads.release(track: audioSpec.identity)
        XCTAssertTrue(audioAfter === sharedAudio, "the shared audio download continues, it is not restarted")
        let audioStopped = await sharedAudio.isStopped
        XCTAssertFalse(audioStopped)
        let oldPriority = await oldVideo.priority
        let oldStopped = await oldVideo.isStopped
        let oldFinished = await oldVideo.isFinished
        XCTAssertTrue(oldFinished || (oldPriority == .background && !oldStopped),
                      "the old format keeps downloading at low priority until it is complete")

        // The new presentation serves the segment at the current position (15 s: segment 3).
        let base = playback.request.video.url.deletingLastPathComponent()
        let (playlist, _) = try await bounded { try await URLSession.shared.data(from: base.appendingPathComponent("video.m3u8")) }
        let offset = Int(low.firstSegmentOffset) + 3 * 100_000
        XCTAssertTrue(String(decoding: playlist, as: UTF8.self).contains("#EXT-X-BYTERANGE:100000@\(offset)"))
        var ranged = URLRequest(url: base.appendingPathComponent("video.mp4"))
        ranged.setValue("bytes=\(offset)-\(offset + 99_999)", forHTTPHeaderField: "Range")
        let (bytes, _) = try await bounded { [ranged] in try await URLSession.shared.data(for: ranged) }
        XCTAssertEqual(bytes, low.data.subdata(in: offset..<(offset + 100_000)))
        await second.stop()
    }

    // MARK: HLS

    private static let hlsFiles: [String: Data] = [
        "/hls/master.m3u8": Data("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud"
        v360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud"
        v720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="vp09.00.40.08,mp4a.40.2",AUDIO="aud"
        v1080.m3u8
        """.utf8),
        "/hls/v720.m3u8": Data("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
        #EXTINF:4.000,
        s0.m4s
        #EXTINF:4.000,
        s1.m4s
        #EXTINF:4.000,
        s2.m4s
        #EXT-X-ENDLIST
        """.utf8),
        "/hls/audio.m3u8": Data("""
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.000,
        a0.m4s
        #EXTINF:6.000,
        a1.m4s
        #EXT-X-ENDLIST
        """.utf8),
        "/hls/init.mp4": Data(repeating: 1, count: 500),
        "/hls/key.bin": Data(repeating: 2, count: 16),
        "/hls/s0.m4s": Data(repeating: 3, count: 40_000),
        "/hls/s1.m4s": Data(repeating: 4, count: 40_000),
        "/hls/s2.m4s": Data(repeating: 5, count: 40_000),
        "/hls/a0.m4s": Data(repeating: 6, count: 8_000),
        "/hls/a1.m4s": Data(repeating: 7, count: 8_000),
    ]

    func testHLSPlaylistsParseSelectAndRewriteLocally() throws {
        let base = try XCTUnwrap(URL(string: "https://media.test/hls/master.m3u8"))
        let master = try HLSPlaylist.parseMaster(String(decoding: try XCTUnwrap(Self.hlsFiles["/hls/master.m3u8"]), as: UTF8.self), base: base)
        let variant = try XCTUnwrap(HLSPlaylist.bestVariant(master.variants, maxHeight: 1080))
        XCTAssertEqual(variant.height, 720, "the tallest variant the player can decode (VP9 is skipped)")
        XCTAssertEqual(HLSPlaylist.bestVariant(master.variants, maxHeight: 480)?.height, 360)
        let audio = try XCTUnwrap(HLSPlaylist.bestAudio(master.audio, group: variant.audioGroup, language: "en"))
        XCTAssertEqual(audio.uri?.absoluteString, "https://media.test/hls/audio.m3u8")

        let media = try HLSPlaylist.parseMedia(String(decoding: try XCTUnwrap(Self.hlsFiles["/hls/v720.m3u8"]), as: UTF8.self), base: variant.uri)
        XCTAssertFalse(media.isEndless)
        XCTAssertEqual(media.segments.count, 3)
        XCTAssertEqual(media.duration, 12, accuracy: 0.001)
        XCTAssertEqual(media.resources.map(\.kind), [.map, .key, .segment, .segment, .segment])
        let local = HLSPlaylist.localMedia(media) { "v/\($0)" }
        XCTAssertTrue(local.contains("#EXT-X-MAP:URI=\"v/0\""))
        XCTAssertTrue(local.contains("METHOD=AES-128,URI=\"v/1\",IV=0x00000000000000000000000000000001"))
        XCTAssertTrue(local.contains("\nv/4\n"))
        XCTAssertFalse(local.contains("https://"), "nothing in the local playlist points upstream")
        XCTAssertTrue(local.hasSuffix("#EXT-X-ENDLIST\n"))

        let live = try HLSPlaylist.parseMedia("#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\ns.ts\n", base: base)
        XCTAssertTrue(live.isEndless, "no ENDLIST: live")
        XCTAssertThrowsError(try HLSPlaylist.parseMedia("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://x\"\n#EXTINF:4,\ns.ts\n#EXT-X-ENDLIST\n", base: base))
    }

    func testHLSSessionDownloadsEverySegmentAndServesThemLocally() async throws {
        let transport = FakeUpstream(files: Self.hlsFiles, failures: 3)
        let cache = temporaryCache()
        let server = LocalMediaServer()
        let downloads = MediaDownloads(cache: cache, transport: transport)
        let spec = HLSPresentationSpec(identity: "hls-test", url: try XCTUnwrap(URL(string: "https://media.test/hls/master.m3u8")),
                                       signer: .plain(), refresh: nil, maxHeight: 1080, language: "en")
        let (session, playback) = try await bounded {
            try await VODSession.start(hls: spec, downloads: downloads, server: server, transport: transport)
        }
        let master = playback.request.video.url
        XCTAssertEqual(master.host, "127.0.0.1")
        let base = master.deletingLastPathComponent()
        let (masterData, _) = try await bounded { try await URLSession.shared.data(from: master) }
        let masterText = String(decoding: masterData, as: UTF8.self)
        XCTAssertTrue(masterText.contains("RESOLUTION=1280x720"))
        XCTAssertTrue(masterText.contains("URI=\"a.m3u8\""))
        XCTAssertFalse(masterText.contains("https://"))
        // Segment 2 of the video rendition is resource 4 (map, key, s0, s1, s2).
        let (segment, response) = try await bounded { try await URLSession.shared.data(from: base.appendingPathComponent("v/4")) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(segment, Self.hlsFiles["/hls/s2.m4s"])
        let (key, _) = try await bounded { try await URLSession.shared.data(from: base.appendingPathComponent("v/1")) }
        XCTAssertEqual(key, Self.hlsFiles["/hls/key.bin"])
        await session.stop()
        await downloads.stopAll()
    }

    // MARK: ownership and priority

    func testDownloadsContinueInTheBackgroundAfterThePlayerCloses() async throws {
        let file = FakeMedia.fragmentedMP4(segmentSizes: [400_000, 400_000, 400_000], segmentMilliseconds: 4_000)
        let upstream = FakeUpstream(file: file.data, failures: 0)
        let cache = temporaryCache()
        let downloads = MediaDownloads(cache: cache, transport: upstream)
        let spec = VODTrackSpec(role: .muxed, identity: "background", signer: .plain(try XCTUnwrap(URL(string: "https://media.test/v"))),
                                refresh: nil, indexHint: nil, container: "video/mp4", codec: "", bandwidth: 1,
                                width: 0, height: 0, declaredDuration: nil)
        let (session, _) = try await bounded {
            try await VODSession.start(video: spec, audio: nil, downloads: downloads, server: LocalMediaServer())
        }
        await session.stop() // the player closes at once
        let released = try await downloads.hold(spec)
        let priority = await released.priority
        XCTAssertEqual(priority, .foreground, "holding it again brings it back to the foreground")
        try await bounded { try await released.waitUntilAvailable(0..<Int64(file.data.count)) }
        await downloads.release(track: "background")
        await downloads.stopAll()
    }

    func testBackgroundDownloadsWaitWhileForegroundDownloadsRun() async throws {
        let scheduler = DownloadScheduler(backgroundLimit: 1)
        await scheduler.admit(.foreground)
        let background = Task { await scheduler.admit(.background) }
        try await Task.sleep(for: .milliseconds(50))
        var state = await scheduler.snapshot
        XCTAssertEqual(state.waiting, 1, "background waits while playback downloads")
        await scheduler.finish(.foreground)
        _ = await background.value
        state = await scheduler.snapshot
        XCTAssertEqual(state.background, 1)
        XCTAssertEqual(state.waiting, 0)
        await scheduler.finish(.background)
    }

    // MARK: selection (task 49)

    /// An audio description is its own choice (never merged into its
    /// language's main track), labelled as such, and chosen automatically only
    /// when the system setting asks for descriptions.
    func testAudioDescriptionsAreSeparateLabelledAndChosenOnlyWhenPreferred() throws {
        func audio(_ name: String, bitrate: Int) throws -> MediaSource {
            try JSONDecoder().decode(MediaSource.self, from: Data("""
            {"plugin_type":"AudioUrlSource","name":"\(name)","url":"https://a.test/\(bitrate)","container":"audio/mp4","language":"en","bitrate":\(bitrate)}
            """.utf8))
        }
        let main = try audio("English", bitrate: 128_000)
        let described = try audio("English (Audio Description)", bitrate: 160_000)
        XCTAssertTrue(described.describesVideo)
        XCTAssertFalse(main.describesVideo)
        let choices = PlaybackSelector.audioChoices([main, described])
        XCTAssertEqual(choices.count, 2, "not merged into the main English track")
        XCTAssertTrue(choices.contains { PlaybackSelector.audioLabel(for: $0).contains("Audio Description") })
        XCTAssertEqual(PlaybackSelector.bestAudio([main, described], language: "en")?.name, "English")
        XCTAssertEqual(PlaybackSelector.bestAudio([main, described], language: "en", prefersDescriptions: true)?.name,
                       "English (Audio Description)")
    }

    func testSelectionHonoursPreferredResolutionAndPicksBestAudio() throws {
        let details = try JSONDecoder().decode(VideoDetails.self, from: Data("""
        {"contentType":1,"name":"V","url":"u","id":{"pluginId":"p","value":"v"},"description":"",
         "video":{"isUnMuxed":true,
           "videoSources":[
             {"plugin_type":"VideoUrlRangeSource","url":"https://x/360","height":360,"width":640,"container":"video/mp4","codec":"avc1.4d401e","bitrate":400000,"itagId":134},
             {"plugin_type":"VideoUrlRangeSource","url":"https://x/1080-30","height":1080,"width":1920,"container":"video/mp4","codec":"avc1.640028","bitrate":2500000,"itagId":137},
             {"plugin_type":"VideoUrlRangeSource","url":"https://x/1080-60","height":1080,"width":1920,"container":"video/mp4","codec":"avc1.64002a","bitrate":4500000,"itagId":299},
             {"plugin_type":"VideoUrlRangeSource","url":"https://x/720","height":720,"width":1280,"container":"video/mp4","codec":"avc1.4d401f","bitrate":1500000,"itagId":136},
             {"plugin_type":"VideoUrlRangeSource","url":"https://x/2160","height":2160,"width":3840,"container":"video/mp4","codec":"avc1.640033","bitrate":12000000,"itagId":266}],
           "audioSources":[
             {"plugin_type":"AudioUrlRangeSource","url":"https://x/a48","container":"audio/mp4","codec":"mp4a.40.5","bitrate":48000,"itagId":139},
             {"plugin_type":"AudioUrlRangeSource","url":"https://x/a128","container":"audio/mp4","codec":"mp4a.40.2","bitrate":130000,"itagId":140,
              "initStart":0,"initEnd":631,"indexStart":632,"indexEnd":1123}]}}
        """.utf8))
        let options = PlaybackSelector.options(for: details, preferredLanguage: "en")
        let at1080 = try XCTUnwrap(PlaybackSelector.best(options, maxHeight: 1080))
        XCTAssertEqual(at1080.video.url, "https://x/1080-60", "tallest allowed, then highest bitrate")
        XCTAssertEqual(at1080.audio?.url, "https://x/a128", "best audio, not the 48 kbps stream")
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 720)?.height, 720)
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 2160)?.height, 2160)
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 240)?.height, 360)

        let audio = try XCTUnwrap(details.audioSources.last)
        XCTAssertEqual(audio.indexRange, 632...1123)
        XCTAssertEqual(audio.initRange, 0...631)
        XCTAssertEqual(audio.formatID, "140")
        var refreshed = audio
        refreshed.url = "https://x/a128-new"
        refreshed.name = "renamed"
        XCTAssertTrue(PlaybackSelector.isSameFileSource(refreshed, as: audio), "the format ID identifies the format")
        XCTAssertFalse(PlaybackSelector.isSameFileSource(details.audioSources[0], as: audio))
    }
}

// MARK: - Fakes

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// An upstream that serves byte ranges of in-memory files, failing the first
/// `failures` requests as a dropped network would and refusing one path as an
/// expired URL would.
private actor FakeUpstream: MediaTransport {
    private let files: [String: Data]
    private var failures: Int
    private let refusedPath: String?
    private(set) var requestCount = 0
    /// Body bytes returned, to tell when something is downloaded twice.
    private(set) var bytesServed: Int64 = 0

    init(file: Data, failures: Int, refusedPath: String? = nil) {
        files = ["*": file]
        self.failures = failures
        self.refusedPath = refusedPath
    }

    init(files: [String: Data], failures: Int, refusedPath: String? = nil) {
        self.files = files
        self.failures = failures
        self.refusedPath = refusedPath
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        let url = try XCTUnwrap(request.url)
        if failures > 0 {
            failures -= 1
            throw URLError(.networkConnectionLost)
        }
        if let refusedPath, url.path == refusedPath {
            return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])))
        }
        let file = try XCTUnwrap(files[url.path] ?? files["*"])
        let total = Int64(file.count)
        guard let header = request.value(forHTTPHeaderField: "Range"),
              let range = LocalMediaServer.parseRange(header, total: total) else {
            bytesServed += Int64(file.count)
            return (file, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])))
        }
        let body = file.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        bytesServed += Int64(body.count)
        let headers = ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"]
        return (body, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)))
    }
}

/// Serves a file, answering the first requests with the given statuses.
private actor StatusUpstream: MediaTransport {
    private let file: Data
    private var statuses: [Int]
    private(set) var urls: [URL] = []

    init(file: Data, statuses: [Int]) {
        self.file = file
        self.statuses = statuses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        urls.append(url)
        if !statuses.isEmpty {
            let status = statuses.removeFirst()
            let headers = status == 429 ? ["Retry-After": "0"] : [:]
            return (Data(), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)))
        }
        let total = Int64(file.count)
        let range = request.value(forHTTPHeaderField: "Range").flatMap { LocalMediaServer.parseRange($0, total: total) } ?? 0..<total
        let body = file.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        let headers = ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"]
        return (body, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)))
    }
}

/// Synthetic fragmented MP4 files (DASH on-demand layout).
private enum FakeMedia {
    struct File {
        var data: Data
        var initializationEnd: Int64
        var firstSegmentOffset: Int64
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var data = uint32(UInt32(8 + payload.count))
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func fragmentedMP4(segmentSizes: [Int], segmentMilliseconds: UInt32) -> File {
        let ftyp = box("ftyp", Data("iso6\0\0\0\0".utf8))
        let moov = box("moov", box("mvhd", Data(count: 100)) + box("mvex", box("trex", Data(count: 24))))
        var sidx = Data()
        sidx.append(uint32(0))            // version 0, flags
        sidx.append(uint32(1))            // reference_ID
        sidx.append(uint32(1_000))        // timescale
        sidx.append(uint32(0))            // earliest_presentation_time
        sidx.append(uint32(0))            // first_offset
        sidx.append(Data([0, 0]))         // reserved
        sidx.append(Data([UInt8(segmentSizes.count >> 8), UInt8(segmentSizes.count & 0xFF)]))
        for size in segmentSizes {
            sidx.append(uint32(UInt32(size)))
            sidx.append(uint32(segmentMilliseconds))
            sidx.append(uint32(0x9000_0000))
        }
        let header = ftyp + moov + box("sidx", sidx)
        var data = header
        for (index, size) in segmentSizes.enumerated() {
            data.append(Data((0..<size).map { UInt8(($0 + index * 7) % 253) }))
        }
        return File(data: data, initializationEnd: Int64(ftyp.count + moov.count), firstSegmentOffset: Int64(header.count))
    }
}

// MARK: - Live

/// A live stream whose 3-segment window slides on every playlist request,
/// with an ad-break discontinuity, ending after three polls.
private actor FakeLiveUpstream: MediaTransport {
    private var polls = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let ok = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]))
        guard url.path == "/live.m3u8" else {
            let sequence = Int(url.deletingPathExtension().lastPathComponent.dropFirst(3)) ?? 0
            return (Data(repeating: UInt8(sequence), count: 1_000 + sequence), ok)
        }
        let first = polls
        polls += 1
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:\(first)\n"
        for sequence in first..<(first + 3) {
            if sequence == 3 { text += "#EXT-X-DISCONTINUITY\n" }
            text += "#EXTINF:1.0,\nseg\(sequence).ts\n"
        }
        if polls >= 3 { text += "#EXT-X-ENDLIST\n" }
        return (Data(text.utf8), ok)
    }
}

final class LiveRecordingTests: XCTestCase {
    func testLiveRecordingKeepsEverySegmentPastUpstreamsWindowAndEndsWithTheStream() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: directory))
        let recorder = LiveHLSRecorder(role: .muxed, cache: cache, identity: "live-test",
                                       playlistURL: try XCTUnwrap(URL(string: "https://live.test/live.m3u8")),
                                       signer: .plain(), refresh: nil, transport: FakeLiveUpstream())
        await recorder.start()
        try await recorder.waitForFirstPoll()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var playlist = ""
        while ContinuousClock.now < deadline {
            playlist = await recorder.localPlaylist(prefix: "v")
            if playlist.contains("#EXT-X-ENDLIST") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"), "the recording ends with the stream")
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:0"), "it starts at the first segment seen, past upstream's window")
        for sequence in 0...4 { XCTAssertTrue(playlist.contains("v/s\(sequence)\n"), "segment \(sequence) is in the recording") }
        XCTAssertTrue(playlist.contains("#EXT-X-DISCONTINUITY\n"), "ad-break discontinuities are kept")
        XCTAssertFalse(playlist.contains("https://"))
        try await recorder.waitForResource("s4")
        let first = try await recorder.readResource("s0")
        XCTAssertEqual(first.count, 1_000)
        let state = await recorder.state
        XCTAssertEqual(state.timeline?.duration ?? 0, 5, accuracy: 0.001, "the seek bar spans the whole recording")
        await recorder.stop()
    }
}

/// A low-latency stream: one part of the segment being published per
/// playlist request, blocking reload supported (later requests are held as a
/// server holding a blocking reload would), ending on the third request.
private actor FakeLowLatencyUpstream: MediaTransport {
    private var polls = 0
    private(set) var playlistQueries: [String] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let ok = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]))
        guard url.path == "/ll.m3u8" else { return (Data(repeating: 9, count: 500), ok) }
        playlistQueries.append(url.query ?? "")
        let n = polls
        polls += 1
        if n > 0 { try await Task.sleep(for: .milliseconds(600)) }
        var text = "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-PART-INF:PART-TARGET=0.5\n#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for sequence in 0..<n {
            text += "#EXT-X-PART:DURATION=0.5,URI=\"s\(sequence)p0.mp4\",INDEPENDENT=YES\n#EXT-X-PART:DURATION=0.5,URI=\"s\(sequence)p1.mp4\"\n"
            text += "#EXTINF:1.0,\nseg\(sequence).mp4\n"
        }
        if n >= 2 {
            text += "#EXT-X-ENDLIST\n"
        } else {
            text += "#EXT-X-PART:DURATION=0.5,URI=\"s\(n)p0.mp4\",INDEPENDENT=YES\n"
        }
        return (Data(text.utf8), ok)
    }
}

final class LowLatencyRecordingTests: XCTestCase {
    func testLowLatencyStreamsAreRecordedPartByPartAndServedAsLowLatency() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-ll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = FakeLowLatencyUpstream()
        let recorder = LiveHLSRecorder(role: .muxed, cache: MediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: directory)), identity: "ll-test",
                                       playlistURL: try XCTUnwrap(URL(string: "https://live.test/ll.m3u8")),
                                       signer: .plain(), refresh: nil, transport: upstream)
        await recorder.start()
        try await recorder.waitForFirstPoll()
        let early = await recorder.localPlaylist(prefix: "v")
        XCTAssertTrue(early.contains("#EXT-X-PART-INF:PART-TARGET=0.500"))
        XCTAssertTrue(early.contains("CAN-BLOCK-RELOAD=YES"))
        XCTAssertTrue(early.contains("URI=\"v/p0.0\",INDEPENDENT=YES"), "the published part is served before its segment exists")
        XCTAssertTrue(early.contains("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"v/p0.1\""))
        try await recorder.waitForResource("p0.0")

        // A blocking reload for segment 0 returns once the stream has it.
        await recorder.waitForPlaylist(msn: 0, part: nil)
        let later = await recorder.localPlaylist(prefix: "v")
        XCTAssertTrue(later.contains("v/s0\n") || later.contains("#EXT-X-ENDLIST"))
        let queries = await upstream.playlistQueries
        XCTAssertTrue(queries.dropFirst().contains { $0.contains("_HLS_msn=") && $0.contains("_HLS_part=") },
                      "later reloads ask upstream to block until the next part")
        await recorder.stop()
    }
}
