import Foundation
import XCTest
@testable import HummingbirdKit
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Opt-in compatibility probe for the moving upstream plugin. Run with:
/// HUMMINGBIRD_YOUTUBE_PLUGIN_DIR=/path/to/youtube swift test --filter YouTubePluginCompatibilityTests
final class YouTubePluginCompatibilityTests: XCTestCase {
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
        try await runtime.validate()
    }

    func testCurrentOfficialPluginAnonymousHomeAndDetails() async throws {
        let runtime = try makeRuntime()
        defer { Task { await runtime.stop() } }

        let home = try await runtime.pager("getHome", as: ContentItem.self)
        XCTAssertFalse(home.initial.isEmpty)

        let url = "https://www.youtube.com/watch?v=S4Qf8o4QSDs"
        let data = try await runtime.callRaw("getContentDetails", [url], kind: "details")
        guard case .video(let details) = try PluginRuntime.decode(ContentDetails.self, from: data) else {
            return XCTFail("Expected video details")
        }
        XCTAssertFalse(details.videoSources.isEmpty && details.hls == nil && details.live == nil)
        for source in details.videoSources where source.pluginType == "DashManifestRawSource" {
            XCTAssertNotNil(source.handle)
            XCTAssertTrue(source.hasGenerate)
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
                    ["https://grayjay.internal/video/internal/init.mp4", [String: String](), "GET", NSNull()]
                )
                XCTAssertEqual(String(decoding: initialization.dropFirst(4).prefix(4), as: UTF8.self), "ftyp")
                print("[youtube init] \(initialization.count) bytes")
            }
        }
    }

    func testCurrentOfficialPluginGeneratedPlaybackTransport() async throws {
        let runtime = try makeRuntime()
        defer { Task { await runtime.stop() } }
        let url = "https://www.youtube.com/watch?v=S4Qf8o4QSDs"
        let data = try await runtime.callRaw("getContentDetails", [url], kind: "details")
        guard case .video(let details) = try PluginRuntime.decode(ContentDetails.self, from: data),
              let source = details.videoSources.first(where: { $0.container == "video/mp4" }),
              let handle = source.handle else { return XCTFail("Expected a generated MP4 source") }
        let manifest = try PluginRuntime.decode(
            String.self, from: try await runtime.callHandle(handle, "generate")
        )
        guard let executor = try await runtime.handleFromCall(handle, "getRequestExecutor") else {
            return XCTFail("Expected a request executor")
        }
        let playbackURL = try await PluginMediaProxy.shared.register(
            manifest: manifest, runtime: runtime, executor: executor.handle
        )
        let (masterData, masterResponse) = try await URLSession.shared.data(from: playbackURL)
        XCTAssertEqual((masterResponse as? HTTPURLResponse)?.statusCode, 200)
        let master = String(decoding: masterData, as: UTF8.self)
        XCTAssertTrue(master.contains("#EXT-X-STREAM-INF"))
        XCTAssertTrue(master.contains("audio.m3u8"))

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
        player.isMuted = true
        player.play()
        defer { player.pause() }
        for _ in 0..<150 where player.currentTime().seconds < 0.05 {
            if item.status == .failed { throw item.error ?? PluginError.execution("AVPlayer rejected generated playback") }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(player.currentTime().seconds, 0.05, "Generated playback did not advance")
        await player.seek(to: CMTime(seconds: 5, preferredTimescale: 600))
        for _ in 0..<150 where player.currentTime().seconds < 5.25 {
            if item.status == .failed { throw item.error ?? PluginError.execution("AVPlayer rejected generated seek") }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(player.currentTime().seconds, 5.25, "Generated playback did not resume after seeking")
        #endif
    }

    private func makeRuntime() throws -> PluginRuntime {
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
        if ProcessInfo.processInfo.environment["HUMMINGBIRD_PLUGIN_VERBOSE"] == "1" {
            runtime.onLog = { message in
                if message.hasPrefix("UMP:") || message.hasPrefix("Generating") { print("[youtube] \(message)") }
            }
            runtime.onToast = { print("[youtube toast] \($0)") }
        }
        return runtime
    }
}
