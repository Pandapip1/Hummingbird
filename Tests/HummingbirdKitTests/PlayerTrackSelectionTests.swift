import XCTest
@testable import HummingbirdKit

@MainActor
final class PlayerTrackSelectionTests: XCTestCase {
    func testSelectionReflectsBackendInitialAndRejectedChoices() async {
        let video = MediaTrack(id: "video-0", kind: .video, language: nil, label: "Main")
        let alternate = MediaTrack(id: "video-1", kind: .video, language: nil, label: "Alternate")
        let backend = SelectionBackend(tracks: [video, alternate], selected: [.video: video])
        let model = PlayerModel(backend: backend)

        XCTAssertEqual(model.selectedTrack(ofKind: .video), video)
        model.selectTrack(MediaTrack(id: "video-missing", kind: .video, language: nil, label: nil))
        XCTAssertEqual(model.selectedTrack(ofKind: .video), video)
        model.selectTrack(alternate)
        XCTAssertEqual(model.selectedTrack(ofKind: .video), alternate)
    }
}

@MainActor
private final class SelectionBackend: MediaBackend {
    var currentTime = 0.0
    var duration = 0.0
    var isPlaying = false
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    let tracks: [MediaTrack]
    private var selected: [MediaTrack.Kind: MediaTrack]
    var pictureInPictureSupported = false

    init(tracks: [MediaTrack], selected: [MediaTrack.Kind: MediaTrack]) {
        self.tracks = tracks; self.selected = selected
    }
    func selectTrack(_ track: MediaTrack?) {
        guard let track, tracks.contains(track) else { return }
        selected[track.kind] = track
    }
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? { selected[kind] }
    func setExternalSubtitle(_ url: URL?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func canPlay(_ option: PlaybackOption) -> Bool { true }
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {}
    func play() {}
    func pause() {}
    func setPlaybackRate(_ rate: Float) {}
    func seek(to seconds: Double) {}
    func stop() {}
}
