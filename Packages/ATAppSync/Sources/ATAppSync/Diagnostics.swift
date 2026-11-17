import Foundation
import os

/// Whether this process is a test runner rather than an application. Shared
/// by ATAppSync and the apps built on it, so they all decide the same way.
///
/// XCTest is never loaded into an app (UI tests drive it from a separate
/// runner process), so its presence identifies a unit-test process on Apple
/// platforms. Elsewhere the runner is identified by its executable: SwiftPM's
/// `*.xctest` test binary, or the `xctest`/Swift Testing helper that loads it.
public enum TestProcess {
    public static let isRunning: Bool = {
        #if canImport(ObjectiveC)
        if NSClassFromString("XCTestCase") != nil { return true }
        #endif
        let executable = ProcessInfo.processInfo.arguments.first
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return executable == "xctest" || executable.hasSuffix(".xctest")
            || executable == "swiftpm-testing-helper"
    }()
}

/// ATAppSync's logging and signposts, in the host app's unified logging
/// subsystem so one predicate covers both. On Linux `os` is SwiftOpenUI's
/// stand-in, which writes to the systemd journal.
///
/// A test process logs under `com.eightybps.hummingbird.tests` instead,
/// keeping test output out of the app's entries.
enum AppSyncDiagnostics {
    static let subsystem = TestProcess.isRunning
        ? "com.eightybps.hummingbird.tests"
        : "com.eightybps.hummingbird"
    static let lan = Logger(subsystem: subsystem, category: "appsync.lan")
    static let lanSignposter = OSSignposter(subsystem: subsystem, category: "appsync.lan")
}
