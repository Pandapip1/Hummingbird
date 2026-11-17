import XCTest

/// The app under test, isolated from real data. UI tests drive the real app,
/// so each launch must use data of its own and never the device's real
/// profile, library or keychain: every UI test launches through here
/// (`UITestIsolationTests` fails the build's tests otherwise).
enum IsolatedApp {
    /// An app configured to keep everything under a data root of its own
    /// (`HUMMINGBIRD_DEBUG_DATA_ROOT`, honoured by debug builds): a fresh
    /// directory in the app's own temporary directory, so it works on
    /// simulators and devices alike. Add further launch settings, then
    /// launch it; relaunching the same instance keeps the same data.
    @MainActor
    static func make() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_DATA_ROOT"] = "ui-tests/\(UUID().uuidString)"
        return app
    }

    /// `make()`, launched and in the foreground.
    @MainActor
    static func launch() -> XCUIApplication {
        let app = make()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }
}
