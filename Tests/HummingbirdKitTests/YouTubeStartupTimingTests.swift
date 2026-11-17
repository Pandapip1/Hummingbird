#if canImport(AVFoundation)
import Foundation
import XCTest
@testable import HummingbirdKit

/// Opt-in, networked: where a YouTube video's start-up time goes, on isolated
/// stores (in-memory database and keychain, temporary caches). Installs the
/// official plugin from its config URL the way the Sources screen does, then
/// runs the production path: routing + getContentDetails
/// (`PlatformService.details`), then `PlayerModel.load` (selection, media
/// download, AVPlayer) until playback time advances.
///
///     HUMMINGBIRD_YOUTUBE_TIMING=1 swift test --filter YouTubeStartupTimingTests
///
/// Optional: HUMMINGBIRD_YOUTUBE_VIDEO_URL, HUMMINGBIRD_YOUTUBE_CONFIG_URL.
final class YouTubeStartupTimingTests: XCTestCase {
    @MainActor
    func testYouTubeStartupStages() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HUMMINGBIRD_YOUTUBE_TIMING"] == "1" else {
            throw XCTSkip("Set HUMMINGBIRD_YOUTUBE_TIMING=1 to measure YouTube start-up over the network")
        }
        let configURL = environment["HUMMINGBIRD_YOUTUBE_CONFIG_URL"] ?? "https://plugins.grayjay.app/Youtube/YoutubeConfig.json"
        let videoURL = environment["HUMMINGBIRD_YOUTUBE_VIDEO_URL"] ?? "https://www.youtube.com/watch?v=ukE4nf9WeQU"
        let model = makeTestAppModel()

        let installStart = ContinuousClock.now
        let preview = try await model.plugins.prepareInstall(from: configURL)
        model.plugins.commit(preview)
        print("[timing] install_ms=\(ms(installStart.duration(to: .now))) plugin=\(preview.config.name) version=\(preview.config.version)")

        let start = ContinuousClock.now
        let (runtime, content) = try await model.platform.details(url: videoURL)
        let detailsDone = ContinuousClock.now
        guard case .video(let details) = content else { return XCTFail("expected video details") }
        print("[timing] route_and_details_ms=\(ms(start.duration(to: detailsDone)))")
        print("[timing] video_sources=\(PlaybackSelector.inventory(details.videoSources))")
        print("[timing] audio_sources=\(PlaybackSelector.inventory(details.audioSources))")

        let player = PlayerModel(stores: model.stores)
        let loadTask = Task { @MainActor in
            await player.load(details: details, runtime: runtime, library: model.library, sourceURL: videoURL)
        }
        var loadedAt: ContinuousClock.Instant?
        var firstFrameAt: ContinuousClock.Instant?
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        while ContinuousClock.now < deadline {
            if loadedAt == nil, player.selected != nil { loadedAt = .now }
            if player.isPlaying, player.playbackTime > 0.2 { firstFrameAt = .now; break }
            if let error = player.errorMessage { print("[timing] player_error=\(error)"); break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let selected = player.selected
        print("[timing] selected kind=\(selected.map { String(describing: $0.kind) } ?? "-") height=\(selected?.height ?? 0) video_bitrate=\(selected?.video.bitrate ?? 0) audio_bitrate=\(selected?.audio?.bitrate ?? 0)")
        print("[timing] player_loaded_ms=\(loadedAt.map { ms(detailsDone.duration(to: $0)) } ?? -1) first_frame_ms_after_details=\(firstFrameAt.map { ms(detailsDone.duration(to: $0)) } ?? -1) total_ms=\(firstFrameAt.map { ms(start.duration(to: $0)) } ?? -1)")
        for track in player.pipeline.tracks {
            let stage = track.stage(.download)
            print("[timing] track role=\(track.role.rawValue) total=\(track.totalBytes ?? -1) downloaded=\(stage.completed.byteCount) condition=\(stage.condition)")
        }
        loadTask.cancel()
        player.teardown()
        await runtime.stop()
        XCTAssertNotNil(firstFrameAt, "playback did not start within 10 minutes")
    }

    private func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
#endif
