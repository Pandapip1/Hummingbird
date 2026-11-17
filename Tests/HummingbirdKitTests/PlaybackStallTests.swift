import Foundation
import XCTest
import AdvancedVideoPlayerKit
@testable import HummingbirdKit

/// Playback that stops must show that it stopped (no optimistic "playing"),
/// and must recover: the system pausing the player, a clock that does not
/// advance, iOS reclaiming the loopback server's socket, and download pieces
/// starved behind other tracks.
@MainActor
final class PlaybackStallTests: XCTestCase {
    private func until(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testPausesTheSystemMakesReachTheUI() async {
        let backend = ActivityBackend()
        let model = makeTestPlayerModel(backend: backend)
        backend.report(.playing)
        XCTAssertTrue(model.isPlaying)
        // An interruption, a route change or a torn-down view pauses AVPlayer.
        backend.report(.paused)
        XCTAssertFalse(model.isPlaying, "the UI shows the pause the system made")
        backend.report(.waiting("Buffering"))
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(model.waitingReason, "Buffering", "waiting shows why")
        model.teardown()
    }

    func testPlayingWithoutAdvancingShowsStalledUntilTheClockMoves() async {
        let backend = ActivityBackend()
        let model = makeTestPlayerModel(backend: backend)
        backend.currentTime = 10
        backend.report(.playing)
        let stalled = await until { model.waitingReason == "Stalled" }
        XCTAssertTrue(stalled, "playing with a clock that does not move is shown as stalled")
        backend.currentTime = 11
        let cleared = await until { model.waitingReason == nil }
        XCTAssertTrue(cleared, "it clears as soon as playback advances")
        model.teardown()
    }

    func testTheLoopbackServerSurvivesASocketReclaimOnTheSamePort() async throws {
        let server = LocalMediaServer()
        var presentation = LocalMediaServer.Presentation()
        presentation.playlists["index.m3u8"] = "#EXTM3U\n"
        let (_, base) = try await server.register(presentation)
        let url = base.appendingPathComponent("index.m3u8")
        let session = URLSession(configuration: .ephemeral)
        let (before, _) = try await session.data(from: url)
        XCTAssertEqual(String(decoding: before, as: UTF8.self), "#EXTM3U\n")

        // iOS closes a suspended app's sockets.
        await server.simulateSocketReclaim()
        var after: Data?
        for _ in 0..<50 where after == nil {
            after = try? await session.data(from: url).0
            if after == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertEqual(after.map { String(decoding: $0, as: UTF8.self) }, "#EXTM3U\n",
                       "the same URL works again: the player's URLs stay valid")
        let restarts = await server.restarts
        XCTAssertEqual(restarts, 1)
    }

    func testAQueuedBackgroundPieceRunsAsSoonAsThePlayerNeedsItsTrack() async {
        let scheduler = DownloadScheduler(backgroundLimit: 2)
        // Another track keeps the scheduler busy in the foreground.
        await scheduler.admit(.foreground)
        let ticket = UUID()
        let queued = Task { await scheduler.admit(.background, ticket: ticket) }
        try? await Task.sleep(for: .milliseconds(100))
        await scheduler.promote([ticket])
        let admitted = await queued.value
        XCTAssertEqual(admitted, .foreground, "promoted, not starved behind the other track")

        // A promotion that arrives before the request reaches the queue still counts.
        let early = UUID()
        await scheduler.promote([early])
        let admittedEarly = await scheduler.admit(.background, ticket: early)
        XCTAssertEqual(admittedEarly, .foreground)
    }
}

@MainActor
private final class ActivityBackend: MediaBackend {
    var currentTime = 0.0
    var isPlaying: Bool { activity.wantsToPlay }
    private(set) var activity: PlaybackActivity = .paused
    var onActivityChange: (@MainActor (PlaybackActivity) -> Void)?
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    func report(_ activity: PlaybackActivity) {
        self.activity = activity
        onActivityChange?(activity)
    }

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {}
    func play() { report(.playing) }
    func pause() { report(.paused) }
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { report(.paused) }
}
