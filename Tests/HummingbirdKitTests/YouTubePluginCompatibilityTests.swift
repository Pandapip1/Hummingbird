import Foundation
import XCTest
@testable import HummingbirdKit
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Opt-in compatibility probe for the moving upstream plugin. Run with:
/// HUMMINGBIRD_YOUTUBE_PLUGIN_DIR=/path/to/youtube swift test --filter YouTubePluginCompatibilityTests
final class YouTubePluginCompatibilityTests: XCTestCase {
    private let fixtureVideoURL = "https://www.youtube.com/watch?v=ukE4nf9WeQU"
    private let fixtureCaptionURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    private let fixtureChannelURL = "https://www.youtube.com/channel/UCIBNAd4nO5rk6G8YaEudqNw"

    func testCurrentOfficialPluginLoads() async throws {
        guard let path = ProcessInfo.processInfo.environment["HUMMINGBIRD_YOUTUBE_PLUGIN_DIR"] else {
            throw XCTSkip("Set HUMMINGBIRD_YOUTUBE_PLUGIN_DIR to an official plugin checkout")
        }
        let root = URL(fileURLWithPath: path)
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(contentsOf: root.appendingPathComponent("YoutubeConfig.json"))
        )
        let script = try String(contentsOf: root.appendingPathComponent("YoutubeScript.js"), encoding: .utf8)
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        defer { Task { await runtime.stop() } }
        XCTAssertNotNil(config.authentication)
        XCTAssertNotNil(config.captcha)
        try await runtime.validate()
    }

    func testCurrentOfficialPluginAnonymousHomeAndDetails() async throws {
        let runtime = try makeRuntime()
        defer { Task { await runtime.stop() } }

        let home = try await runtime.pager("getHome", as: ContentItem.self)
        XCTAssertFalse(home.initial.isEmpty)

        let url = fixtureVideoURL
        let data = try await runtime.callRaw("getContentDetails", [url], kind: "details")
        guard case .video(let details) = try PluginRuntime.decode(ContentDetails.self, from: data) else {
            return XCTFail("Expected video details")
        }
        XCTAssertFalse(details.videoSources.isEmpty && details.hls == nil && details.live == nil)
        for source in details.videoSources where source.pluginType == "DashManifestRawSource" {
            XCTAssertNotNil(source.handle)
            XCTAssertTrue(source.hasGenerate)
        }
        if details.hasTracker {
            let tracker = try await runtime.handleFromCall(details.handle, "getPlaybackTracker")
            XCTAssertNil(tracker)
        }
        if runtime.has("getContentChapters") {
            _ = try await runtime.call("getContentChapters", [url, NSNull()], as: [CompatibilityChapter].self)
        }
        if ProcessInfo.processInfo.environment["HUMMINGBIRD_PLUGIN_VERBOSE"] == "1",
           let source = details.videoSources.first(where: { $0.container == "video/mp4" }),
           let handle = source.handle {
            let manifestData = try await runtime.callHandle(handle, "generate")
            let manifest = try PluginRuntime.decode(String.self, from: manifestData)
            print("[youtube manifest] \(manifest.prefix(1_000))")
            if let executor = try await runtime.handleFromCall(handle, "getRequestExecutor") {
                print("[youtube executor] handle=\(executor.handle)")
                let initialization = try await runtime.callHandleBytes(
                    executor.handle,
                    "executeRequest",
                    ["https://grayjay.internal/video/internal/init.mp4", [String: String]()]
                )
                XCTAssertEqual(String(decoding: initialization.dropFirst(4).prefix(4), as: UTF8.self), "ftyp")
                print("[youtube init] \(initialization.count) bytes")
            }
        }
    }

    func testCurrentOfficialPluginDetailsSurviveCleanRuntimeReload() async throws {
        let runtime = try makeRuntime(settingsOverride: ["useUMP": "true", "use_native_ump": "false"])
        defer { Task { await runtime.stop() } }

        let firstStart = ContinuousClock.now
        let first = try await videoDetails(runtime)
        let firstDuration = ContinuousClock.now - firstStart
        XCTAssertNotNil(first.videoSources.first(where: { $0.pluginType == "DashManifestRawSource" }))

        await runtime.reload(reloadData: nil)
        let secondStart = ContinuousClock.now
        let second = try await videoDetails(runtime)
        let secondDuration = ContinuousClock.now - secondStart
        XCTAssertNotNil(second.videoSources.first(where: { $0.pluginType == "DashManifestRawSource" }))
        print("[youtube reload timing] initial=\(firstDuration) cleanReload=\(secondDuration)")
    }

    func testCurrentOfficialPluginSearchAndChannelSurface() async throws {
        let runtime = try makeRuntime()
        defer { Task { await runtime.stop() } }
        _ = try await runtime.enable()

        let suggestions = try await runtime.call("searchSuggestions", ["swift lang"], as: [String].self)
        XCTAssertFalse(suggestions.isEmpty)
        let search = try await runtime.pager(
            "search", ["Swift programming", NSNull(), NSNull(), NSNull()], as: ContentItem.self
        )
        XCTAssertFalse(search.initial.isEmpty)
        if search.hasMore { _ = try await search.next() }
        let channel = try await runtime.call("getChannel", [fixtureChannelURL], as: ChannelInfo.self)
        XCTAssertFalse(channel.name.isEmpty)
        let contents = try await runtime.pager(
            "getChannelContents", [fixtureChannelURL, NSNull(), NSNull(), NSNull()], as: ContentItem.self
        )
        XCTAssertFalse(contents.initial.isEmpty)
        if contents.hasMore { _ = try await contents.next() }
    }

    func testCurrentOfficialPluginCommentsRecommendationsAndSubtitles() async throws {
        let runtime = try makeRuntime()
        defer { Task { await runtime.stop() } }
        let details = try await videoDetails(runtime, url: fixtureCaptionURL)

        if details.hasComments {
            let comments = try await runtime.handlePager(details.handle, "getComments", as: PluginComment.self)
            if comments.hasMore { _ = try await comments.next() }
            if let comment = comments.initial.first(where: { $0.replyCount > 0 }) {
                _ = try await runtime.subCommentsPager(handle: comment.handle)
            }
        } else if runtime.has("getComments") {
            _ = try await runtime.pager("getComments", [fixtureCaptionURL], as: PluginComment.self)
        }

        if details.hasRecommendations {
            let recommendations = try await runtime.handlePager(
                details.handle, "getContentRecommendations", as: ContentItem.self
            )
            if recommendations.hasMore { _ = try await recommendations.next() }
        } else if runtime.has("getContentRecommendations") {
            _ = try await runtime.pager(
                "getContentRecommendations", [fixtureCaptionURL, NSNull()], as: ContentItem.self
            )
        }

        if let subtitle = details.subtitles.first {
            if ProcessInfo.processInfo.environment["HUMMINGBIRD_PLUGIN_VERBOSE"] == "1" {
                print("[youtube subtitles] \(details.subtitles)")
            }
            var text: String?
            if let handle = subtitle.getSubtitlesHandle {
                for attempt in 0..<3 where text?.isEmpty ?? true {
                    if attempt > 0 { try await Task.sleep(for: .milliseconds(500)) }
                    if let data = try? await runtime.callHandle(handle, "getSubtitles") {
                        text = try? PluginRuntime.decode(String.self, from: data)
                    }
                }
            }
            if (text?.isEmpty ?? true), let rawURL = subtitle.url, let url = URL(string: rawURL) {
                text = String(data: try await URLSession.shared.data(from: url).0, encoding: .utf8)
            }
            XCTAssertFalse(text?.isEmpty ?? true)
            XCTAssertFalse(SubtitleParser.parse(text ?? "").isEmpty)
        }
    }

    func testCurrentOfficialPluginPlaylistSurface() async throws {
        let runtime = try makeRuntime()
        defer { Task { await runtime.stop() } }
        _ = try await runtime.enable()
        guard runtime.has("searchPlaylists"), runtime.has("getPlaylist") else {
            return XCTFail("Official YouTube plugin should expose playlist search and details")
        }
        let playlists = try await runtime.pager("searchPlaylists", ["Swift programming"], as: ContentItem.self)
        let item = try XCTUnwrap(playlists.initial.first)
        let payload = try PluginRuntime.decode(
            PlaylistDetailsPayload.self,
            from: try await runtime.callRaw("getPlaylist", [item.url], kind: "playlist")
        )
        XCTAssertFalse(payload.header.name.isEmpty)
        XCTAssertFalse(payload.contents.results.compactMap(\.value).isEmpty)
        if payload.contents.hasMore {
            let next = try PluginRuntime.decode(
                PagerPayload<ContentItem>.self,
                from: try await runtime.nextPageRaw(handle: payload.contents.pager)
            )
            XCTAssertFalse(next.results.compactMap(\.value).isEmpty)
        }
    }

    func testCurrentOfficialPluginGeneratedPlaybackTransport() async throws {
        let runtime = try makeRuntime(settingsOverride: ["useUMP": "true", "use_native_ump": "false"])
        defer { Task { await runtime.stop() } }
        let url = fixtureVideoURL
        let (manifest, executor) = try await generatedPresentation(runtime, url: url)
        let playbackURL = try await PluginMediaProxy.shared.register(
            manifest: manifest, runtime: runtime, executor: executor, prefetch: true,
            useCache: true, cacheAllocationBytes: 1,
            prefetchExecutorFactory: {
                let clone = runtime.isolatedClone()
                do {
                    let (_, executor) = try await self.generatedPresentation(clone, url: url)
                    return (clone, executor)
                } catch {
                    await clone.stop()
                    throw error
                }
            }
        )
        let (masterData, masterResponse) = try await URLSession.shared.data(from: playbackURL)
        XCTAssertEqual((masterResponse as? HTTPURLResponse)?.statusCode, 200)
        let master = String(decoding: masterData, as: UTF8.self)
        XCTAssertTrue(master.contains("#EXT-X-STREAM-INF"))

        let base = playbackURL.deletingLastPathComponent()
        let (initData, initResponse) = try await URLSession.shared.data(
            from: base.appendingPathComponent("video/internal/init.mp4")
        )
        XCTAssertEqual((initResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: initData.dropFirst(4).prefix(4), as: UTF8.self), "ftyp")
        let segmentURL = URL(string: "\(base.absoluteString)/video/internal/segment.mp4?segIndex=1")!
        let (segmentData, segmentResponse) = try await URLSession.shared.data(from: segmentURL)
        XCTAssertEqual((segmentResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(segmentData.count, 1_000)
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: playbackURL)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertTrue(playable)
        XCTAssertGreaterThan(duration, 1)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        // Keep a rendering consumer attached. A video-only AVPlayer can remain
        // paused in headless XCTest even while it downloads the whole HLS VOD.
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        player.isMuted = true
        defer { player.pause() }
        let seekTarget = min(60, max(5, duration - 15))
        await player.seek(
            to: CMTime(seconds: seekTarget, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
        for _ in 0..<300 where player.currentTime().seconds < seekTarget + 0.25 {
            if item.status == .failed { throw item.error ?? PluginError.execution("AVPlayer rejected generated playback") }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(
            player.currentTime().seconds, seekTarget + 0.25,
            "Generated playback did not start directly at the one-minute UMP boundary"
        )
        guard player.currentTime().seconds > seekTarget + 0.25 else { return }
        let longSeekTarget = min(120, max(5, duration - 15))
        player.seek(
            to: CMTime(seconds: longSeekTarget, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            completionHandler: { _ in }
        )
        for _ in 0..<300 where player.currentTime().seconds < longSeekTarget + 0.25 {
            if item.status == .failed { throw item.error ?? PluginError.execution("AVPlayer rejected generated long seek") }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(player.currentTime().seconds, longSeekTarget + 0.25,
                             "Generated playback did not resume after seeking to two minutes")
        guard player.currentTime().seconds > longSeekTarget + 0.25 else { return }
        player.seek(
            to: CMTime(seconds: 1, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            completionHandler: { _ in }
        )
        for _ in 0..<150 where player.currentTime().seconds < 1.25 {
            if item.status == .failed { throw item.error ?? PluginError.execution("AVPlayer rejected generated backward seek") }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(player.currentTime().seconds, 1.25, "Generated playback did not resume after seeking backward")
        #endif
    }

    func testCurrentOfficialPluginGeneratedExecutorAcrossUMPBoundary() async throws {
        let runtime = try makeRuntime(settingsOverride: ["useUMP": "true", "use_native_ump": "false"])
        defer { Task { await runtime.stop() } }
        let (_, executor) = try await generatedPresentation(runtime, url: fixtureVideoURL)

        for segment in [13, 25] {
            let bytes = try await runtime.callHandleBytes(
                executor,
                "executeRequest",
                ["https://grayjay.internal/video/internal/segment.mp4?segIndex=\(segment)", [String: String]()]
            )
            XCTAssertGreaterThan(bytes.count, 1_000, "Non-native UMP segment \(segment) was empty")
        }
    }

    private func makeRuntime(settingsOverride: [String: String] = [:]) throws -> PluginRuntime {
        if let path = ProcessInfo.processInfo.environment["HUMMINGBIRD_YOUTUBE_PLUGIN_DIR"] {
            let root = URL(fileURLWithPath: path)
            let config = try JSONDecoder().decode(
                PluginConfig.self,
                from: Data(contentsOf: root.appendingPathComponent("YoutubeConfig.json"))
            )
            let script = try String(contentsOf: root.appendingPathComponent("YoutubeScript.js"), encoding: .utf8)
            return configuredRuntime(config: config, script: script, settings: settingsOverride)
        }
        if let path = ProcessInfo.processInfo.environment["HUMMINGBIRD_YOUTUBE_PLUGIN_DATABASE"],
           let data = StorageDatabase(url: URL(fileURLWithPath: path)).load(name: "plugins"),
           let plugin = try JSONDecoder().decode([InstalledPlugin].self, from: data)
               .first(where: { $0.config.name.caseInsensitiveCompare("YouTube") == .orderedSame }) {
            return configuredRuntime(
                config: plugin.config,
                script: plugin.script,
                settings: plugin.settings.merging(settingsOverride) { _, override in override }
            )
        }
        throw XCTSkip("Set HUMMINGBIRD_YOUTUBE_PLUGIN_DIR or HUMMINGBIRD_YOUTUBE_PLUGIN_DATABASE")
    }

    private func configuredRuntime(config: PluginConfig, script: String,
                                   settings: [String: String]) -> PluginRuntime {
        let runtime = PluginRuntime(config: config, script: script, settings: settings, auth: nil, captcha: nil)
        if ProcessInfo.processInfo.environment["HUMMINGBIRD_PLUGIN_VERBOSE"] == "1" {
            runtime.onLog = { message in
                let useful = ["Using Browser", "Using Non-Browser", "Initializing browser", "Browser result",
                              "Minter Browser", "Load succesful", "Load timeout", "UMP ", "UMP:",
                              "ABR Enabled", "Generating", "POT Type",
                              "playerdata", "Player data"]
                if useful.contains(where: message.contains) { print("[youtube] \(message)") }
            }
            runtime.onToast = { print("[youtube toast] \($0)") }
        }
        return runtime
    }

    private func videoDetails(_ runtime: PluginRuntime, url: String? = nil) async throws -> VideoDetails {
        let data = try await runtime.callRaw("getContentDetails", [url ?? fixtureVideoURL], kind: "details")
        guard case .video(let details) = try PluginRuntime.decode(ContentDetails.self, from: data) else {
            throw PluginError.execution("Expected YouTube video details")
        }
        return details
    }

    private func generatedPresentation(_ runtime: PluginRuntime, url: String) async throws -> (String, Int) {
        for attempt in 0..<2 {
            let details = try await videoDetails(runtime, url: url)
            guard let source = details.videoSources.first(where: { $0.container == "video/mp4" }),
                  let handle = source.handle else {
                throw PluginError.execution("Expected a generated MP4 source")
            }
            do {
                let manifest = try PluginRuntime.decode(
                    String.self, from: try await runtime.callHandle(handle, "generate")
                )
                guard let executor = try await runtime.handleFromCall(handle, "getRequestExecutor") else {
                    throw PluginError.execution("Expected a request executor")
                }
                return (manifest, executor.handle)
            } catch let PluginError.reloadRequired(_, reloadData) where attempt == 0 {
                await runtime.reload(reloadData: reloadData)
            }
        }
        throw PluginError.execution("Generated playback still requested a reload after recreating the runtime")
    }
}

private struct CompatibilityChapter: Decodable {
    var name: String
    var timeStart: Double
    var timeEnd: Double
    var type: Int
}
