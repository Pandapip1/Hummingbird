import Foundation
import os

/// The only way to log what plugins and their network traffic produce: their
/// `log()` output, alerts, browser errors and HTTP traces. Every message is a
/// `RedactedText`, which only `LogRedaction` makes, so tokens, cookies,
/// addresses and what the user typed are gone before anything is logged,
/// and the redacted text can be public. The loggers for these categories
/// are private to this file.
enum PluginLog {
    private static let consoleLog = Logger(subsystem: Diagnostics.subsystem, category: "plugin.console")
    private static let browserLog = Logger(subsystem: Diagnostics.subsystem, category: "plugin.browser")
    private static let httpLog = Logger(subsystem: Diagnostics.subsystem, category: "http")

    /// A plugin's own `log()` line (debug: streamed, not persisted).
    static func console(plugin: String, _ message: RedactedText) {
        consoleLog.debug("plugin=\(plugin, privacy: .public) \(message.description, privacy: .public)")
    }

    /// A plugin's UMP progress line, kept at info so it survives in the log
    /// store for diagnosing playback.
    static func umpProgress(plugin: String, _ message: RedactedText) {
        Logger.player.info("ump_log plugin=\(plugin, privacy: .public) \(message.description, privacy: .public)")
    }

    /// An alert a plugin showed the user.
    static func alert(plugin: String, _ message: RedactedText) {
        Logger.plugin.notice("alert plugin=\(plugin, privacy: .public) message=\(message.description, privacy: .public)")
    }

    /// A failure in the hidden browser plugins drive.
    static func browserFailure(_ event: StaticString, _ message: RedactedText) {
        browserLog.error("\(String(describing: event), privacy: .public) message=\(message.description, privacy: .public)")
    }

    /// An opt-in HTTP trace line (debug).
    static func httpTrace(_ line: RedactedText) {
        httpLog.debug("\(line.description, privacy: .public)")
    }

    /// A plugin request that failed, with verbose plugin logging on.
    static func httpFailure(_ line: RedactedText) {
        httpLog.notice("\(line.description, privacy: .public)")
    }
}
