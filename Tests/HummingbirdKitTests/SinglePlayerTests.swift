import Foundation
import XCTest
import AdvancedVideoPlayerKit
@testable import HummingbirdKit

/// Doubled audio after a relaunch: a load still resolving when its media was
/// torn down must never start a second, invisible player; a tab has one
/// player; a window plays one tab at a time.
@MainActor
final class SinglePlayerTests: XCTestCase {
    func testALoadResolvingDuringTeardownNeverReachesTheEngine() async throws {
        let backend = CountingBackend()
        let model = makeTestPlayerModel(backend: backend)
        let gate = Gate()
        model.localPlaybackForTesting = { option in
            await gate.wait()
            return try Self.loopbackPlayback(option)
        }
        let source = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"url":"https://x/a.m3u8"}"#.utf8))
        let selecting = Task { await model.select(PlaybackOption(id: "a", label: "A", kind: .hls, video: source, audio: nil, height: 720)) }
        try await Task.sleep(for: .milliseconds(50))
        // The tab is restored again / navigates: its media is torn down.
        model.teardown()
        await gate.open()
        _ = await selecting.value
        XCTAssertEqual(backend.loads, 0, "the stale load never starts the old engine")
    }

    func testAStoppedEngineNeverPlaysAgain() async throws {
        #if canImport(AVFoundation) && !BACKEND_GTK
        let backend = AVMediaBackend()
        backend.stop()
        let request = try PlayRequest.local(video: URL(fileURLWithPath: "/tmp/never.mp4"))
        do {
            try await backend.load(request, resumeAt: nil, autoplay: true)
            XCTFail("a retired engine loaded media")
        } catch {
            XCTAssertEqual(error as? MediaBackendLoadError, .superseded)
        }
        XCTAssertNil(backend.player?.currentItem)
        #endif
    }

    func testOnePlayerPerTabAndOneTabPlayingPerWindow() {
        let app = makeTestAppModel()
        var backends: [CountingBackend] = []
        app.makePlayer = { stores in
            let backend = CountingBackend()
            backends.append(backend)
            return PlayerModel(stores: stores, backend: backend)
        }
        let first = app.activeTabID
        let player = app.player(forTab: first)
        XCTAssertTrue(app.player(forTab: first) === player, "asking again (a remounted page) returns the same player")
        XCTAssertEqual(app.openPlayerCount, 1)

        app.openInNewTab(.home, title: "Home")
        let second = app.player(forTab: app.activeTabID)
        player.togglePlayback()
        XCTAssertTrue(player.isPlaying)
        second.togglePlayback()
        XCTAssertTrue(second.isPlaying)
        XCTAssertFalse(player.isPlaying, "starting one tab pauses the other")
        XCTAssertEqual(backends.filter(\.playing).count, 1, "exactly one engine is playing")
        app.closeWindow()
    }
}

private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor
private final class CountingBackend: MediaBackend {
    var currentTime = 0.0
    var playing = false
    var isPlaying: Bool { playing }
    var loads = 0
    var activity: PlaybackActivity { playing ? .playing : .paused }
    var onActivityChange: (@MainActor (PlaybackActivity) -> Void)?
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws { loads += 1 }
    func play() { playing = true; onActivityChange?(.playing) }
    func pause() { playing = false; onActivityChange?(.paused) }
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { playing = false }
}
