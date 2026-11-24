import XCTest

final class PlayerFocusUITests: XCTestCase {
    @MainActor
    func testNewTabMenuOpensFromToolbar() throws {
        let app = IsolatedApp.make()
        IsolatedApp.start(app)

        let newTab = app.buttons["Open section in new tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 10))
        // The tab bar is the top row, above the page's own toolbar; the
        // new-tab menu sits left of the tab overview button at its end.
        for _ in 0..<3 { XCUIRemote.shared.press(.up) }
        for _ in 0..<4 where !newTab.hasFocus {
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        let focusedButtons = app.buttons.allElementsBoundByIndex
            .filter(\.hasFocus).map { $0.label }
        XCTAssertTrue(newTab.hasFocus,
                      "the toolbar new-tab menu must be focusable; focused buttons: \(focusedButtons)")
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["Search"].waitForExistence(timeout: 5),
                      "selecting the new-tab menu must present its section actions")
    }

    @MainActor
    func testFullscreenKeepsFocusAndCanExit() throws {
        let app = IsolatedApp.make(scene: .playerFullscreen)
        IsolatedApp.start(app)

        let enterFullscreen = app.buttons["Enter Full Screen"]
        // The controls are enabled once the clip is ready.
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: enterFullscreen)
        waitForExpectations(timeout: 15)

        // Focus starts on the seek bar; the transport row is below it.
        XCUIRemote.shared.press(.down)
        for _ in 0..<8 where !enterFullscreen.hasFocus {
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(enterFullscreen.hasFocus)
        XCUIRemote.shared.press(.select)

        let exitFullscreen = app.buttons["Exit Full Screen"]
        XCTAssertTrue(exitFullscreen.waitForExistence(timeout: 5))
        XCTAssertTrue(playerControlHasFocus(in: app))

        XCUIRemote.shared.press(.left)
        XCTAssertNotNil(focusedButton(label: "Back 10 seconds", in: app))
        XCUIRemote.shared.press(.right)
        // The clip plays, so the button reads Pause.
        XCTAssertNotNil(focusedButton(label: "Pause", in: app))
        XCUIRemote.shared.press(.right)
        XCTAssertNotNil(focusedButton(label: "Forward 10 seconds", in: app))

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(playerControlHasFocus(in: app), "Down must not move focus into AVKit's container")

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(exitFullscreen.waitForNonExistence(timeout: 5), "Back/Menu must dismiss fullscreen")
    }

    @MainActor
    func testRemoteSeekControlAdjustsThenReleasesNavigation() throws {
        let app = IsolatedApp.make(scene: .playerSeek)
        IsolatedApp.start(app)

        let slider = app.descendants(matching: .any)["playback-seek-control"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        for _ in 0..<8 where !slider.hasFocus { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(slider.hasFocus)

        let initialValue = slider.value as? String
        XCUIRemote.shared.press(.select)
        expectation(for: NSPredicate(format: "value CONTAINS 'adjusting'"), evaluatedWith: slider)
        waitForExpectations(timeout: 2)
        XCUIRemote.shared.press(.right)
        expectation(for: NSPredicate(format: "value != %@", initialValue ?? ""), evaluatedWith: slider)
        waitForExpectations(timeout: 2)

        XCUIRemote.shared.press(.menu)
        expectation(for: NSPredicate(format: "value == %@", initialValue ?? ""), evaluatedWith: slider)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(slider.hasFocus, "Back must cancel adjustment without leaving the player")

        XCUIRemote.shared.press(.select)
        expectation(for: NSPredicate(format: "value CONTAINS 'adjusting'"), evaluatedWith: slider)
        waitForExpectations(timeout: 2)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.down)
        XCTAssertFalse(slider.hasFocus, "Select must leave adjustment mode so directional focus navigation resumes")
    }

    @MainActor
    func testPlaybackMenuSurvivesControlsAutoHideDeadline() throws {
        let app = IsolatedApp.make(scene: .playerSeek)
        IsolatedApp.start(app)

        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.down)
        for _ in 0..<4 where !play.hasFocus {
            XCUIRemote.shared.press(.left)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(play.hasFocus)
        XCUIRemote.shared.press(.select)

        for _ in 0..<3 {
            XCUIRemote.shared.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCUIRemote.shared.press(.select)
        let normal = app.descendants(matching: .any)["Normal"]
        XCTAssertTrue(normal.waitForExistence(timeout: 2))
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertTrue(normal.exists, "an open player menu must outlive the controls auto-hide deadline")
    }

    @MainActor
    func testInstallPreviewCanFocusLastAllowedURL() throws {
        let app = IsolatedApp.make(scene: .installPreview)
        IsolatedApp.start(app)

        // Read-only values: focusable text, not buttons.
        let firstURL = app.staticTexts[UITestIdentifier.installPreviewURL(0)]
        XCTAssertTrue(firstURL.waitForExistence(timeout: 5))
        let lastURL = app.staticTexts[UITestIdentifier.installPreviewURL(29)]
        for _ in 0..<50 where !lastURL.hasFocus {
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 0.08)
        }
        XCTAssertTrue(lastURL.hasFocus && lastURL.isHittable,
                      "Every allowed URL must be reachable by moving focus through the preview")
    }

    @MainActor
    private func playerControlHasFocus(in app: XCUIApplication) -> Bool {
        let labels = Set(["Back 10 seconds", "Play", "Pause", "Forward 10 seconds", "Exit Full Screen", "Speed"])
        return app.buttons.allElementsBoundByIndex.contains { labels.contains($0.label) && $0.hasFocus }
    }

    @MainActor
    private func focusedButton(label: String, in app: XCUIApplication) -> XCUIElement? {
        app.buttons.allElementsBoundByIndex.first { $0.label == label && $0.hasFocus }
    }
}
