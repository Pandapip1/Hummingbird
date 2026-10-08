import XCTest

final class PlayerFocusUITests: XCTestCase {
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

    private func playerControlHasFocus(in app: XCUIApplication) -> Bool {
        let labels = Set(["Back 10 seconds", "Play", "Forward 10 seconds", "Exit Full Screen", "Speed"])
        return app.buttons.allElementsBoundByIndex.contains { labels.contains($0.label) && $0.hasFocus }
    }

    private func focusedButton(label: String, in app: XCUIApplication) -> XCUIElement? {
        app.buttons.allElementsBoundByIndex.first { $0.label == label && $0.hasFocus }
    }
}
