#if os(macOS) && canImport(SwiftUI)
import AppKit
import XCTest
@testable import HummingbirdKit

final class MacTabBarAccessoryTests: XCTestCase {
    @MainActor
    func testManagerInstallsOneAccessoryAndRetainsItUntilLastOwnerDetaches() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let manager = WindowTabBarAccessoryManager(window: window, app: makeTestAppModel())
        let first = UUID()
        let second = UUID()

        manager.attach(owner: first, app: makeTestAppModel())
        manager.attach(owner: second, app: makeTestAppModel())

        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertEqual(window.titlebarAccessoryViewControllers[0].layoutAttribute, .bottom)
        XCTAssertEqual(window.titlebarAccessoryViewControllers[0].view.frame.height,
                       WindowTabBarAccessoryManager.height)

        manager.detach(owner: first)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        manager.detach(owner: second)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertTrue(manager.isUnused)
    }

    @MainActor
    func testReconcileUpdatesAccessoryWidthWithoutDuplicatingIt() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let manager = WindowTabBarAccessoryManager(window: window, app: makeTestAppModel())
        let owner = UUID()
        manager.attach(owner: owner, app: makeTestAppModel())
        let original = window.titlebarAccessoryViewControllers[0]

        window.setContentSize(NSSize(width: 1_000, height: 700))
        manager.reconcile()
        manager.reconcile()

        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertTrue(window.titlebarAccessoryViewControllers[0] === original)
        XCTAssertEqual(original.view.frame.width, window.contentLayoutRect.width, accuracy: 1)
        manager.detach(owner: owner)
    }

    @MainActor
    func testHiddenOwnerRemovesAccessoryAndShowingItRestoresAccessory() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let app = makeTestAppModel()
        let manager = WindowTabBarAccessoryManager(window: window, app: app)
        let owner = UUID()

        manager.attach(owner: owner, app: app)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)

        manager.attach(owner: owner, app: app, isHidden: true)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)

        manager.attach(owner: owner, app: app, isHidden: false)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        manager.detach(owner: owner)
    }
}
#endif
