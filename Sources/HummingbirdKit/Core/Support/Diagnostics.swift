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
///
/// A test process logs under `com.eightybps.hummingbird.tests` instead, so
/// the fake diagnostics, failures and payloads tests produce never appear
/// among the app's own entries.
public enum Diagnostics {
    public static let subsystem = LiveData.isTestProcess
        ? "com.eightybps.hummingbird.tests"
        : "com.eightybps.hummingbird"
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
    /// MetricKit payloads and render stalls.
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
    /// Render stalls (`RenderStall` events).
    static let performance = OSSignposter(subsystem: Diagnostics.subsystem, category: "performance")
}
