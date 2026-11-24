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
        let app = IsolatedApp.make(scene: .playerWebMDash)
        app.launchEnvironment["HUMMINGBIRD_DEBUG_WEBM_DASH_DIR"] = fixture
        IsolatedApp.start(app)
        let state = app.staticTexts["debug-playback-state"]
        let time = app.staticTexts["debug-playback-time"]
        XCTAssertTrue(state.waitForExistence(timeout: 60))
        // It plays, or, where the system has no VP9 decoder (the simulator,
        // older devices), it says so by name. Never a silent pause.
        let cannotPlay = "error: This device can't play VP9 video"
        XCTAssertTrue(waitUntil(60) { state.label == "playing" || state.label.hasPrefix(cannotPlay) },
                      "plays, or names what it cannot decode (state: \(state.label))")
        if state.label.hasPrefix(cannotPlay) {
            let note = XCTAttachment(string: "No VP9 decoder here: \(state.label)")
            note.lifetime = .keepAlways
            add(note)
            return
        }
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
