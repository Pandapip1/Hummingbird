import Foundation
import PlatformSupport
import XCTest
@testable import HummingbirdKit

/// Optional transcoding (task 35): the originals are the stage's buffer and
/// are deleted only once the smaller output is stored; failures and outputs
/// that save nothing keep the original; nothing runs while it is off or while
/// conditions do not allow it, and open (playing) tracks are never consumed.
final class TranscodeStageTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hb-transcode-\(UUID().uuidString)")
        directories.append(url)
        return url
    }

    private let identity = "vod-v2|plugin|https://video.test/1|video|VideoUrlRangeSource|format|137|video/mp4|en"

    private func cacheWithCompleteVideo(bytes: Int = 100_000) async throws -> MediaCache {
        let cache = MediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: directory()))
        let track = try await cache.open(identity: identity)
        try await cache.write(Data(repeating: 7, count: bytes), at: 0, to: track)
        try await cache.setTotalBytes(track, Int64(bytes))
        await cache.close(track)
        return cache
    }

    private func encoder(outputBytes: Int, fails: Bool = false, allowed: Bool = true, calls: Calls) -> TranscodeEncoder {
        TranscodeEncoder(
            isAvailable: { true },
            conditionsAllow: { allowed },
            transcode: { _, destination in
                await calls.increment()
                if fails { throw URLError(.cannotDecodeContentData) }
                try Data(repeating: 1, count: outputBytes).write(to: destination)
            }
        )
    }

    func testTheOriginalIsDeletedOnlyOnceTheSmallerOutputIsStored() async throws {
        let cache = try await cacheWithCompleteVideo()
        let calls = Calls()
        let stage = TranscodeStage(cache: cache, scratch: directory(), encoder: encoder(outputBytes: 40_000, calls: calls))
        let disabledRun = await stage.runOnce()
        XCTAssertFalse(disabledRun, "off by default")

        await stage.setEnabled(true, background: false)
        let worked = await stage.runOnce()
        XCTAssertTrue(worked)
        let output = await cache.isComplete(identity: TranscodeStage.transcodedIdentity(identity))
        let original = await cache.isComplete(identity: identity)
        XCTAssertTrue(output, "the re-encoded copy is stored")
        XCTAssertFalse(original, "and then the original buffer is consumed")
        await stage.setEnabled(false)
    }

    func testFailuresAndOutputsThatSaveNothingKeepTheOriginal() async throws {
        for (fails, outputBytes) in [(true, 10), (false, 99_000)] {
            let cache = try await cacheWithCompleteVideo()
            let calls = Calls()
            let stage = TranscodeStage(cache: cache, scratch: directory(),
                                       encoder: encoder(outputBytes: outputBytes, fails: fails, calls: calls))
            await stage.setEnabled(true, background: false)
            _ = await stage.runOnce()
            let original = await cache.isComplete(identity: identity)
            let output = await cache.isComplete(identity: TranscodeStage.transcodedIdentity(identity))
            XCTAssertTrue(original, "nothing is lost")
            XCTAssertFalse(output)
            // It is not retried over and over.
            _ = await stage.runOnce()
            let count = await calls.value
            XCTAssertEqual(count, 1)
            await stage.setEnabled(false)
        }
    }

    func testNothingRunsWhenConditionsDoNotAllowOrTheTrackIsPlaying() async throws {
        let cache = try await cacheWithCompleteVideo()
        let calls = Calls()
        let blocked = TranscodeStage(cache: cache, scratch: directory(),
                                     encoder: encoder(outputBytes: 1_000, allowed: false, calls: calls))
        await blocked.setEnabled(true, background: false)
        let ran = await blocked.runOnce()
        XCTAssertFalse(ran, "not in Low Power Mode / hot / on battery")
        await blocked.setEnabled(false)

        let playing = try await cache.open(identity: identity)
        let stage = TranscodeStage(cache: cache, scratch: directory(), encoder: encoder(outputBytes: 1_000, calls: calls))
        await stage.setEnabled(true, background: false)
        let consumed = await stage.runOnce()
        XCTAssertFalse(consumed, "an open (playing) track is never consumed")
        await cache.close(playing)
        await stage.setEnabled(false)
        let count = await calls.value
        XCTAssertEqual(count, 0)
    }
}

private actor Calls {
    private(set) var value = 0
    func increment() { value += 1 }
}
