import XCTest

final class PlayerFocusUITests: XCTestCase {
    @MainActor
    func testNewTabMenuOpensFromToolbar() throws {
        let app = XCUIApplication()
        app.launch()

        let newTab = app.buttons["Open section in new tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.up)
        for _ in 0..<4 where !newTab.hasFocus {
            XCUIRemote.shared.press(.right)
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
        let app = XCUIApplication()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_SCENE"] = "player"
        app.launch()

        let enterFullscreen = app.buttons["Enter Full Screen"]
        XCTAssertTrue(enterFullscreen.waitForExistence(timeout: 5))

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
        XCTAssertNotNil(focusedButton(label: "Play", in: app))
        XCUIRemote.shared.press(.right)
        XCTAssertNotNil(focusedButton(label: "Forward 10 seconds", in: app))

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(playerControlHasFocus(in: app), "Down must not move focus into AVKit's container")

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(exitFullscreen.waitForNonExistence(timeout: 5), "Back/Menu must dismiss fullscreen")
    }

    @MainActor
    func testRemoteSeekControlAdjustsThenReleasesNavigation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_SCENE"] = "player-seek"
        app.launch()

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
        let app = XCUIApplication()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_SCENE"] = "player-seek"
        app.launch()

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
        let app = XCUIApplication()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_SCENE"] = "install-preview"
        app.launch()

        let firstURL = app.buttons["https://audit-0.example.com/path"]
        XCTAssertTrue(firstURL.waitForExistence(timeout: 5))
        let lastURL = app.buttons["https://audit-29.example.com/path"]
        for _ in 0..<50 where !lastURL.isHittable {
            XCUIRemote.shared.press(.down)
            Thread.sleep(forTimeInterval: 0.08)
        }
        XCTAssertTrue(lastURL.exists && lastURL.isHittable,
                      "Every allowed URL must be reachable by moving focus through the preview")
    }

    private func playerControlHasFocus(in app: XCUIApplication) -> Bool {
        let labels = Set(["Back 10 seconds", "Play", "Forward 10 seconds", "Exit Full Screen", "Speed"])
        return app.buttons.allElementsBoundByIndex.contains { labels.contains($0.label) && $0.hasFocus }
    }

    private func focusedButton(label: String, in app: XCUIApplication) -> XCUIElement? {
        app.buttons.allElementsBoundByIndex.first { $0.label == label && $0.hasFocus }
    }
}
