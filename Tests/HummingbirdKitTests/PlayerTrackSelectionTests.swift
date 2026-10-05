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

    func testSupersededLoadDoesNotReplaceNewerSelection() async {
        let backend = SupersedingBackend()
        let model = PlayerModel(backend: backend)
        let first = playbackOption(id: "first", url: "https://example.com/first.mp4")
        let second = playbackOption(id: "second", url: "https://example.com/second.mp4")

        let firstTask = Task { await model.select(first) }
        await backend.waitForFirstLoad()
        await model.select(second)
        backend.supersedeFirstLoad()
        await firstTask.value

        XCTAssertEqual(model.selected, second)
        XCTAssertNil(model.errorMessage)
    }

    func testFailedReplacementKeepsExistingSelection() async {
        let backend = FailingReplacementBackend()
        let model = PlayerModel(backend: backend)
        let first = playbackOption(id: "first", url: "https://example.com/first.mp4")
        let second = playbackOption(id: "second", url: "https://example.com/second.mp4")

        await model.select(first)
        await model.select(second)

        XCTAssertEqual(model.selected, first)
        XCTAssertEqual(model.errorMessage, "replacement failed")
    }

    func testFailedReplacementLetsInstalledLoadFinish() async {
        let backend = InstalledLoadBackend()
        let model = PlayerModel(backend: backend)
        let first = playbackOption(id: "first", url: "https://example.com/first.mp4")
        let second = playbackOption(id: "second", url: "https://example.com/second.mp4")

        let firstTask = Task { await model.select(first) }
        await backend.waitForFirstItem()
        await model.select(second)
        backend.finishFirstLoad()
        await firstTask.value

        XCTAssertEqual(model.selected, first)
        XCTAssertTrue(backend.firstItemInstalled)
        XCTAssertTrue(backend.firstItemFinished)
        XCTAssertEqual(model.errorMessage, "replacement failed")
    }

    func testCancelledLoadBeforeCommitDoesNotSelectOption() async {
        let backend = CancellableLoadBackend(installsFirstItem: false)
        let model = PlayerModel(backend: backend)
        let option = playbackOption(id: "first", url: "https://example.com/first.mp4")

        let task = Task { await model.select(option) }
        await backend.waitForFirstLoad()
        task.cancel()
        await backend.waitForFirstCancellation()
        await task.value

        XCTAssertNil(model.selected)
        XCTAssertNil(model.errorMessage)
    }

    func testCancelledInstalledLoadDoesNotWaitForSuspendedReplacement() async {
        let backend = CancellableLoadBackend(installsFirstItem: true)
        let model = PlayerModel(backend: backend)
        let first = playbackOption(id: "first", url: "https://example.com/first.mp4")
        let second = playbackOption(id: "second", url: "https://example.com/second.mp4")

        let firstTask = Task { await model.select(first) }
        await backend.waitForFirstLoad()
        let secondTask = Task { await model.select(second) }
        await backend.waitForSecondLoad()
        firstTask.cancel()
        await backend.waitForFirstCancellation()
        await firstTask.value

        XCTAssertTrue(backend.firstItemInstalled)
        XCTAssertNil(model.selected)
        secondTask.cancel()
        await secondTask.value
    }

    private func playbackOption(id: String, url: String) -> PlaybackOption {
        let source = try! JSONDecoder().decode(
            MediaSource.self,
            from: Data("{\"url\":\"\(url)\",\"container\":\"video/mp4\"}".utf8)
        )
        return PlaybackOption(id: id, label: id, kind: .progressive, video: source, audio: nil, height: 720)
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

@MainActor
private final class SupersedingBackend: MediaBackend {
    var currentTime = 0.0
    var duration = 60.0
    var isPlaying = false
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var pictureInPictureSupported = false
    private var loadCount = 0
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private var firstLoadStarted: CheckedContinuation<Void, Never>?

    func waitForFirstLoad() async {
        await withCheckedContinuation { firstLoadStarted = $0 }
    }

    func supersedeFirstLoad() {
        firstLoadContinuation?.resume()
        firstLoadContinuation = nil
    }

    func selectTrack(_ track: MediaTrack?) {}
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? { nil }
    func setExternalSubtitle(_ url: URL?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func canPlay(_ option: PlaybackOption) -> Bool { true }
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        loadCount += 1
        guard loadCount == 1 else {
            isPlaying = true
            return
        }
        firstLoadStarted?.resume()
        firstLoadStarted = nil
        await withCheckedContinuation { firstLoadContinuation = $0 }
        throw MediaBackendLoadError.superseded
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func setPlaybackRate(_ rate: Float) {}
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }
}

@MainActor
private final class FailingReplacementBackend: MediaBackend {
    var currentTime = 0.0
    var duration = 60.0
    var isPlaying = false
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var pictureInPictureSupported = false
    private var loadCount = 0

    func selectTrack(_ track: MediaTrack?) {}
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? { nil }
    func setExternalSubtitle(_ url: URL?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func canPlay(_ option: PlaybackOption) -> Bool { true }
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        loadCount += 1
        if loadCount > 1 { throw PluginError.execution("replacement failed") }
        isPlaying = true
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func setPlaybackRate(_ rate: Float) {}
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }
}

@MainActor
private final class InstalledLoadBackend: MediaBackend {
    var currentTime = 0.0
    var duration = 60.0
    var isPlaying = false
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var pictureInPictureSupported = false
    var firstItemInstalled = false
    var firstItemFinished = false
    private var loadCount = 0
    private var firstItemContinuation: CheckedContinuation<Void, Never>?
    private var finishFirstLoadContinuation: CheckedContinuation<Void, Never>?

    func waitForFirstItem() async {
        await withCheckedContinuation { firstItemContinuation = $0 }
    }

    func finishFirstLoad() {
        finishFirstLoadContinuation?.resume()
        finishFirstLoadContinuation = nil
    }

    func selectTrack(_ track: MediaTrack?) {}
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? { nil }
    func setExternalSubtitle(_ url: URL?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func canPlay(_ option: PlaybackOption) -> Bool { true }
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        loadCount += 1
        guard loadCount == 1 else { throw PluginError.execution("replacement failed") }
        firstItemInstalled = true
        firstItemContinuation?.resume()
        firstItemContinuation = nil
        await withCheckedContinuation { finishFirstLoadContinuation = $0 }
        firstItemFinished = true
        isPlaying = true
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func setPlaybackRate(_ rate: Float) {}
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }
}

@MainActor
private final class CancellableLoadBackend: MediaBackend {
    var currentTime = 0.0
    var duration = 60.0
    var isPlaying = false
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var pictureInPictureSupported = false
    let installsFirstItem: Bool
    var firstItemInstalled = false
    private var loadCount = 0
    private var firstLoadStarted = false
    private var secondLoadStarted = false
    private var firstCancellationObserved = false
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private var secondLoadContinuation: CheckedContinuation<Void, Never>?
    private var firstCancellationContinuation: CheckedContinuation<Void, Never>?
    private var firstWaiter: CheckedContinuation<Void, Never>?
    private var secondWaiter: CheckedContinuation<Void, Never>?

    init(installsFirstItem: Bool) {
        self.installsFirstItem = installsFirstItem
    }

    func waitForFirstLoad() async {
        if firstLoadStarted { return }
        await withCheckedContinuation { firstLoadContinuation = $0 }
    }

    func waitForSecondLoad() async {
        if secondLoadStarted { return }
        await withCheckedContinuation { secondLoadContinuation = $0 }
    }

    func waitForFirstCancellation() async {
        if firstCancellationObserved { return }
        await withCheckedContinuation { firstCancellationContinuation = $0 }
    }

    func selectTrack(_ track: MediaTrack?) {}
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? { nil }
    func setExternalSubtitle(_ url: URL?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func canPlay(_ option: PlaybackOption) -> Bool { true }
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        loadCount += 1
        if loadCount == 1 {
            firstItemInstalled = installsFirstItem
            firstLoadStarted = true
            firstLoadContinuation?.resume()
            firstLoadContinuation = nil
            do {
                try await suspendFirstLoad()
            } catch {
                firstCancellationObserved = true
                firstCancellationContinuation?.resume()
                firstCancellationContinuation = nil
                throw error
            }
        } else {
            secondLoadStarted = true
            secondLoadContinuation?.resume()
            secondLoadContinuation = nil
            try await suspendSecondLoad()
        }
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func setPlaybackRate(_ rate: Float) {}
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }

    private func suspendFirstLoad() async throws {
        try await withTaskCancellationHandler {
            await withCheckedContinuation { firstWaiter = $0 }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.firstWaiter?.resume()
                self?.firstWaiter = nil
            }
        }
    }

    private func suspendSecondLoad() async throws {
        try await withTaskCancellationHandler {
            await withCheckedContinuation { secondWaiter = $0 }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.secondWaiter?.resume()
                self?.secondWaiter = nil
            }
        }
    }
}
