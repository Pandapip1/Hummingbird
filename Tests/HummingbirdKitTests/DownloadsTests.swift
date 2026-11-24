import Foundation
import PlatformSupport
import XCTest
import SwiftOpenUI
@testable import HummingbirdKit

/// The downloads list: one row per video across its tracks, real pause and
/// resume, stop (data kept), remove (data deleted, never while playing), and
/// Clear. The window model never shows an action as done before it is.
final class DownloadsTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func makeDownloads(file: Data, failures: Int = 0, delay: Duration = .milliseconds(20)) -> (MediaDownloads, MediaCache) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-downloads-\(UUID().uuidString)")
        directories.append(directory)
        let cache = MediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: directory))
        return (MediaDownloads(cache: cache, transport: SlowUpstream(file: file, delay: delay)), cache)
    }

    private func spec(_ identity: String) throws -> VODTrackSpec {
        VODTrackSpec(role: .muxed, identity: identity, signer: .plain(try XCTUnwrap(URL(string: "https://media.test/v"))),
                     refresh: nil, indexHint: nil, container: "video/mp4", codec: "", bandwidth: 1,
                     width: 0, height: 0, declaredDuration: nil)
    }

    private let info = DownloadInfo(id: "plugin|https://video.test/1", title: "A video", contentURL: "https://video.test/1",
                                    thumbnail: nil, isLive: false)

    func testListPausesResumesStopsAndRemovesAVideosDownloads() async throws {
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let (downloads, _) = makeDownloads(file: data)
        let downloader = try await downloads.hold(try spec("track-1"))
        await downloads.describe(info, tracks: ["track-1"])

        var rows = await downloads.snapshot()
        XCTAssertEqual(rows.count, 1, "one row per video")
        XCTAssertEqual(rows.first?.info.title, "A video")
        XCTAssertTrue(rows.first?.isPlaying == true)

        await downloads.setPaused(true, download: info.id)
        let paused = await downloader.isPaused
        XCTAssertTrue(paused)
        rows = await downloads.snapshot()
        XCTAssertEqual(rows.first?.state, .paused)
        await downloads.setPaused(false, download: info.id)
        rows = await downloads.snapshot()
        XCTAssertNotEqual(rows.first?.state, .paused)

        let removedWhilePlaying = await downloads.remove(download: info.id)
        XCTAssertFalse(removedWhilePlaying, "a playing video's download is not removed")

        await downloads.release(track: "track-1")
        await downloads.stop(download: info.id)
        rows = await downloads.snapshot()
        XCTAssertEqual(rows.first?.state, .stopped)

        let removed = await downloads.remove(download: info.id)
        XCTAssertTrue(removed)
        rows = await downloads.snapshot()
        XCTAssertTrue(rows.isEmpty)
    }

    func testFinishedDownloadsStayListedUntilCleared() async throws {
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        let (downloads, _) = makeDownloads(file: data)
        let downloader = try await downloads.hold(try spec("track-2"))
        await downloads.describe(info, tracks: ["track-2"])
        try await downloader.waitUntilAvailable(0..<Int64(data.count))
        var complete = false
        for _ in 0..<100 where !complete {
            complete = (await downloads.snapshot()).first?.state == .complete
            if !complete { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(complete, "recently finished downloads are listed")
        await downloads.release(track: "track-2")
        await downloads.clearFinished()
        let rows = await downloads.snapshot()
        XCTAssertTrue(rows.isEmpty, "Clear forgets finished rows")
    }

    func testClearingTheCacheKeepsWhatIsPlaying() async throws {
        let (_, cache) = makeDownloads(file: Data())
        let playing = try await cache.open(identity: "playing")
        try await cache.write(Data(repeating: 1, count: 4_096), at: 0, to: playing)
        let idle = try await cache.open(identity: "idle")
        try await cache.write(Data(repeating: 2, count: 8_192), at: 0, to: idle)
        await cache.close(idle)
        let before = await cache.usage()
        XCTAssertGreaterThan(before, 0)
        let freed = await cache.clearUnused()
        XCTAssertGreaterThan(freed, 0)
        let kept = try await cache.read(playing, range: 0..<4_096)
        XCTAssertEqual(kept, Data(repeating: 1, count: 4_096), "an open (playing) entry is never cleared")
        let reopened = try await cache.open(identity: "idle")
        let gone = try await cache.read(reopened, range: 0..<8_192)
        XCTAssertNil(gone, "the idle entry was removed")
    }

    func testDownloadsUseTheInstalledTransport() async throws {
        let data = Data((0..<100_000).map { UInt8($0 % 251) })
        let (downloads, _) = makeDownloads(file: Data())
        let installed = SlowUpstream(file: data)
        await downloads.useTransport(installed)
        let downloader = try await downloads.hold(try spec("track-4"))
        try await downloader.waitUntilAvailable(0..<Int64(data.count))
        let served = try await downloader.read(0..<Int64(data.count))
        XCTAssertEqual(served, data, "bytes came through the installed (background) transport")
        await downloads.stopAll()
    }

    @MainActor
    func testWindowModelShowsAPendingActionUntilItIsDone() async throws {
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })
        let (downloads, _) = makeDownloads(file: data)
        _ = try await downloads.hold(try spec("track-3"))
        await downloads.describe(info, tracks: ["track-3"])
        let model = DownloadsModel(downloads: downloads)
        await model.refresh()
        XCTAssertTrue(model.isVisible)
        let item = try XCTUnwrap(model.items.first)

        let pausing = Task { await model.setPaused(true, item) }
        await Task.yield()
        // Either still pending, or done and showing the real result: never a
        // paused row before the downloads have paused.
        if model.pending.contains(item.id) {
            XCTAssertNotEqual(model.items.first?.state, .paused)
        }
        await pausing.value
        XCTAssertFalse(model.pending.contains(item.id))
        XCTAssertEqual(model.items.first?.state, .paused)
        await downloads.stopAll()
    }
}

