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

    /// Switching streams on a playing YouTube video (1080p -> 720p -> 1080p):
    /// each switch must complete (the checkmark moves), resume near the same
    /// position and keep playing.
    @MainActor
    func testYouTubeStreamSwitches() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HUMMINGBIRD_YOUTUBE_TIMING"] == "1" else {
            throw XCTSkip("Set HUMMINGBIRD_YOUTUBE_TIMING=1 to measure YouTube stream switches over the network")
        }
        let configURL = environment["HUMMINGBIRD_YOUTUBE_CONFIG_URL"] ?? "https://plugins.grayjay.app/Youtube/YoutubeConfig.json"
        let videoURL = environment["HUMMINGBIRD_YOUTUBE_VIDEO_URL"] ?? "https://www.youtube.com/watch?v=ukE4nf9WeQU"
        let model = makeTestAppModel()
        try await condition(model, environment)
        model.plugins.commit(try await model.plugins.prepareInstall(from: configURL))
        let (runtime, content) = try await model.platform.details(url: videoURL)
        guard case .video(let details) = content else { return XCTFail("expected video details") }
        let player = PlayerModel(stores: model.stores)
        let loading = Task { @MainActor in
            await player.load(details: details, runtime: runtime, library: model.library, sourceURL: videoURL)
        }
        defer { loading.cancel(); player.teardown() }
        func until(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
            let end = ContinuousClock.now.advanced(by: .seconds(seconds))
            while ContinuousClock.now < end {
                if condition() { return true }
                if let error = player.errorMessage { print("[timing] player_error=\(error)"); return false }
                try await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }
        let started = try await until(600) { player.isPlaying && player.playbackTime > 5 }
        XCTAssertTrue(started, "playback did not start")
        print("[timing] options=\(player.options.map { "\($0.height)p:\($0.kind)" })")
        for height in [720, 1080] {
            guard let option = player.options.first(where: { $0.height == height }) else {
                print("[timing] no \(height)p option"); continue
            }
            let before = player.playbackTime
            let switchStart = ContinuousClock.now
            let switching = Task { @MainActor in await player.select(option) }
            let moved = try await until(300) { player.selected?.id == option.id }
            let switchedAt = ContinuousClock.now
            let advancing = try await until(60) { player.isPlaying && player.playbackTime > player.playbackTime.rounded(.down) && player.waitingReason == nil }
            let after = player.playbackTime
            await switching.value
            print("[timing] switch_to=\(height)p confirmed=\(moved) ms=\(ms(switchStart.duration(to: switchedAt))) before=\(before) after=\(after) playing=\(advancing)")
            XCTAssertTrue(moved, "the switch to \(height)p completed")
            XCTAssertGreaterThanOrEqual(after, before - 6, "resumed where playback was (within a segment), not earlier")
            let resumed = try await until(30) { player.playbackTime > after + 2 }
            XCTAssertTrue(resumed, "playback keeps advancing after the switch to \(height)p")
        }
        await runtime.stop()
    }

    /// Plays a YouTube video for a long time (HUMMINGBIRD_YOUTUBE_PLAY_MINUTES,
    /// default 20) and records every pause against what the download did: a
    /// sample every 10 s (position, state, margin ahead, transfer rate vs.
    /// media rate per track) and an event line for every upstream issue and
    /// every pause, with its reason and the margins at that moment. Per-piece
    /// detail (status, bytes, rate) is in the unified log (upstream_issue,
    /// piece_retry, local_request_wait, playback_activity, source_refreshed).
    @MainActor
    func testYouTubeLongPlaybackHealth() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HUMMINGBIRD_YOUTUBE_TIMING"] == "1" else {
            throw XCTSkip("Set HUMMINGBIRD_YOUTUBE_TIMING=1 to measure YouTube playback health over the network")
        }
        let configURL = environment["HUMMINGBIRD_YOUTUBE_CONFIG_URL"] ?? "https://plugins.grayjay.app/Youtube/YoutubeConfig.json"
        let videoURL = environment["HUMMINGBIRD_YOUTUBE_VIDEO_URL"] ?? "https://www.youtube.com/watch?v=ukE4nf9WeQU"
        let minutes = Double(environment["HUMMINGBIRD_YOUTUBE_PLAY_MINUTES"] ?? "20") ?? 20
        let model = makeTestAppModel()
        try await condition(model, environment)
        model.plugins.commit(try await model.plugins.prepareInstall(from: configURL))
        let (runtime, content) = try await model.platform.details(url: videoURL)
        guard case .video(let details) = content else { return XCTFail("expected video details") }
        print("[health] video duration=\(details.item.duration ?? -1)")
        let player = PlayerModel(stores: model.stores)
        let loading = Task { @MainActor in
            await player.load(details: details, runtime: runtime, library: model.library, sourceURL: videoURL)
        }
        defer { loading.cancel(); player.teardown() }
        let start = ContinuousClock.now
        func t() -> String { String(format: "%7.1f", Double(start.duration(to: .now).components.seconds)) }
        let end = start.advanced(by: .seconds(minutes * 60))
        var lastSample = ContinuousClock.now.advanced(by: .seconds(-60))
        var lastPosition = -1.0
        var stuckSince: ContinuousClock.Instant?
        var pauses = 0
        var pausedSeconds = 0.0
        var pauseReported = false
        var firstFrame: Double?
        var seenIssues: [String: Int] = [:]
        while ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(250))
            let position = player.playbackTime
            let margins = player.pipeline.tracks.map { "\($0.role.rawValue)=\(String(format: "%.0f", PlayerModel.margin(ahead: position, in: $0.timeRanges(for: .download))))s" }.joined(separator: " ")
            // Upstream issues as they happen.
            for track in player.pipeline.tracks {
                guard let health = track.health else { continue }
                for (kind, count) in health.issueCounts where count != seenIssues["\(track.role.rawValue).\(kind.rawValue)"] {
                    seenIssues["\(track.role.rawValue).\(kind.rawValue)"] = count
                    print("[health] t=\(t()) upstream_issue role=\(track.role.rawValue) kind=\(kind.rawValue) count=\(count) detail=\(health.lastIssueDetail ?? "-") refreshes=\(health.refreshes)")
                }
            }
            // Pauses: wanted to play, clock not advancing.
            if player.isPlaying, abs(position - lastPosition) < 0.01, position > 0 {
                if stuckSince == nil { stuckSince = .now }
                if let since = stuckSince, since.duration(to: .now) >= .seconds(1), !pauseReported {
                    pauseReported = true
                    pauses += 1
                    print("[health] t=\(t()) PAUSE begins position=\(String(format: "%.1f", position)) reason=\(player.waitingReason ?? "none") recovering=\(player.isRecovering) margins: \(margins)")
                }
            } else if let since = stuckSince {
                let length = Double(since.duration(to: .now).components.seconds)
                stuckSince = nil
                guard pauseReported else { lastPosition = position; continue }
                pauseReported = false
                pausedSeconds += length
                print("[health] t=\(t()) PAUSE ends after \(length) s position=\(String(format: "%.1f", position)) margins: \(margins)")
                stuckSince = nil
            }
            if firstFrame == nil, player.isPlaying, position > 0.2 {
                firstFrame = Double(start.duration(to: .now).components.seconds)
                print("[health] t=\(t()) first_frame startup_s=\(firstFrame ?? -1)")
            }
            lastPosition = position
            if lastSample.duration(to: .now) >= .seconds(10) {
                lastSample = .now
                let tracks = player.pipeline.tracks.map { track -> String in
                    let h = track.health
                    let rate = h.map { Int($0.throughput * 8 / 1_000) } ?? 0
                    let media = h?.mediaRate.map { Int($0 * 8 / 1_000) } ?? 0
                    return "\(track.role.rawValue): \(rate)kbps media=\(media)kbps done=\(track.stage(.download).completed.byteCount)/\(track.totalBytes ?? -1)"
                }.joined(separator: " | ")
                print("[health] t=\(t()) sample position=\(String(format: "%.1f", position)) playing=\(player.isPlaying) waiting=\(player.waitingReason ?? "-") margins: \(margins) | \(tracks)")
            }
            if let error = player.errorMessage { print("[health] t=\(t()) player_error=\(error)") ; break }
            if let duration = details.item.duration, position > Double(duration) - 2 { break }
        }
        print("[health] summary profile=\(environment["HUMMINGBIRD_NETWORK_PROFILE"] ?? "none") startup_s=\(firstFrame ?? -1) pauses=\(pauses) paused_seconds=\(pausedSeconds) played=\(player.playbackTime) issues=\(seenIssues)")
        await runtime.stop()
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
                let data = try await runtime.callHandle(modifier.handle, "modifyRequest", [source.url, [String: String]()])
                let modified = try JSONDecoder().decode(OldModifiedRequest.self, from: data)
                if let next = modified.url.flatMap(URL.init(string:)) { url = next }
                headers = modified.headers ?? [:]
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

    private struct OldModifiedRequest: Decodable { var url: String?; var headers: [String: String]? }

    /// Puts the in-process network conditioner (HUMMINGBIRD_NETWORK_PROFILE) between
    /// the media downloads and upstream.
    @MainActor
    private func condition(_ model: AppModel, _ environment: [String: String]) async throws {
        guard let name = environment["HUMMINGBIRD_NETWORK_PROFILE"], name != "none" else { return }
        let profile = try XCTUnwrap(NetworkProfile.all[name], "unknown profile \(name)")
        let downloads = model.stores.mediaDownloads
        let base = await downloads.currentTransport
        await downloads.useTransport(NetworkConditioner(base: base, profile: profile))
        print("[health] network profile=\(name)")
    }

    private func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }
}
#endif
