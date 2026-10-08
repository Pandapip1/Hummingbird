import Foundation
import XCTest
@testable import HummingbirdKit

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
            runtime.onLog = { if !$0.hasPrefix("batchResp ") { print("[youtube] \($0)") } }
            runtime.onToast = { print("[youtube toast] \($0)") }
        }
        return runtime
    }
}
