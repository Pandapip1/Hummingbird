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
    /// With a `scene`, the app shows that one piece of UI instead.
    @MainActor
    static func make(scene: DebugScene? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HUMMINGBIRD_DEBUG_DATA_ROOT"] = "ui-tests/\(UUID().uuidString)"
        if let scene { app.launchEnvironment[DebugScene.environmentKey] = scene.rawValue }
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
