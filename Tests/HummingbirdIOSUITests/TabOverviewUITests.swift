import XCTest

/// The tab overview's card gestures: a sideways swipe closes a tab, a
/// long-press drag reorders, and neither opens the tab.
final class TabOverviewUITests: XCTestCase {
    @MainActor
    func testSwipingACardClosesItsTab() throws {
        let app = IsolatedApp.launch()
        for section in ["Library", "Sources", "Settings"] { openNewTab(named: section, in: app) }

        openOverview(in: app)
        let before = titles(in: app)
        XCTAssertGreaterThanOrEqual(before.count, 3, "\(before)")

        // A quick flick, as most people close tabs.
        card("Open Sources", in: app).swipeLeft(velocity: .fast)
        let afterFlick = waitForChange(before, in: app)
        XCTAssertEqual(afterFlick.count, before.count - 1, "a fast swipe closed nothing: \(afterFlick)")
        XCTAssertFalse(afterFlick.contains("Open Sources"))
        XCTAssertTrue(app.buttons["Done"].exists, "the swipe opened a tab instead of staying in the overview")

        // A slow drag past the threshold, as when pulling a card off by hand.
        let settings = card("Open Settings", in: app)
        let start = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -settings.frame.width, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0)
        let afterDrag = waitForChange(afterFlick, in: app)
        XCTAssertEqual(afterDrag.count, afterFlick.count - 1, "a slow swipe closed nothing: \(afterDrag)")
        XCTAssertTrue(app.buttons["Done"].exists)

        // The last card in the grid, after the others moved up.
        let last = afterDrag.last ?? ""
        card(last, in: app).swipeLeft(velocity: .fast)
        let afterLast = waitForChange(afterDrag, in: app)
        XCTAssertEqual(afterLast.count, afterDrag.count - 1, "swiping the last card closed nothing: \(afterLast)")
    }

    /// A drag to reorder that is dropped outside the grid changes nothing and
    /// leaves the cards working: a swipe afterwards still closes a tab.
    @MainActor
    func testSwipeClosesAfterACancelledDrag() throws {
        let app = IsolatedApp.launch()
        for section in ["Library", "Sources"] { openNewTab(named: section, in: app) }
        openOverview(in: app)
        let before = titles(in: app)

        card("Open Library", in: app).press(forDuration: 1.0, thenDragTo: app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH ' Tabs'")).firstMatch)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(titles(in: app), before, "a cancelled drag moved a tab")

        card("Open Sources", in: app).swipeLeft(velocity: .fast)
        let after = waitForChange(before, in: app)
        XCTAssertEqual(after.count, before.count - 1, "a swipe after a cancelled drag closed nothing: \(after)")
    }

    @MainActor
    func testCardCloseButtonClosesItsTab() throws {
        let app = IsolatedApp.launch()
        openNewTab(named: "Library", in: app)
        openOverview(in: app)
        let before = titles(in: app)
        let close = app.buttons["Close Library"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let after = waitForChange(before, in: app)
        XCTAssertEqual(after.count, before.count - 1, "\(after)")
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    /// The card swipe must not swallow taps: tapping a card still opens it.
    @MainActor
    func testTappingACardOpensItsTab() throws {
        let app = IsolatedApp.launch()
        for section in ["Library", "Sources"] { openNewTab(named: section, in: app) }
        openOverview(in: app)
        let before = titles(in: app)
        card("Open Library", in: app).tap()
        let done = app.buttons["Done"]
        let deadline = Date().addingTimeInterval(5)
        while done.exists && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertFalse(done.exists, "tapping a card didn't leave the overview")
        openOverview(in: app)
        XCTAssertEqual(titles(in: app).count, before.count, "tapping a card closed or added a tab")
    }

    @MainActor private func openOverview(in app: XCUIApplication) {
        let tabs = app.buttons["Tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        tabs.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        // Let the zoom into the overview finish.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor private func card(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let card = app.buttons[label].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no card \(label): \(titles(in: app))")
        return card
    }

    @MainActor private func titles(in app: XCUIApplication) -> [String] {
        // The cards only, not other "Open …" buttons such as the new-tab menu.
        app.buttons.matching(identifier: "browser-tab-overview-card").allElementsBoundByIndex
            .map { ($0.frame, $0.label) }
            .sorted { ($0.0.minY, $0.0.minX) < ($1.0.minY, $1.0.minX) }
            .map(\.1)
    }

    @MainActor private func waitForChange(_ previous: [String], in app: XCUIApplication) -> [String] {
        let deadline = Date().addingTimeInterval(5)
        var current = titles(in: app)
        while current == previous && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            current = titles(in: app)
        }
        return current
    }

    @MainActor private func openNewTab(named section: String, in app: XCUIApplication) {
        let menu = app.buttons["Open section in new tab"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 60))
        menu.tap()
        let action = app.buttons[section].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }
}
