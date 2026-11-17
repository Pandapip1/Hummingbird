import XCTest

/// UI tests drive the real app, so each launch must use data of its own and
/// never the device's real profile, library or keychain. This declaration
/// shadows XCTest's `XCUIApplication` in the UI test targets, so creating one
/// directly doesn't compile: launch through `IsolatedApp` instead.
@available(*, unavailable, message: "Use IsolatedApp.make() or IsolatedApp.launch(): UI tests must never use the device's real data.")
struct XCUIApplication {}

/// The app under test, isolated from real data.
enum IsolatedApp {
    /// An app configured to keep everything under a data root of its own
    /// (`HUMMINGBIRD_DEBUG_DATA_ROOT`, honoured by debug builds): a fresh
    /// directory in the app's own temporary directory, so it works on
    /// simulators and devices alike. Add further launch settings, then
    /// launch it; relaunching the same instance keeps the same data.
    @MainActor
    static func make() -> XCTest.XCUIApplication {
        let app = XCTest.XCUIApplication()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_DATA_ROOT"] = "ui-tests/\(UUID().uuidString)"
        return app
    }

    /// `make()`, launched and in the foreground.
    @MainActor
    static func launch() -> XCTest.XCUIApplication {
        let app = make()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }
}
