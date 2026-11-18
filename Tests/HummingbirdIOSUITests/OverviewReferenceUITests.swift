import XCTest

/// Screenshots of Hummingbird's tab overview next to Safari's, in light and
/// dark mode, portrait and landscape, to keep the two looking the same.
/// Attachments: "safari-<light|dark>-<portrait|landscape>" and the same for
/// "hummingbird-…".
final class OverviewReferenceUITests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    @MainActor
    func testSafariTabOverview() throws {
        for orientation in Self.orientations {
            XCUIDevice.shared.orientation = orientation
            let safari = SystemReferenceApp.safari()
            safari.launch()
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 30))
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            let tabs = safari.buttons.matching(NSPredicate(
                format: "identifier == 'TabOverviewButton' OR label IN {'Tabs', 'Show Tabs', 'Tab Overview'}")).firstMatch
            if tabs.waitForExistence(timeout: 10) { tabs.tap() }
            // Two more tabs, so the grid shows several cards.
            for _ in 0..<2 {
                let add = safari.buttons.matching(NSPredicate(
                    format: "identifier == 'AddTabButton' OR label IN {'New Tab', 'Add Tab', 'Open New Tab'}")).firstMatch
                guard add.waitForExistence(timeout: 5) else { break }
                add.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                if tabs.waitForExistence(timeout: 5) { tabs.tap() }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            attach(safari, "safari-\(Self.name(orientation))")
            safari.terminate()
        }
    }

    @MainActor
    func testHummingbirdTabOverview() throws {
        for orientation in Self.orientations {
            XCUIDevice.shared.orientation = orientation
            let app = IsolatedApp.launch()
            for section in ["Library", "Settings"] {
                let menu = app.buttons["Open section in new tab"].firstMatch
                XCTAssertTrue(menu.waitForExistence(timeout: 90))
                menu.tap()
                let action = app.buttons[section].firstMatch
                XCTAssertTrue(action.waitForExistence(timeout: 5))
                action.tap()
            }
            let tabs = app.buttons["Tabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 15))
            tabs.tap()
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            attach(app, "hummingbird-\(Self.name(orientation))")
            app.terminate()
        }
    }

    private static let orientations: [UIDeviceOrientation] = [.portrait, .landscapeLeft]

    /// The Simulator's appearance is set from outside (`xcrun simctl ui <device>
    /// appearance dark`), and named by TEST_RUNNER_REFERENCE_APPEARANCE when
    /// running xcodebuild: XCUIDevice's appearance setting doesn't reach apps.
    private static func name(_ orientation: UIDeviceOrientation) -> String {
        let appearance = ProcessInfo.processInfo.environment["REFERENCE_APPEARANCE"] ?? "light"
        return "\(appearance)-\(orientation == .portrait ? "portrait" : "landscape")"
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        // Let a rotation finish, and take the whole screen: an app screenshot
        // taken in landscape comes out drawn in portrait.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
