import Foundation
import XCTest
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

    private func makeDownloads(file: Data, failures: Int = 0) -> (MediaDownloads, MediaCache) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hb-downloads-\(UUID().uuidString)")
        directories.append(directory)
        let cache = MediaCache(directory: directory)
        return (MediaDownloads(cache: cache, transport: SlowUpstream(file: file)), cache)
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

/// Serves byte ranges slowly enough that a download is still running while
/// the test acts on it.
private actor SlowUpstream: MediaTransport {
    private let file: Data
    init(file: Data) { self.file = file }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await Task.sleep(for: .milliseconds(20))
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
