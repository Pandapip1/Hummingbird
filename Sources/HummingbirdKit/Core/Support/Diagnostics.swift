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

/// Removes secrets, network addresses, home-directory names and caller-supplied
/// terms (what the user typed) from free text such as plugin and service error
/// messages, so it can be logged as public data and still be readable in the
/// persisted log. The rules are regex literals: a malformed rule fails to
/// compile instead of silently redacting nothing. It errs towards removing too
/// much: a credential header's value is dropped to the end of the line.
enum LogRedaction {
    static func redact(_ text: String, removing terms: [String] = [], limit: Int = 500) -> String {
        var s = text
        for term in expanded(terms) {
            s = s.replacingOccurrences(of: term, with: "<query>", options: [.caseInsensitive, .diacriticInsensitive])
        }
        // Query strings and fragments carry tokens and signatures, with or without a scheme.
        s.replace(#/(https?:\/\/[^\s?#"'<>]+)[?#][^\s"'<>]*/#) { "\($0.output.1)?<redacted>" }
        s.replace(#/(?i)\b((?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^\s?#"'<>]*)?)\?[^\s"'<>]+/#) { "\($0.output.1)?<redacted>" }
        // Credential headers: the whole value, whatever its scheme or number of cookies.
        s.replace(#/(?i)\b((?:set-)?cookie|(?:proxy-)?authorization|x-api-key)("?\s*[:=]\s*"?)[^\r\n"]*/#) {
            "\($0.output.1)\($0.output.2)<redacted>"
        }
        s.replace(#/(?i)\b(bearer|basic|oauth)\s+[A-Za-z0-9._~+\/=-]+/#) { "\($0.output.1) <redacted>" }
        // JSON web tokens.
        s.replace(#/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?/#, with: "<redacted>")
        // name=value and "name": "value" pairs whose name says they are secret.
        s.replace(#/(?i)("?[a-z0-9_-]*(?:token|key|secret|password|passwd|auth|session|cookie|signature|integrity|credential)[a-z0-9_-]*"?\s*[:=]\s*"?)[^"&\s,;}]+/#) { "\($0.output.1)<redacted>" }
        s.replace(#/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#, with: "<email>")
        // Home directories name the person.
        s.replace(#/(\/(?:Users|home))\/[^\/\s"']+/#) { "\($0.output.1)/<user>" }
        s.replace(#/(?i)\b([a-z]:\\Users)\\[^\\\s"']+/#) { "\($0.output.1)\\<user>" }
        s.replace(#/\b(?:\d{1,3}\.){3}\d{1,3}\b/#, with: "<ip>")
        // IPv6: full form (four or more groups, so clock times are left alone), "a::b" and a bare "::1".
        s.replace(#/(?i)\b(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}\b/#, with: "<ip>")
        s.replace(#/(?i)\b(?:[0-9a-f]{1,4}:){1,6}:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4}){0,5})?/#, with: "<ip>")
        s.replace(#/(?i)(^|[\s\[(=,"'\/])::(?:ffff:)?[0-9a-f]{0,4}(?::[0-9a-f]{1,4})*/#) { "\($0.output.1)<ip>" }
        // Long opaque values (hex IDs, base64 tokens).
        s.replace(#/[A-Za-z0-9+_-]{32,}={0,2}/#, with: "<redacted>")
        if s.count > limit { s = String(s.prefix(limit)) + "…" }
        return s
    }

    /// Each term as typed, URL-encoded both ways, and its longer words on their own.
    private static func expanded(_ terms: [String]) -> [String] {
        var out: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            // One- and two-letter terms would blank out ordinary words.
            guard trimmed.count >= 3 else { continue }
            out.append(trimmed)
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                out.append(encoded)
                out.append(encoded.replacingOccurrences(of: "%20", with: "+"))
            }
            out.append(contentsOf: trimmed.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count >= 3 })
        }
        // Longest first, so a phrase is replaced before its words.
        return Array(Set(out)).sorted { $0.count > $1.count }
    }
}
