import XCTest
@testable import HummingbirdKit

/// The debug source exists to give playback a fixed input. If it drifts out of
/// step with the plugin API these fail here rather than in the app.
final class DebugPluginTests: XCTestCase {
    private func loadDebugPlugin() throws -> (PluginConfig, String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HummingbirdKitTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("debug-plugin")
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(contentsOf: root.appendingPathComponent("DebugPlugin.json")))
        let script = try String(contentsOf: root.appendingPathComponent("DebugPlugin.js"), encoding: .utf8)
        return (config, script)
    }

    func testDebugPluginProvidesEveryRequiredEntryPoint() async throws {
        let (config, script) = try loadDebugPlugin()
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        // validate() is what the installer runs; it throws if an entry point is missing.
        try await runtime.validate()
        await runtime.stop()
    }

    func testDebugPluginHomeReturnsOnePlayableVideo() async throws {
        let (config, script) = try loadDebugPlugin()
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        try await runtime.enable()
        let pager = try await runtime.pager("getHome", as: ContentItem.self)
        await runtime.stop()

        XCTAssertEqual(pager.initial.count, 1, "the debug source should offer exactly one video")
        let item = try XCTUnwrap(pager.initial.first)
        XCTAssertFalse(item.url.isEmpty, "the video needs a details URL")
        XCTAssertEqual(item.duration, 10, "the fixed fixture should remain a ten-second video")
        XCTAssertEqual(item.thumbnailURL?.absoluteString, "http://127.0.0.1:8742/thumbnail.svg")
    }
}
