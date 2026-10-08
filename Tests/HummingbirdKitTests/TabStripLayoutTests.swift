import XCTest
@testable import HummingbirdKit

final class TabStripLayoutTests: XCTestCase {
    func testTabsShareWidthInsideStripInsets() {
        let width = TabStripLayout.tabWidth(availableWidth: 612, tabCount: 3)

        XCTAssertEqual(width, 200)
        XCTAssertEqual(width * 3 + TabStripLayout.horizontalInsets, 612)
    }

    func testTabsKeepMinimumWidthWhenStripMustScroll() {
        let width = TabStripLayout.tabWidth(availableWidth: 320, tabCount: 4)

        XCTAssertEqual(width, 100)
        XCTAssertGreaterThan(width * 4 + TabStripLayout.horizontalInsets, 320)
    }

    func testTabsShareThePrincipalRowsHeightInsideStripInsets() {
        XCTAssertEqual(TabStripLayout.tabHeight(availableHeight: 34), 24)
        XCTAssertEqual(TabStripLayout.tabHeight(availableHeight: 28), 18)
    }
}
