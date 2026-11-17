import Foundation
import XCTest
@testable import HummingbirdKit

/// Picture in Picture state flows from the backend to the controls, and
/// returning from PiP brings back the tab that owns the player.
@MainActor
final class PictureInPictureTests: XCTestCase {
    func testStateFollowsTheBackendAndRestoreSelectsTheOwningTab() async throws {
        let app = makeTestAppModel()
        let backend = PictureInPictureBackend()
        app.makePlayer = { stores in
            let player = PlayerModel(stores: stores, backend: backend)
            player.localPlaybackForTesting = Self.loopbackPlayback
            return player
        }
        let videoTab = app.activeTabID
        let player = app.player(forTab: videoTab)
        await player.select(PlaybackOption(id: "pip", label: "Video", kind: .hls,
                                           video: try JSONDecoder().decode(MediaSource.self, from: Data(#"{"url":"https://x/a.m3u8"}"#.utf8)),
                                           audio: nil, height: 720))
        XCTAssertEqual(player.pictureInPictureState, .possible, "possible once media is loaded")

        player.startPictureInPicture()
        XCTAssertEqual(player.pictureInPictureState, .starting, "a spinner while it starts, not an optimistic switch")
        backend.finishStarting()
        XCTAssertEqual(player.pictureInPictureState, .active)

        app.openInNewTab(.home, title: "Home")
        XCTAssertNotEqual(app.activeTabID, videoTab)
        backend.userReturnsFromPictureInPicture()
        XCTAssertEqual(app.activeTabID, videoTab, "returning from PiP shows the video's tab")

        app.closeWindow()
        XCTAssertEqual(backend.stopped, true, "closing the window ends playback, PiP included")
    }
}

@MainActor
private final class PictureInPictureBackend: MediaBackend {
    var currentTime = 0.0
    var isPlaying = false
    var stopped = false
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var onPictureInPictureChange: (@MainActor (PictureInPictureState) -> Void)?
    var onRestoreFromPictureInPicture: (@MainActor () -> Void)?
    private(set) var pictureInPictureState: PictureInPictureState = .unavailable {
        didSet { onPictureInPictureChange?(pictureInPictureState) }
    }

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        pictureInPictureState = .possible
    }
    func startPictureInPicture() { pictureInPictureState = .starting }
    func finishStarting() { pictureInPictureState = .active }
    func userReturnsFromPictureInPicture() {
        onRestoreFromPictureInPicture?()
        pictureInPictureState = .possible
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false; stopped = true; pictureInPictureState = .unavailable }
}
