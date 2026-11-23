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

    /// After a surface handover the scene showed "loaded" although the clock
    /// advanced: the waiting reason was a stored copy that only an activity
    /// callback refreshed. It now follows the engine on every tick too.
    func testWaitingReasonFollowsTheEngineEvenWithoutACallback() {
        let backend = ActivityBackend()
        let model = makeTestPlayerModel(backend: backend)
        backend.report(.waiting("Buffering"))
        XCTAssertEqual(model.waitingReason, "Buffering")
        backend.changeSilently(.playing)
        backend.currentTime = 3
        backend.onTick?(3)
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.waitingReason, "a tick reconciles what the engine is doing")
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

        // iOS closes a suspended app's sockets (the listener and the open
        // connections; a fresh session makes a new connection).
        await server.simulateSocketReclaim()
        session.invalidateAndCancel()
        let fresh = URLSession(configuration: .ephemeral)
        var after: Data?
        for _ in 0..<50 where after == nil {
            after = try? await fresh.data(from: url).0
            if after == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertEqual(after.map { String(decoding: $0, as: UTF8.self) }, "#EXTM3U\n",
                       "the same URL works again: the player's URLs stay valid")
        let restarts = await server.restarts
        XCTAssertEqual(restarts, 1)
    }

    func testLeavingFullscreenNeitherPausesNorSeeksNorTouchesTheRate() {
        let backend = ActivityBackend()
        let model = makeTestPlayerModel(backend: backend)
        model.togglePlayback()
        XCTAssertEqual(backend.activity, .playing)
        backend.calls.removeAll()
        var seen: [PlaybackActivity] = []
        backend.onActivityChange = { seen.append($0) }

        model.fullscreenDidChange(true)
        model.restorePlaybackAfterSurfaceTransfer()
        model.fullscreenDidChange(false)
        model.restorePlaybackAfterSurfaceTransfer()

        XCTAssertEqual(backend.calls, [], "the same player moves between surfaces untouched: no play, rate change or seek")
        XCTAssertEqual(seen, [], "it never leaves playing")
        XCTAssertEqual(backend.activity, .playing)

        // Only if a surface did pause it is playback resumed, once.
        backend.report(.paused)
        model.restorePlaybackAfterSurfaceTransfer()
        XCTAssertEqual(backend.calls, ["play"])
        model.teardown()
    }

    /// Background -> active: a playing video keeps playing with no reload or
    /// seek; one the system paused while away resumes in place; one the user
    /// paused stays paused.
    func testReturningToTheAppKeepsPlaybackAsTheUserLeftIt() {
        let app = makeTestAppModel()
        let backend = ActivityBackend()
        app.makePlayer = { stores in PlayerModel(stores: stores, backend: backend) }
        let model = app.player(forTab: app.activeTabID)
        model.togglePlayback()
        backend.calls.removeAll()

        app.applicationBecameActive()
        XCTAssertEqual(backend.calls, [], "still playing: untouched (no reload, seek or rate change)")
        XCTAssertEqual(backend.activity, .playing)

        backend.report(.paused)  // the system paused it while away
        app.applicationBecameActive()
        XCTAssertEqual(backend.calls, ["play"], "resumed in place")
        XCTAssertTrue(model.isPlaying)

        model.togglePlayback()  // the user pauses
        backend.calls.removeAll()
        app.applicationBecameActive()
        XCTAssertEqual(backend.calls, [], "a video the user paused stays paused")
        XCTAssertFalse(model.isPlaying)
        app.closeWindow()
    }

    /// Calls, remote commands, unplugged headphones and the system's own
    /// controls go through the same intent as the app's: the UI state, the
    /// intent (what returning to the app resumes) and the engine agree.
    func testExternalEventsKeepStateIntentAndEngineInStep() {
        let backend = ActivityBackend()
        let model = makeTestPlayerModel(backend: backend)
        model.togglePlayback()
        XCTAssertTrue(model.isPlaying)

        // A call: the engine paused; the user still wants it playing.
        backend.report(.paused)
        backend.external(.interruptionBegan)
        XCTAssertFalse(model.isPlaying)
        XCTAssertTrue(model.isInterrupted)
        backend.calls.removeAll()
        model.applicationBecameActive()
        XCTAssertEqual(backend.calls, [], "returning to the app during a call does not resume")
        backend.calls.removeAll()
        // Hung up, the system says it may resume: it resumes.
        backend.external(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(backend.calls, ["play"])
        XCTAssertTrue(model.isPlaying)

        // Another interruption that ends without permission to resume: stays paused.
        backend.report(.paused)
        backend.external(.interruptionBegan)
        backend.external(.interruptionEnded(shouldResume: false))
        XCTAssertFalse(model.isPlaying)
        backend.calls.removeAll()
        model.applicationBecameActive()
        XCTAssertEqual(backend.calls, [], "the user's intent is now paused: returning does not resume")

        // The lock screen plays, then pauses.
        backend.external(.play)
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(backend.calls.last, "play")
        backend.external(.pause)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(backend.calls.last, "pause")
        backend.calls.removeAll()
        model.applicationBecameActive()
        XCTAssertEqual(backend.calls, [], "paused from the lock screen stays paused")

        // Headphones unplugged while playing: the user's pause.
        backend.external(.togglePlayPause)
        XCTAssertTrue(model.isPlaying)
        backend.report(.paused)
        backend.external(.outputLost)
        XCTAssertFalse(model.isPlaying)
        backend.calls.removeAll()
        model.applicationBecameActive()
        XCTAssertEqual(backend.calls, [])

        // A remote seek.
        backend.external(.seek(to: 42))
        XCTAssertEqual(backend.calls.last, "seek")
        XCTAssertEqual(backend.currentTime, 42)
        model.teardown()
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
    var onExternalEvent: (@MainActor (ExternalPlaybackEvent) -> Void)?
    var nowPlaying: NowPlaying?
    func updateNowPlaying(_ nowPlaying: NowPlaying?) { self.nowPlaying = nowPlaying }
    func external(_ event: ExternalPlaybackEvent) { onExternalEvent?(event) }
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    func report(_ activity: PlaybackActivity) {
        self.activity = activity
        onActivityChange?(activity)
    }
    /// Changes the state without reporting it, as a callback lost in a
    /// surface handover would.
    func changeSilently(_ activity: PlaybackActivity) { self.activity = activity }

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws { calls.append("load") }
    var calls: [String] = []
    func play() { calls.append("play"); report(.playing) }
    func pause() { calls.append("pause"); report(.paused) }
    func setPlaybackRate(_ rate: Float) { calls.append("rate \(rate)") }
    func seek(to seconds: Double) { calls.append("seek"); currentTime = seconds }
    func stop() { report(.paused) }
}
