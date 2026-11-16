import Foundation
import os

/// ATAppSync's logging and signposts, in the host app's unified logging
/// subsystem so one predicate covers both. On Linux `os` is SwiftOpenUI's
/// stand-in, which writes to the systemd journal.
///
/// A test process (XCTest loaded, or SwiftPM's `*.xctest` runner) logs under
/// `com.eightybps.hummingbird.tests` instead, keeping test output out of the
/// app's entries.
enum AppSyncDiagnostics {
    static let subsystem = isTestProcess
        ? "com.eightybps.hummingbird.tests"
        : "com.eightybps.hummingbird"

    private static var isTestProcess: Bool {
        #if canImport(ObjectiveC)
        if NSClassFromString("XCTestCase") != nil { return true }
        #endif
        let executable = ProcessInfo.processInfo.arguments.first
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return executable == "xctest" || executable.hasSuffix(".xctest")
            || executable == "swiftpm-testing-helper"
    }
    static let lan = Logger(subsystem: subsystem, category: "appsync.lan")
    static let lanSignposter = OSSignposter(subsystem: subsystem, category: "appsync.lan")
}
