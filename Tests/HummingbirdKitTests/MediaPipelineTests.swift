import Foundation
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
        return MediaCache(directory: directory)
    }

    private let fastRetry = TrackDownloader.Configuration(
        pieceBytes: 256 * 1_024, urgentPieceBytes: 64 * 1_024, headerProbeBytes: 4_096, concurrentPieces: 3,
        retry: DownloadRetryPolicy(initialDelay: 0.01, maximumDelay: 0.05, refusalsBeforeRefresh: 1)
    )

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

    /// Lint: on-demand media reaches the player only through `LocalPlayback`.
    func testPlayRequestsAreOnlyBuiltByLocalPlayback() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HummingbirdKit")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "LocalPlayback.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("PlayRequest(") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "Build play requests with LocalPlayback so on-demand media always comes from the media cache")
    }

    // MARK: downloader

    func testDownloaderFetchesWholeTrackThroughNetworkFailures() async throws {
        let file = FakeMedia.fragmentedMP4(segmentSizes: [300_000, 700_000, 1_200_000], segmentMilliseconds: 4_000)
        let upstream = FakeUpstream(file: file.data, failures: 4)
        let cache = temporaryCache()
        let track = try await cache.open(identity: "video")
        let downloader = TrackDownloader(role: .video, cache: cache, track: track,
                                         signer: .plain(try XCTUnwrap(URL(string: "https://media.test/v.mp4"))),
                                         transport: upstream, configuration: fastRetry)
        await downloader.start()
        guard case .indexed(let layout) = try await downloader.trackLayout() else { return XCTFail("expected an indexed layout") }
        XCTAssertEqual(layout.timeline.segments.count, 3)
        let all = 0..<Int64(file.data.count)
        try await downloader.waitUntilAvailable(all)
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
        try await resumed.waitUntilAvailable(all)
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
        try await downloader.waitUntilAvailable(0..<Int64(file.data.count))
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
        let layout = try await downloader.trackLayout()
        XCTAssertEqual(layout, .progressive)
        let total = await downloader.knownTotalBytes
        XCTAssertEqual(total, Int64(data.count), "learned from Content-Range")
        try await downloader.waitUntilAvailable(250_000..<300_000)
        let tail = try await downloader.read(250_000..<300_000)
        XCTAssertEqual(tail, data.subdata(in: 250_000..<300_000))
        await downloader.stop()
    }

    // MARK: session and loopback server

    func testSessionServesSeparateTracksAsOneLocalHLSPresentation() async throws {
        let video = FakeMedia.fragmentedMP4(segmentSizes: [200_000, 300_000], segmentMilliseconds: 5_000)
        let audio = FakeMedia.fragmentedMP4(segmentSizes: [20_000, 30_000], segmentMilliseconds: 5_000)
        let transport = FakeUpstream(files: ["/v": video.data, "/a": audio.data], failures: 2)
        let cache = temporaryCache()
        let server = LocalMediaServer()
        func spec(_ role: MediaTrackRole, _ path: String, codec: String) throws -> VODTrackSpec {
            VODTrackSpec(role: role, identity: "session-\(role.rawValue)",
                         signer: .plain(try XCTUnwrap(URL(string: "https://media.test" + path))),
                         refresh: nil, indexHint: nil, container: role == .audio ? "audio/mp4" : "video/mp4",
                         codec: codec, bandwidth: 1_000_000, width: 1280, height: 720, declaredDuration: 10)
        }
        let (session, playback) = try await VODSession.start(
            video: try spec(.video, "/v", codec: "avc1.64001f"), audio: try spec(.audio, "/a", codec: "mp4a.40.2"),
            cache: cache, server: server, transport: transport
        )
        XCTAssertEqual(playback.origin, .mediaCache)
        XCTAssertNil(playback.request.audio, "separate tracks are one HLS asset, not a composition")
        let master = playback.request.video.url
        XCTAssertEqual(master.host, "127.0.0.1")

        let (masterData, _) = try await URLSession.shared.data(from: master)
        let masterText = String(decoding: masterData, as: UTF8.self)
        XCTAssertTrue(masterText.contains("URI=\"audio.m3u8\""))
        let videoPlaylist = master.deletingLastPathComponent().appendingPathComponent("video.m3u8")
        let (playlistData, _) = try await URLSession.shared.data(from: videoPlaylist)
        XCTAssertTrue(String(decoding: playlistData, as: UTF8.self).contains("#EXT-X-BYTERANGE:200000@\(video.firstSegmentOffset)"))

        var ranged = URLRequest(url: master.deletingLastPathComponent().appendingPathComponent("video.mp4"))
        let start = Int(video.firstSegmentOffset) + 1_000
        ranged.setValue("bytes=\(start)-\(start + 99_999)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: ranged)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(bytes, video.data.subdata(in: start..<(start + 100_000)))

        await session.stop()
    }

    // MARK: selection (task 49)

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
        let at1080 = try XCTUnwrap(PlaybackSelector.best(options, maxHeight: 1080, preferAdaptive: true))
        XCTAssertEqual(at1080.video.url, "https://x/1080-60", "tallest allowed, then highest bitrate")
        XCTAssertEqual(at1080.audio?.url, "https://x/a128", "best audio, not the 48 kbps stream")
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 720, preferAdaptive: true)?.height, 720)
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 2160, preferAdaptive: true)?.height, 2160)
        XCTAssertEqual(PlaybackSelector.best(options, maxHeight: 240, preferAdaptive: true)?.height, 360)

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
            return (file, try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])))
        }
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
