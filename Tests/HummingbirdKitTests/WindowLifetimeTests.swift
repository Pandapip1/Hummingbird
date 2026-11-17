import Foundation
import XCTest
@testable import HummingbirdKit

/// Closing a window stops everything it plays, and only that window's.
@MainActor
final class WindowLifetimeTests: XCTestCase {
    func testClosingAWindowStopsItsPlayersAndLeavesOtherWindowsPlaying() async {
        let first = makeTestAppModel()
        let second = makeTestAppModel()
        var backends: [ObjectIdentifier: LifetimeBackend] = [:]
        for model in [first, second] {
            let owner = ObjectIdentifier(model)
            let backend = LifetimeBackend()
            backends[owner] = backend
            model.makePlayer = { stores in PlayerModel(stores: stores, backend: backend) }
        }
        let firstPlayer = first.player(forTab: first.activeTabID)
        let secondPlayer = second.player(forTab: second.activeTabID)
        firstPlayer.togglePlayback()
        secondPlayer.togglePlayback()
        XCTAssertTrue(backends[ObjectIdentifier(first)]?.isPlaying == true)

        first.closeWindow()

        XCTAssertEqual(backends[ObjectIdentifier(first)]?.stopCount, 1, "the closed window's player stops at once")
        XCTAssertFalse(backends[ObjectIdentifier(first)]?.isPlaying ?? true)
        XCTAssertEqual(first.openPlayerCount, 0, "and is released")
        XCTAssertTrue(backends[ObjectIdentifier(second)]?.isPlaying == true, "other windows keep playing")
        XCTAssertEqual(backends[ObjectIdentifier(second)]?.stopCount, 0)
        XCTAssertEqual(second.openPlayerCount, 1)
    }
}

@MainActor
private final class LifetimeBackend: MediaBackend {
    var currentTime = 0.0
    var isPlaying = false
    var stopCount = 0
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {}
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false; stopCount += 1 }
}
