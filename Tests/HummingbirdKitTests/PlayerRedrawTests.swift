import Foundation
import Observation
import Synchronization
import XCTest
import AdvancedVideoPlayerKit
@testable import HummingbirdKit

/// Battery: while a video plays, the player ticks twice a second. Only the
/// position changes on a tick, and only the views that show it observe it
/// (`PlaybackClock`); the page's state is assigned only when it changes, so
/// the page does not redraw per tick. Nobody watching the position (controls
/// hidden, page off screen, app in the background), the player ticks
/// quietly; paused, the engine does not tick.
@MainActor
final class PlayerRedrawTests: XCTestCase {
    func testTicksInvalidateOnlyThePosition() async throws {
        let backend = TickingBackend()
        let model = makeTestPlayerModel(backend: backend)
        backend.onTick?(1)
        backend.onTick?(1.5)

        let pageChanged = Flag()
        withObservationTracking {
            // What the video page and the controls (outside the timeline) read.
            _ = model.isMediaReady
            _ = model.isPreparing
            _ = model.preparationMessage
            _ = model.bufferingMessage
            _ = model.errorMessage
            _ = model.isPlaying
            _ = model.duration
            _ = model.waitingReason
            _ = model.scrubberContent
            _ = model.playbackRate
            _ = model.title
        } onChange: { pageChanged.set() }

        let positionChanged = Flag()
        withObservationTracking { _ = model.clock.time } onChange: { positionChanged.set() }

        for second in stride(from: 2.0, through: 6.0, by: 0.5) { backend.onTick?(second) }
        XCTAssertFalse(pageChanged.value, "a tick does not redraw the page")
        XCTAssertTrue(positionChanged.value, "the position views do update")
        XCTAssertEqual(model.playbackTime, 6)

        let unchanged = Flag()
        withObservationTracking { _ = model.clock.time } onChange: { unchanged.set() }
        backend.onTick?(6)
        XCTAssertFalse(unchanged.value, "the same position notifies no one")
    }

    func testTicksSlowDownWhenNobodyWatchesThePosition() {
        let backend = TickingBackend()
        let model = makeTestPlayerModel(backend: backend)
        backend.onTick?(1)
        XCTAssertEqual(backend.interval, PlayerModel.visibleTickInterval)
        model.controlsVisibilityChanged(false)
        XCTAssertEqual(backend.interval, PlayerModel.quietTickInterval, "controls hidden")
        model.controlsVisibilityChanged(true)
        XCTAssertEqual(backend.interval, PlayerModel.visibleTickInterval)
        model.pageVisibilityChanged(false)
        XCTAssertEqual(backend.interval, PlayerModel.quietTickInterval, "page off screen")
        model.pageVisibilityChanged(true)
        XCTAssertEqual(backend.interval, PlayerModel.visibleTickInterval)
        XCTAssertLessThanOrEqual(PlayerModel.quietTickInterval, 2.5, "progress is still recorded at least every 5 s")
    }
}

private final class Flag: Sendable {
    private let raised = Mutex(false)
    var value: Bool { raised.withLock { $0 } }
    func set() { raised.withLock { $0 = true } }
}

private final class TickingBackend: MediaBackend {
    var currentTime = 0.0
    var isPlaying: Bool { true }
    var activity: PlaybackActivity { .playing }
    var interval = 0.0
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() {}
    func setTickInterval(_ seconds: Double) { interval = seconds }
}
