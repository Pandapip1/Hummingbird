import XCTest

/// Entering and leaving full screen hands the one player between surfaces:
/// exactly one surface shows the video at every step (no second copy in the
/// corner), and playback keeps advancing throughout.
final class FullscreenHandoverUITests: XCTestCase {
    @MainActor
    func testFullscreenInAndOutKeepsOneSurfaceAndContinuousPlayback() throws {
        let app = IsolatedApp.make()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_SCENE"] = "player-fullscreen"
        app.launch()
        let state = app.staticTexts["debug-playback-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntil(60) { state.label == "playing" }, "the clip plays (state: \(state.label))")
        assertOneSurface(app, "inline")

        reveal(app)
        let enter = app.buttons["Enter Full Screen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        enter.tap()
        XCTAssertTrue(app.buttons["Exit Full Screen"].waitForExistence(timeout: 10) || revealAndFind(app, "Exit Full Screen"))
        assertOneSurface(app, "full screen")

        let exit = app.buttons["Exit Full Screen"]
        if !exit.isHittable { reveal(app) }
        exit.tap()
        XCTAssertTrue(app.buttons["Enter Full Screen"].waitForExistence(timeout: 10) || revealAndFind(app, "Enter Full Screen"))
        assertOneSurface(app, "after leaving full screen")

        // Playback continued across both transitions.
        let time = app.staticTexts["debug-playback-time"]
        let before = Int(time.label) ?? 0
        XCTAssertTrue(waitUntil(10) { (Int(time.label) ?? 0) >= before + 2 }, "playback keeps advancing")
        XCTAssertEqual(state.label, "playing")
    }

    /// Home, then back: a playing video keeps playing (no pause, no jump back)
    /// and one surface shows it again.
    @MainActor
    func testBackgroundAndReturnKeepsPlaying() throws {
        let app = IsolatedApp.make()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_SCENE"] = "player-fullscreen"
        app.launch()
        let state = app.staticTexts["debug-playback-state"]
        let time = app.staticTexts["debug-playback-time"]
        XCTAssertTrue(state.waitForExistence(timeout: 60))
        XCTAssertTrue(waitUntil(60) { state.label == "playing" })
        let before = Int(time.label) ?? 0

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(waitUntil(10) { state.label == "playing" }, "still playing after returning (state: \(state.label))")
        let after = Int(time.label) ?? 0
        XCTAssertGreaterThanOrEqual(after, before + 4, "it kept playing in the background, no jump back")
        XCTAssertTrue(waitUntil(10) { (Int(time.label) ?? 0) >= after + 2 }, "and keeps advancing")
        assertOneSurface(app, "after returning")
    }

    @MainActor
    private func assertOneSurface(_ app: XCUIApplication, _ step: String) {
        // Let the transition settle, then count at several moments.
        for _ in 0..<5 {
            let count = app.descendants(matching: .any).matching(identifier: "player-surface").count
            XCTAssertEqual(count, 1, "\(step): exactly one surface shows the player")
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    @MainActor
    private func reveal(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    }

    @MainActor
    private func revealAndFind(_ app: XCUIApplication, _ label: String) -> Bool {
        reveal(app)
        return app.buttons[label].waitForExistence(timeout: 5)
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