extension DownloadsTests {
    /// Saving energy (Low Power Mode, power-saver, hot device): downloads
    /// nobody watches pause where they are and continue from there; what is
    /// playing keeps downloading; "Download anyway" overrides; the policy
    /// follows the platform's conditions.
    func testSavingEnergyPausesUnwatchedDownloadsWithoutLosingBytes() async throws {
        let data = Data((0..<20_000_000).map { UInt8($0 % 251) })
        let (downloads, _) = makeDownloads(file: data, delay: .milliseconds(400))
        let background = try await downloads.hold(try spec("closed"))
        await downloads.describe(info, tracks: ["closed"])
        await downloads.release(track: "closed")  // its player closed
        let playing = try await downloads.hold(try spec("playing"))
        let watched = DownloadInfo(id: "plugin|https://video.test/2", title: "Watched", contentURL: "https://video.test/2",
                                   thumbnail: nil, isLive: false)
        await downloads.describe(watched, tracks: ["playing"])
        try await Task.sleep(for: .milliseconds(300))

        let policy = BackgroundWorkPolicy()
        await downloads.follow(policy)
        policy.update(defersNonUrgentWork: true)
        try await Task.sleep(for: .milliseconds(200))
        let pausedBackground = await background.isPaused
        let pausedPlaying = await playing.isPaused
        XCTAssertTrue(pausedBackground, "a closed video's download waits")
        XCTAssertFalse(pausedPlaying, "what is playing keeps downloading")
        var rows = await downloads.snapshot()
        XCTAssertEqual(rows.first { $0.id == info.id }?.state, .pausedSavingEnergy)
        let kept = await background.state.stage(.download).completed.byteCount
        try await Task.sleep(for: .milliseconds(300))
        let after = await background.state.stage(.download).completed.byteCount
        XCTAssertGreaterThanOrEqual(after, kept, "nothing downloaded is lost")

        // Download anyway.
        await downloads.downloadWhileSavingEnergy(info.id)
        let overridden = await background.isPaused
        XCTAssertFalse(overridden)
        rows = await downloads.snapshot()
        XCTAssertNotEqual(rows.first { $0.id == info.id }?.state, .pausedSavingEnergy)

        // It ends: everything continues.
        policy.update(defersNonUrgentWork: false)
        try await Task.sleep(for: .milliseconds(100))
        let resumed = await background.isPaused
        XCTAssertFalse(resumed)
        await downloads.stopAll()

        XCTAssertTrue(PowerConditions(lowPower: false, thermal: .critical).savesEnergy, "a critical thermal state saves energy too")
        XCTAssertTrue(PowerConditions(lowPower: true).savesEnergy)
        XCTAssertFalse(PowerConditions(lowPower: false, thermal: .fair).savesEnergy)
    }
}

/// Serves byte ranges slowly enough that a download is still running while
/// the test acts on it.
private actor SlowUpstream: MediaTransport {
    private let file: Data
    private let delay: Duration
    init(file: Data, delay: Duration = .milliseconds(20)) {
        self.file = file
        self.delay = delay
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(for: delay)
        let url = try XCTUnwrap(request.url)
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
