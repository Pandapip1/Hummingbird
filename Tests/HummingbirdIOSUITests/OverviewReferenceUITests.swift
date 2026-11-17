import XCTest

/// Screenshots of Hummingbird's tab overview next to Safari's, in light and
/// dark mode, portrait and landscape, to keep the two looking the same.
/// Attachments: "safari-<light|dark>-<portrait|landscape>" and the same for
/// "hummingbird-…".
final class OverviewReferenceUITests: XCTestCase {
    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    @MainActor
    func testSafariTabOverview() throws {
        for (appearance, orientation) in Self.variants {
            XCUIDevice.shared.appearance = appearance
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
            attach(safari, "safari-\(Self.name(appearance, orientation))")
            safari.terminate()
        }
    }

    @MainActor
    func testHummingbirdTabOverview() throws {
        for (appearance, orientation) in Self.variants {
            XCUIDevice.shared.appearance = appearance
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
            attach(app, "hummingbird-\(Self.name(appearance, orientation))")
            app.terminate()
        }
    }

    private static let variants: [(XCUIDevice.Appearance, UIDeviceOrientation)] = [
        (.light, .portrait), (.dark, .portrait), (.light, .landscapeLeft), (.dark, .landscapeLeft),
    ]

    private static func name(_ appearance: XCUIDevice.Appearance, _ orientation: UIDeviceOrientation) -> String {
        "\(appearance == .dark ? "dark" : "light")-\(orientation == .portrait ? "portrait" : "landscape")"
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
