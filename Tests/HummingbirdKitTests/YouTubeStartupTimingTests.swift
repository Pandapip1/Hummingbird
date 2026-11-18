#if canImport(AVFoundation)
import Foundation
import XCTest
import AVFoundation
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
        print("[timing] duration seek_bar=\(player.duration) index=\(player.pipeline.mediaDuration ?? -1) declared=\(details.item.duration ?? -1)")
        XCTAssertEqual(player.duration, Double(details.item.duration ?? 0), accuracy: 2, "the seek bar ends at the real length")
        for track in player.pipeline.tracks {
            let stage = track.stage(.download)
            print("[timing] track role=\(track.role.rawValue) total=\(track.totalBytes ?? -1) downloaded=\(stage.completed.byteCount) condition=\(stage.condition)")
        }
        loadTask.cancel()
        player.teardown()
        await runtime.stop()
        XCTAssertNotNil(firstFrameAt, "playback did not start within 10 minutes")
    }

    /// What the removed progressive path did: AVURLAssets on the upstream
    /// URLs with the request modifier's headers from one call, loading
    /// duration and tracks as AVMediaBackend.makeItem did. Measures how long
    /// that takes and what duration AVFoundation reports.
    @MainActor
    func testOldUpstreamCompositionStartup() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HUMMINGBIRD_YOUTUBE_TIMING"] == "1" else {
            throw XCTSkip("Set HUMMINGBIRD_YOUTUBE_TIMING=1 to measure YouTube start-up over the network")
        }
        let configURL = environment["HUMMINGBIRD_YOUTUBE_CONFIG_URL"] ?? "https://plugins.grayjay.app/Youtube/YoutubeConfig.json"
        let videoURL = environment["HUMMINGBIRD_YOUTUBE_VIDEO_URL"] ?? "https://www.youtube.com/watch?v=ukE4nf9WeQU"
        let model = makeTestAppModel()
        model.plugins.commit(try await model.plugins.prepareInstall(from: configURL))
        let (runtime, content) = try await model.platform.details(url: videoURL)
        guard case .video(let details) = content else { return XCTFail("expected video details") }
        let option = try XCTUnwrap(PlaybackSelector.best(PlaybackSelector.options(for: details), maxHeight: 1080))
        print("[old] declared_duration=\(details.item.duration ?? -1)")
        let tracks: [(String, MediaSource)] = [("video", option.video)] + (option.audio.map { [("audio", $0)] } ?? [])
        for (role, source) in tracks {
            var url = try XCTUnwrap(URL(string: source.url))
            var headers: [String: String] = [:]
            if let modifier = source.requestModifier {
                let modified = try await runtime.modifyRequest(handle: modifier.handle, url: url, headers: [:])
                url = modified.url
                headers = modified.headers
            }
            let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let start = ContinuousClock.now
            let isVideo = role == "video"
            let result = await withTaskGroup(of: String.self) { group in
                group.addTask {
                    do {
                        let duration = try await asset.load(.duration)
                        let found = try await asset.loadTracks(withMediaType: isVideo ? .video : .audio)
                        return "duration=\(duration.seconds) tracks=\(found.count)"
                    } catch { return "error=\(error.localizedDescription)" }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(300))
                    return "timeout=300s"
                }
                let first = await group.next() ?? "none"
                group.cancelAll()
                return first
            }
            print("[old] role=\(role) load_ms=\(ms(start.duration(to: .now))) \(result)")
            asset.cancelLoading()
        }
        await runtime.stop()
    }


    private func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
#endif
