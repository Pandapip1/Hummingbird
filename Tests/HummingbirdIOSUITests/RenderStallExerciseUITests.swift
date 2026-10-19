import XCTest

final class RenderStallExerciseUITests: XCTestCase {
    private let pluginURL = "https://plugins.grayjay.app/Youtube/YoutubeConfig.json"

    @MainActor
    func testRepeatedColdLaunchInteractionPaths() throws {
        var app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        try installYouTubeIfNeeded(in: app)

        for iteration in 0..<12 {
            if iteration > 0 {
                app.terminate()
                app = XCUIApplication()
                app.launch()
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

        let add = app.buttons["Add"]
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
