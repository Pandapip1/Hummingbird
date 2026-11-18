#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import BrowserTabs

/// The macOS tab strip is one titlebar accessory per window, however many
/// views ask for it, sized to the window and removed while hidden.
final class WindowTabStripAccessoryTests: XCTestCase {
    @MainActor
    private func makeWindow(width: CGFloat, height: CGFloat) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    @MainActor
    private var strip: AnyView { AnyView(Text("Tabs")) }

    @MainActor
    func testManagerInstallsOneAccessoryAndRetainsItUntilLastOwnerDetaches() {
        let window = makeWindow(width: 900, height: 600)
        let manager = WindowTabStripAccessoryManager(window: window, content: strip)
        let first = UUID()
        let second = UUID()

        manager.attach(owner: first, content: strip)
        manager.attach(owner: second, content: strip)

        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertEqual(window.titlebarAccessoryViewControllers[0].layoutAttribute, .bottom)
        XCTAssertEqual(window.titlebarAccessoryViewControllers[0].view.frame.height,
                       WindowTabStripAccessoryManager.height)

        manager.detach(owner: first)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        manager.detach(owner: second)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertTrue(manager.isUnused)
    }

    @MainActor
    func testReconcileUpdatesAccessoryWidthWithoutDuplicatingIt() {
        let window = makeWindow(width: 700, height: 500)
        let manager = WindowTabStripAccessoryManager(window: window, content: strip)
        let owner = UUID()
        manager.attach(owner: owner, content: strip)
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
        let window = makeWindow(width: 700, height: 500)
        let manager = WindowTabStripAccessoryManager(window: window, content: strip)
        let owner = UUID()

        manager.attach(owner: owner, content: strip)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)

        manager.attach(owner: owner, content: strip, isHidden: true)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)

        manager.attach(owner: owner, content: strip, isHidden: false)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        manager.detach(owner: owner)
    }
}
#endif
