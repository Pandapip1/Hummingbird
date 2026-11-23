import XCTest
@testable import HummingbirdKit

@MainActor
final class PlayerTrackSelectionTests: XCTestCase {
    /// No optimistic checkmark: the menu keeps the current stream selected and
    /// marks the new one pending until it is playing; a failed switch keeps
    /// the old stream and shows the error.
    func testSourceSwitchStaysPendingUntilTheNewStreamPlays() async throws {
        let backend = DelayedStartBackend()
        let model = makeTestPlayerModel(backend: backend, confirmsSwitchOnLoad: false)
        let first = playbackOption(id: "first", url: "https://example.com/first.m3u8")
        await model.select(first)  // paused: confirmed by loading
        XCTAssertEqual(model.selected, first)
        backend.isPlaying = true

        let second = playbackOption(id: "second", url: "https://example.com/second.m3u8")
        let switching = Task { await model.select(second) }
        try await waitUntil { backend.loads == 2 }
        XCTAssertEqual(model.selected, first, "the checkmark stays on the playing stream")
        XCTAssertEqual(model.pendingOption, second)
        XCTAssertTrue(model.isMediaReady, "every control stays usable while a switch is pending")

        backend.advance()
        await switching.value
        XCTAssertEqual(model.selected, second)
        XCTAssertNil(model.pendingOption)

        backend.failNextLoad = true
        let third = playbackOption(id: "third", url: "https://example.com/third.m3u8")
        await model.select(third)
        XCTAssertEqual(model.selected, second, "a failed switch keeps the old stream")
        XCTAssertNil(model.pendingOption)
        XCTAssertEqual(model.errorMessage, "switch failed")

        // A slow stream stays pending (no deadline); one the player reports as
        // failed is a failed switch: the previous stream is loaded back and the
        // checkmark never moves.
        let loadsBefore = backend.loads
        let broken = playbackOption(id: "broken", url: "https://example.com/broken.m3u8")
        let failing = Task { await model.select(broken) }
        try await waitUntil { backend.loads == loadsBefore + 1 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.pendingOption, broken, "still pending while it has not played")
        backend.reportFailure("decode error")
        await failing.value
        XCTAssertEqual(model.selected, second)
        XCTAssertNil(model.pendingOption)
        XCTAssertEqual(backend.loads, loadsBefore + 2, "the new stream, then the previous one again")
        XCTAssertEqual(model.errorMessage, PlayerModel.PlaybackNotConfirmed(reason: "decode error").errorDescription)
    }

    /// A pending switch never locks the player: another choice supersedes it
    /// (the spinner moves), and choosing the playing stream cancels it (the
    /// playing stream is put back if the new one had replaced it).
    func testAPendingSwitchCanBeSupersededOrCancelled() async throws {
        let backend = DelayedStartBackend()
        let model = makeTestPlayerModel(backend: backend, confirmsSwitchOnLoad: false)
        let first = playbackOption(id: "first", url: "https://example.com/first.m3u8")
        await model.select(first)
        backend.isPlaying = true

        let second = playbackOption(id: "second", url: "https://example.com/second.m3u8")
        let switching = Task { await model.select(second) }
        try await waitUntil { backend.loads == 2 }
        XCTAssertEqual(model.pendingOption, second)
        XCTAssertTrue(model.isMediaReady)

        // Another choice supersedes the pending one.
        let third = playbackOption(id: "third", url: "https://example.com/third.m3u8")
        let superseding = Task { await model.select(third) }
        try await waitUntil { backend.loads == 3 }
        XCTAssertEqual(model.pendingOption, third, "the spinner moves to the newer choice")
        XCTAssertEqual(model.selected, first, "the checkmark stays on the playing stream")
        await switching.value

        // Choosing the playing stream cancels the pending switch.
        await model.select(first)
        await superseding.value
        XCTAssertNil(model.pendingOption)
        XCTAssertEqual(model.selected, first)
        XCTAssertEqual(backend.loaded.last, "first.m3u8", "the playing stream is put back")
        XCTAssertNil(model.errorMessage, "a cancelled switch is not an error")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not met in 5 s") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testSelectionReflectsBackendInitialAndRejectedChoices() async {
        let video = MediaTrack(id: "video-0", kind: .video, language: nil, label: "Main")
        let alternate = MediaTrack(id: "video-1", kind: .video, language: nil, label: "Alternate")
        let backend = SelectionBackend(tracks: [video, alternate], selected: [.video: video])
        let model = makeTestPlayerModel(backend: backend)

        XCTAssertEqual(model.selectedTrack(ofKind: .video), video)
        model.selectTrack(MediaTrack(id: "video-missing", kind: .video, language: nil, label: nil))
        XCTAssertEqual(model.selectedTrack(ofKind: .video), video)
        model.selectTrack(alternate)
        XCTAssertEqual(model.selectedTrack(ofKind: .video), alternate)
    }

    func testSupersededLoadDoesNotReplaceNewerSelection() async {
        let backend = SupersedingBackend()
        let model = makeTestPlayerModel(backend: backend)
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
        let model = makeTestPlayerModel(backend: backend)
        let first = playbackOption(id: "first", url: "https://example.com/first.mp4")
        let second = playbackOption(id: "second", url: "https://example.com/second.mp4")

        await model.select(first)
        await model.select(second)

        XCTAssertEqual(model.selected, first)
        XCTAssertEqual(model.errorMessage, "replacement failed")
    }

