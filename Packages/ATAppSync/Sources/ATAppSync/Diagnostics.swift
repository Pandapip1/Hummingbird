import os

/// ATAppSync's logging and signposts, in the host app's unified logging
/// subsystem so one predicate covers both. On Linux `os` is SwiftOpenUI's
/// stand-in, which writes to the systemd journal.
enum AppSyncDiagnostics {
    static let subsystem = "com.eightybps.hummingbird"
    static let lan = Logger(subsystem: subsystem, category: "appsync.lan")
    static let lanSignposter = OSSignposter(subsystem: subsystem, category: "appsync.lan")
}
