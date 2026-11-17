import XCTest

/// Pages stay mounted: switching to another tab and back, or opening the tab
/// overview, must never rebuild a page (which would lose its state).
final class TabPageIdentityUITests: XCTestCase {
    @MainActor
    func testSearchPageSurvivesTabSwitchesAndTheOverview() throws {
        let app = IsolatedApp.launch()
        openNewTab(named: "Search", in: app)
        let marker = app.descendants(matching: .any)["page-instance.search"]
        XCTAssertTrue(marker.waitForExistence(timeout: 20))
        let instance = marker.label

        openNewTab(named: "Library", in: app)
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20))

        let tabs = app.buttons["Tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        tabs.tap()
        let searchCard = app.buttons["Open Search"]
        XCTAssertTrue(searchCard.waitForExistence(timeout: 10))
        searchCard.tap()

        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        XCTAssertEqual(marker.label, instance, "the Search page was rebuilt")
    }

    @MainActor
    private func openNewTab(named section: String, in app: XCTest.XCUIApplication) {
        let menu = app.buttons["Open section in new tab"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        let action = app.buttons[section].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }
}
