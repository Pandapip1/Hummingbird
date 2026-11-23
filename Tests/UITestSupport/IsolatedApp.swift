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
        start(app)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }

    /// Launches (or relaunches) `app`. Every UI test launches Hummingbird
    /// through here (`UITestIsolationTests` checks it), never `launch()`.
    ///
    /// The system sometimes fails to start the app at all, typically the
    /// first launch after the simulator boots ("does not have a process ID").
    /// That one failure is retried once, and logged; an assertion failure,
    /// or a second failed launch, fails the test as usual.
    @MainActor
    static func start(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { isLaunchFailure($0.compactDescription) }
        XCTExpectFailure("The system can fail to start the app; that is retried once.", options: options) {
            app.launch()
        }
        // Started: nothing to retry. Not running after launch() means the
        // system never started it (any other issue was reported as usual).
        guard app.state == .notRunning else { return }
        print("IsolatedApp: the app failed to launch; retrying once")
        XCTContext.runActivity(named: "Retry launch after a launch failure") { _ in app.launch() }
    }

    /// Whether an issue is the system failing to start the app, rather than
    /// anything the app or the test did.
    nonisolated static func isLaunchFailure(_ description: String) -> Bool {
        ["does not have a process ID", "Failed to launch", "failed to launch", "Application failed to launch"]
            .contains { description.contains($0) }
    }
}

/// The system's own apps, for reference screenshots (the tab overview is
/// compared with Safari's). They hold none of Hummingbird's data, so they
/// need no isolation; Hummingbird itself is only ever launched through
/// `IsolatedApp`.
enum SystemReferenceApp {
    @MainActor
    static func safari() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    }
}
