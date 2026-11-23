import XCTest

final class RenderStallExerciseUITests: XCTestCase {
    private let pluginURL = "https://plugins.grayjay.app/Youtube/YoutubeConfig.json"

    /// Installs the real YouTube plugin and browses live content, so it needs
    /// the network and YouTube being reachable: opt-in, like the other live
    /// tests, so an outage can't block merges. Run it with
    ///     TEST_RUNNER_HUMMINGBIRD_UI_NETWORK_TESTS=1 xcodebuild test … \
    ///       -only-testing:HummingbirdIOSUITests/RenderStallExerciseUITests
    @MainActor
    func testRepeatedColdLaunchInteractionPaths() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HUMMINGBIRD_UI_NETWORK_TESTS"] == "1",
            "live-network UI test; set TEST_RUNNER_HUMMINGBIRD_UI_NETWORK_TESTS=1"
        )
        let app = IsolatedApp.make()
        IsolatedApp.start(app)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        try installYouTubeIfNeeded(in: app)

        for iteration in 0..<12 {
            if iteration > 0 {
                // A cold launch of the same instance keeps its isolated data
                // (and the source installed above).
                app.terminate()
                IsolatedApp.start(app)
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
            }

            openNewTab(named: "Home", in: app)
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 15))
            exerciseScrolling(in: app)
            if iteration.isMultiple(of: 3) {
                openFirstVideoCard(in: app)
                _ = app.buttons["Show playback controls"].waitForExistence(timeout: 15)
            }
            openNewTab(named: iteration.isMultiple(of: 2) ? "Subscriptions" : "Library", in: app)
        }
    }

    @MainActor
    private func installYouTubeIfNeeded(in app: XCUIApplication) throws {
        openNewTab(named: "Sources", in: app)
        if app.staticTexts["YouTube"].waitForExistence(timeout: 2) { return }

        let add = app.buttons["Add source"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let field = app.textFields["https://…/Config.json"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(pluginURL)
        app.buttons["Continue"].tap()

        let install = app.buttons["Install"]
        let installAnyway = app.buttons["Install anyway"]
        XCTAssertTrue(install.waitForExistence(timeout: 30) || installAnyway.waitForExistence(timeout: 1))
        (install.exists ? install : installAnyway).tap()
        _ = app.descendants(matching: .any)["YouTube"].waitForExistence(timeout: 10)
    }

    @MainActor
    private func exerciseScrolling(in app: XCUIApplication) {
        for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        for _ in 0..<2 { app.swipeDown(velocity: .fast) }
    }

    @MainActor
    private func openNewTab(named section: String, in app: XCUIApplication) {
        guard let menu = hittableButton("Open section in new tab", in: app, timeout: 10) else {
            XCTFail("Missing hittable new-tab menu")
            return
        }
        menu.tap()
        guard let action = hittableButton(section, in: app, timeout: 5) else {
            XCTFail("Missing new-tab action \(section)")
            return
        }
        action.tap()
    }

    @MainActor
    private func hittableButton(_ label: String, in app: XCUIApplication,
                                timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = app.buttons.matching(identifier: label).allElementsBoundByIndex.first(where: \.isHittable) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    @MainActor
    private func openFirstVideoCard(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            if let card = app.buttons.allElementsBoundByIndex.first(where: {
                $0.isHittable && $0.frame.height > 80 && !$0.label.isEmpty
            }) {
                card.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTFail("Home did not expose a hittable video card")
    }
}