    func testFailedReplacementLetsInstalledLoadFinish() async {
        let backend = InstalledLoadBackend()
        let model = makeTestPlayerModel(backend: backend)
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
        let model = makeTestPlayerModel(backend: backend)
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
        let model = makeTestPlayerModel(backend: backend)
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

    func testQualitySelectionPreservesPositionAndPausedState() async {
        let backend = RecordingSelectionBackend(currentTime: 42, isPlaying: false)
        let model = makeTestPlayerModel(backend: backend)
        let option = playbackOption(id: "720p", url: "https://example.com/720.mp4")

        await model.select(option)

        XCTAssertEqual(backend.loadedResumeTime, 42)
        XCTAssertEqual(backend.loadedAutoplay, false)
        XCTAssertFalse(model.isPlaying)

        backend.currentTime = 57
        backend.isPlaying = true
        let next = playbackOption(id: "1080p", url: "https://example.com/1080.mp4")
        await model.select(next)

        XCTAssertEqual(backend.loadedResumeTime, 57)
        XCTAssertEqual(backend.loadedAutoplay, true)
        XCTAssertTrue(model.isPlaying)

        backend.currentTime = 3
        backend.isPlaying = false
        let nearStart = playbackOption(id: "480p", url: "https://example.com/480.mp4")
        await model.select(nearStart)

        XCTAssertEqual(backend.loadedResumeTime, 3, "an in-session quality change must not apply saved-history restart rules")
        XCTAssertEqual(backend.loadedAutoplay, false)
    }

    func testSuccessfulQualityRetryClearsPreviousError() async {
        let backend = RecoveringReplacementBackend()
        let model = makeTestPlayerModel(backend: backend)
        let initial = playbackOption(id: "initial", url: "https://example.com/initial.mp4")
        let broken = playbackOption(id: "broken", url: "https://example.com/broken.mp4")
        let recovered = playbackOption(id: "recovered", url: "https://example.com/recovered.mp4")

        await model.select(initial)
        await model.select(broken)
        XCTAssertEqual(model.selected, initial)
        XCTAssertEqual(model.errorMessage, "replacement failed")

        await model.select(recovered)
        XCTAssertEqual(model.selected, recovered)
        XCTAssertNil(model.errorMessage)
    }

    private func playbackOption(id: String, url: String) -> PlaybackOption {
        let source = try! JSONDecoder().decode(
            MediaSource.self,
            from: Data("{\"url\":\"\(url)\",\"container\":\"video/mp4\"}".utf8)
        )
        // Upstream adaptive HLS goes straight to the backend; these tests are about
        // load generations and cancellation, not where on-demand bytes come from.
        return PlaybackOption(id: id, label: id, kind: .hls, video: source, audio: nil, height: 720)
    }
}

@MainActor
private final class DelayedStartBackend: MediaBackend {
    var currentTime = 10.0
    var duration = 120.0
    var isPlaying = false
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var failNextLoad = false
    private(set) var loads = 0
    private(set) var loaded: [String] = []

    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        loads += 1
        loaded.append(request.video.url.lastPathComponent)
        if failNextLoad { failNextLoad = false; throw PluginError.execution("switch failed") }
        isPlaying = autoplay
    }
    /// The new item shows its first frames.
    func advance() { currentTime += 1 }
    /// The new item fails, as AVPlayer reports a failed item.
    func reportFailure(_ message: String) { onFailure?(message) }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }
}

@MainActor
private final class RecordingSelectionBackend: MediaBackend {
    var currentTime: Double
    var duration = 120.0
    var isPlaying: Bool
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var loadedResumeTime: Double?
    var loadedAutoplay: Bool?

    init(currentTime: Double, isPlaying: Bool) {
        self.currentTime = currentTime
        self.isPlaying = isPlaying
    }

    func selectTrack(_ track: MediaTrack?) {}
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? { nil }
    func setExternalSubtitle(_ url: URL?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func canPlay(_ option: PlaybackOption) -> Bool { true }
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        loadedResumeTime = resumeAt
        loadedAutoplay = autoplay
        if let resumeAt { currentTime = resumeAt }
        isPlaying = autoplay
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func setPlaybackRate(_ rate: Float) {}
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }
}

@MainActor
private final class RecoveringReplacementBackend: MediaBackend {
    var currentTime = 30.0
    var duration = 120.0
    var isPlaying = true
    var onTick: (@MainActor (Double) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    private var loadCount = 0

    func selectTrack(_ track: MediaTrack?) {}
    func selectedTrack(ofKind kind: MediaTrack.Kind) -> MediaTrack? { nil }
    func setExternalSubtitle(_ url: URL?) {}
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func canPlay(_ option: PlaybackOption) -> Bool { true }
    func load(_ request: PlayRequest, resumeAt: Double?, autoplay: Bool) async throws {
        loadCount += 1
        if loadCount == 2 { throw PluginError.execution("replacement failed") }
        isPlaying = autoplay
    }
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func setPlaybackRate(_ rate: Float) {}
    func seek(to seconds: Double) { currentTime = seconds }
    func stop() { isPlaying = false }
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
