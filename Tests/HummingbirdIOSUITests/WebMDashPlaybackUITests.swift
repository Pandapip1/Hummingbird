import XCTest

/// A plugin-generated WebM DASH source (VP9 and Opus, Tests/Fixtures/webm-dash)
/// plays in the real player: the media proxy remuxes each segment to
/// fragmented MP4 as AVPlayer asks for it.
final class WebMDashPlaybackUITests: XCTestCase {
    @MainActor
    func testGeneratedWebMPlaysThroughTheProxy() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/webm-dash").path
        let app = IsolatedApp.make()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_SCENE"] = "player-webm-dash"
        app.launchEnvironment["HUMMINGBIRD_DEBUG_WEBM_DASH_DIR"] = fixture
        app.launch()
        let state = app.staticTexts["debug-playback-state"]
        let time = app.staticTexts["debug-playback-time"]
        XCTAssertTrue(state.waitForExistence(timeout: 60))
        // "playing", or what failed ("error: …" names an undecodable format).
        XCTAssertTrue(waitUntil(60) { state.label == "playing" || state.label.hasPrefix("error") || state.label.hasPrefix("failed") },
                      "settled (state: \(state.label))")
        XCTAssertEqual(state.label, "playing")
        XCTAssertTrue(waitUntil(10) { (Int(time.label) ?? 0) >= 2 }, "the clock advances (time: \(time.label))")
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }
}
