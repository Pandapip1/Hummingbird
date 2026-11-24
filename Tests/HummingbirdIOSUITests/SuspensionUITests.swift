import XCTest

/// "Resume from suspend on iOS seems to cause videos to fail." iOS closes a
/// suspended app's listening sockets and their connections and fails its
/// URL tasks; the simulator does not, so a debug launch does it when the app
/// leaves the foreground (`HUMMINGBIRD_DEBUG_RECLAIM_ON_SUSPEND`). Playback
/// must carry on after the app comes back, with no error shown.
final class SuspensionUITests: XCTestCase {
    @MainActor
    func testPlaybackContinuesAfterTheSystemReclaimsSocketsInSuspension() throws {
        let app = IsolatedApp.make(scene: .playerFullscreen)
        app.launchEnvironment["HUMMINGBIRD_DEBUG_RECLAIM_ON_SUSPEND"] = "1"
        IsolatedApp.start(app)
        let state = app.staticTexts["debug-playback-state"]
        let time = app.staticTexts["debug-playback-time"]
        XCTAssertTrue(state.waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntil(60) { state.label == "playing" }, "the clip plays (state: \(state.label))")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(waitUntil(15) { state.label == "playing" }, "playing again after the resume (state: \(state.label))")
        let after = Int(time.label) ?? 0
        XCTAssertTrue(waitUntil(10) { (Int(time.label) ?? 0) >= after + 3 }, "and advancing (time: \(time.label))")
        XCTAssertFalse(state.label.hasPrefix("error"), "no error is shown (state: \(state.label))")
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
