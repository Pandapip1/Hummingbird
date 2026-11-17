import Foundation
import os

/// Hummingbird's unified logging subsystem. Every logger and signposter in
/// the app and its packages uses it, so one predicate shows everything:
///
///     log stream --predicate 'subsystem == "com.eightybps.hummingbird"'
///
/// On Linux the same `Logger` and `OSSignposter` come from SwiftOpenUI's `os`
/// module and write to the systemd journal (`journalctl --user
/// OSLOG_SUBSYSTEM=com.eightybps.hummingbird`). See Documentation/Debugging.md.
///
/// Privacy: interpolated strings are redacted unless marked `.public`. Mark
/// only values we chose or that identify a service (plugin IDs, event names,
/// hosts, counts, states) as public. URLs, titles, messages, plugin output and
/// error descriptions stay private. Secrets are never logged.
public enum Diagnostics {
    public static let subsystem = "com.eightybps.hummingbird"
}

extension Logger {
    /// Playback model: source selection, loading, UMP refreshes.
    static let player = Logger(subsystem: Diagnostics.subsystem, category: "player")
    /// The AVFoundation playback backend.
    static let avPlayer = Logger(subsystem: Diagnostics.subsystem, category: "avplayer")
    /// Plugin lifecycle, alerts and compatibility patches.
    static let plugin = Logger(subsystem: Diagnostics.subsystem, category: "plugin")
    /// Plugins' own `log()` output (debug level; private).
    static let pluginConsole = Logger(subsystem: Diagnostics.subsystem, category: "plugin.console")
    /// The hidden browser plugins drive (BotGuard and similar).
    static let pluginBrowser = Logger(subsystem: Diagnostics.subsystem, category: "plugin.browser")
    /// Plugin HTTP traffic (traces are opt-in, see HostHTTP).
    static let http = Logger(subsystem: Diagnostics.subsystem, category: "http")
    /// The local proxy that serves plugin media to the player.
    static let mediaProxy = Logger(subsystem: Diagnostics.subsystem, category: "media-proxy")
    /// Which plugin handles a URL, and navigation to content.
    static let routing = Logger(subsystem: Diagnostics.subsystem, category: "routing")
    /// AT Protocol accounts and sign-in.
    static let account = Logger(subsystem: Diagnostics.subsystem, category: "account")
    /// Credential storage.
    static let keychain = Logger(subsystem: Diagnostics.subsystem, category: "keychain")
    /// Permission prompts and records.
    static let permissions = Logger(subsystem: Diagnostics.subsystem, category: "permissions")
    /// MetricKit payloads and main-thread stalls.
    static let performance = Logger(subsystem: Diagnostics.subsystem, category: "performance")
}

extension OSSignposter {
    /// Plugin calls (`PluginCall`), timeouts and the browser package.
    static let plugin = OSSignposter(subsystem: Diagnostics.subsystem, category: "plugin")
    /// Loading content and playback (`LoadContent`, `ResolveSource`, `UMPRefresh`).
    static let player = OSSignposter(subsystem: Diagnostics.subsystem, category: "player")
    /// Media proxy requests and UMP segments.
    static let mediaProxy = OSSignposter(subsystem: Diagnostics.subsystem, category: "media-proxy")
    /// OAuth sign-in steps and keychain reads.
    static let account = OSSignposter(subsystem: Diagnostics.subsystem, category: "account")
    /// AppSync passes (`SyncPass`, `LANPull`, `PDSPull`).
    static let sync = OSSignposter(subsystem: Diagnostics.subsystem, category: "sync")
    /// Main-thread stalls (`RenderStall` intervals, from `MainThreadWatchdog`).
    static let performance = OSSignposter(subsystem: Diagnostics.subsystem, category: "performance")
}

/// Removes secrets and network addresses from free text, such as plugin and
/// service error messages, so it can be logged as public data and still be
/// readable in the persisted log. The rules are regex literals: a malformed
/// rule fails to compile instead of silently redacting nothing.
enum LogRedaction {
    static func redact(_ text: String, limit: Int = 500) -> String {
        var s = text
        // Query strings and fragments carry tokens and signatures.
        s.replace(#/(https?:\/\/[^\s?#"'<>]+)[?#][^\s"'<>]*/#) { "\($0.output.1)?<redacted>" }
        s.replace(#/(?i)\b(bearer|basic|oauth)\s+[A-Za-z0-9._~+\/=-]+/#) { "\($0.output.1) <redacted>" }
        // JSON web tokens.
        s.replace(#/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?/#, with: "<redacted>")
        // name=value and "name": "value" pairs whose name says they are secret.
        s.replace(#/(?i)("?[a-z0-9_-]*(?:token|key|secret|password|passwd|auth|session|cookie|signature|integrity|credential)[a-z0-9_-]*"?\s*[:=]\s*"?)[^"&\s,;}]+/#) { "\($0.output.1)<redacted>" }
        s.replace(#/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#, with: "<email>")
        s.replace(#/\b(?:\d{1,3}\.){3}\d{1,3}\b/#, with: "<ip>")
        // IPv6: full form (four or more groups, so clock times are left alone) and "::" shorthand.
        s.replace(#/(?i)\b(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}\b/#, with: "<ip>")
        s.replace(#/(?i)\b(?:[0-9a-f]{1,4}:){1,6}:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,5})?/#, with: "<ip>")
        // Long opaque values (hex IDs, base64 tokens).
        s.replace(#/[A-Za-z0-9+_-]{32,}={0,2}/#, with: "<redacted>")
        if s.count > limit { s = String(s.prefix(limit)) + "…" }
        return s
    }
}
