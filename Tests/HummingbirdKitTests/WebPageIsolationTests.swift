#if canImport(WebKit) && !BACKEND_GTK && os(macOS)
import SwiftOpenUI
import WebKit
private typealias Page = SwiftOpenUI.WebPage
#elseif BACKEND_GTK_WEBKIT
import WebKit
private typealias Page = WebKit.WebPage
#endif
#if (canImport(WebKit) && !BACKEND_GTK && os(macOS)) || BACKEND_GTK_WEBKIT
import XCTest

/// Every web page is isolated: by default a SwiftOpenUI page gets its own
/// non-persistent data store (on GTK, its own ephemeral network session), so
/// it shares no cookies, storage or cache with other pages and keeps nothing.
@MainActor
final class WebPageIsolationTests: XCTestCase {
    func testPagesDefaultToTheirOwnNonPersistentStores() {
        let first = Page()
        let second = Page()
        XCTAssertFalse(first.websiteDataStore.isPersistent)
        XCTAssertFalse(second.websiteDataStore.isPersistent)
        XCTAssertFalse(first.websiteDataStore === second.websiteDataStore)
    }

    func testPersistenceIsAnExplicitOptIn() {
        var configuration = Page.Configuration()
        configuration.websiteDataStore = .default()
        XCTAssertTrue(Page(configuration: configuration).websiteDataStore.isPersistent)
    }
}
#endif
