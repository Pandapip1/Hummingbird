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
        assertTouchTargets(app, "inline")

        reveal(app)
        let enter = app.buttons["Enter Full Screen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        XCTAssertTrue(tapWhenShown(app, enter) { app.buttons["Exit Full Screen"].exists }, "full screen opens")
        XCTAssertTrue(app.buttons["Exit Full Screen"].waitForExistence(timeout: 10) || revealAndFind(app, "Exit Full Screen"))
        assertOneSurface(app, "full screen")
        assertTouchTargets(app, "full screen")

        let exit = app.buttons["Exit Full Screen"]
        // Hidden controls stay in the accessibility tree (reachable by name) but
        // take no touches: tap only once they are shown.
        XCTAssertTrue(tapWhenShown(app, exit) { !app.buttons["Exit Full Screen"].exists }, "full screen closes")
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

    /// Screenshots of the glass controls over a white and a black frame, inline
    /// and full screen (kept as attachments for review).
    @MainActor
    func testControlsOverLightAndDarkFrames() throws {
        for (shade, name) in [(255, "white"), (0, "black")] {
            let app = IsolatedApp.make()
            app.launchEnvironment["HUMMINGBIRD_DEBUG_SCENE"] = "player-fullscreen"
            app.launchEnvironment["HUMMINGBIRD_DEBUG_CLIP_SHADE"] = String(shade)
            app.launch()
            let state = app.staticTexts["debug-playback-state"]
            XCTAssertTrue(state.waitForExistence(timeout: 60))
            XCTAssertTrue(waitUntil(60) { state.label == "playing" })
            reveal(app)
            attach(app, "controls-inline-over-\(name)")
            let enter = app.buttons["Enter Full Screen"]
            XCTAssertTrue(enter.waitForExistence(timeout: 5))
            XCTAssertTrue(tapWhenShown(app, enter) { app.buttons["Exit Full Screen"].exists }, "full screen opened over \(name)")
            Thread.sleep(forTimeInterval: 1)
            reveal(app)
            attach(app, "controls-fullscreen-over-\(name)")
            app.terminate()
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Every player control takes touches over at least 44 × 44 pt, its glass
    /// included (the UI audit found icons whose glass took no touches).
    @MainActor
    private func assertTouchTargets(_ app: XCUIApplication, _ step: String) {
        reveal(app)
        let names = ["Back 10 seconds", "Play", "Pause", "Forward 10 seconds", "Picture in Picture",
                     "Exit Picture in Picture", "Enter Full Screen", "Exit Full Screen", "Speed"]
        var checked = 0
        for name in names {
            let button = app.buttons[name]
            guard button.exists else { continue }
            checked += 1
            let frame = button.frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(step): \(name) is \(frame.width) pt wide")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(step): \(name) is \(frame.height) pt tall")
        }
        XCTAssertGreaterThanOrEqual(checked, 4, "\(step): the player's controls are there to check")
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
        // On the player itself (its upper part, clear of the controls): a tap
        // elsewhere on the screen does not show them.
        let surface = app.descendants(matching: .any).matching(identifier: "player-surface").firstMatch
        if surface.exists {
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// Taps `button` once it takes touches: hidden controls stay in the
    /// accessibility tree (for VoiceOver) but a synthesized touch on one lands
    /// on the video and only toggles the controls.
    @MainActor
    private func tapWhenShown(_ app: XCUIApplication, _ button: XCUIElement, until done: () -> Bool) -> Bool {
        // The controls hide again after a few seconds: reveal, then tap at once.
        for _ in 0..<4 {
            guard button.exists else { return done() }
            // Hidden controls still report themselves hittable: always reveal.
            reveal(app)
            button.tap()
            if waitUntil(4, done) { return true }
        }
        return false
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
