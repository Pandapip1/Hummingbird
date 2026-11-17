import Foundation
import XCTest
@testable import BrowserTabs

/// The tab strip shares its width like the system's window tabs, scrolls a
/// tab at a time when the tabs overflow, and always shows the selected tab
/// whole.
final class BrowserTabStripLayoutTests: XCTestCase {
    private let minimum = BrowserTabStripLayout.minimumTabWidth

    func testTabsShareTheWidthWhileTheyFit() {
        let layout = BrowserTabStripLayout(count: 4, width: 800, first: 3)
        XCTAssertFalse(layout.isOverflowing)
        XCTAssertEqual(layout.first, 0)
        XCTAssertEqual(layout.slot(of: 3), .tab(x: 600, width: 200))
    }

    func testOverflowingTabsKeepTheirMinimumWidthAndScrolledOffTabsAreSlivers() {
        let layout = BrowserTabStripLayout(count: 20, width: 800, first: 5)
        XCTAssertTrue(layout.isOverflowing)
        XCTAssertGreaterThanOrEqual(layout.tabWidth, minimum)
        let edge = BrowserTabStripLayout.edgeWidth
        XCTAssertLessThanOrEqual(edge * 2 + CGFloat(layout.shown) * layout.tabWidth, 800 + 0.001,
                                 "whole tabs and slivers fit the strip")
        guard case .sliver = layout.slot(of: 4), case .sliver = layout.slot(of: 0),
              case .tab = layout.slot(of: 5), case .sliver = layout.slot(of: 5 + layout.shown) else {
            return XCTFail("tabs before the first whole one and after the last are slivers")
        }
        // Slivers never go past the strip.
        guard case .sliver(let last) = layout.slot(of: 19) else { return XCTFail() }
        XCTAssertLessThanOrEqual(last + BrowserTabStripLayout.sliverWidth, 800 + 0.001)
    }

    func testScrollingStopsAtTheEnds() {
        let layout = BrowserTabStripLayout(count: 20, width: 800, first: 100)
        XCTAssertEqual(layout.first, 20 - layout.shown)
        XCTAssertEqual(BrowserTabStripLayout(count: 20, width: 800, first: -3).first, 0)
    }

    /// The selected tab is scrolled into view, moving as little as possible:
    /// on selecting it (a click, ⌘1–9, ⌃Tab) or opening it (a new tab, last).
    func testRevealingTheSelectedTabScrollsItIntoView() {
        let layout = BrowserTabStripLayout(count: 20, width: 800, first: 5)
        for index in 0..<20 {
            let revealed = BrowserTabStripLayout(count: 20, width: 800, first: layout.first(revealing: index))
            guard case .tab = revealed.slot(of: index) else {
                return XCTFail("tab \(index) isn't whole after revealing it")
            }
        }
        XCTAssertEqual(layout.first(revealing: 6), 5, "a whole tab doesn't scroll the strip")
        XCTAssertEqual(layout.first(revealing: 2), 2)
        XCTAssertEqual(layout.first(revealing: 19), 20 - layout.shown, "a new last tab scrolls to the end")
    }
}
