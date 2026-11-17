import Foundation
import XCTest
@testable import HummingbirdKit

/// ⌘⇧T (Reopen Closed Tab) brings closed tabs back, last closed first, where
/// they were and with their history.
@MainActor
final class ReopenClosedTabTests: XCTestCase {
    func testReopensTheLastClosedTabWhereItWasWithItsHistory() {
        let model = makeTestAppModel()
        model.openInNewTab(.library, title: "Library")
        model.activeTab.push(.sources, title: "Sources")
        let library = model.activeTabID
        model.openInNewTab(.settings, title: "Settings")
        let settings = model.activeTabID
        XCTAssertTrue(model.closedTabs.isEmpty)

        model.closeTab(library)
        model.closeTab(settings)
        XCTAssertEqual(model.closedTabs.count, 2)

        model.reopenClosedTab()
        XCTAssertEqual(model.activeTab.current, .settings)

        model.reopenClosedTab()
        XCTAssertEqual(model.activeTab.current, .sources)
        XCTAssertEqual(model.activeTab.history, [.library, .sources])
        XCTAssertTrue(model.activeTab.canGoBack)
        XCTAssertEqual(model.contentTabs.firstIndex { $0.id == model.activeTabID }, 1,
                       "the tab returns to where it was")
        XCTAssertTrue(model.closedTabs.isEmpty)

        // Nothing left to reopen: nothing happens.
        let tabs = model.contentTabs.map(\.id)
        model.reopenClosedTab()
        XCTAssertEqual(model.contentTabs.map(\.id), tabs)
    }
}
