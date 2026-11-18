import Foundation
import Synchronization

/// A value a plugin returned. Plugin results are data, never code: every type
/// the runtime decodes from a plugin conforms, and the runtime calls
/// `contain(_:)` on it before anyone else sees it (`PluginRuntime.decode`).
/// Containment bounds sizes, keeps only URLs the app may fetch or open, binds
/// the value to the plugin that produced it, and strips text used to spoof
/// the UI. A new model type cannot be decoded from a plugin without saying
/// how it is contained, because the decode functions require this protocol.
protocol PluginOutput: Decodable, Sendable {
    mutating func contain(_ context: PluginOutputContext)
}

/// Who produced a value, and what that plugin may reference.
struct PluginOutputContext: Sendable {
    let pluginID: String
    let policy: PluginNetworkPolicy

    init(pluginID: String, policy: PluginNetworkPolicy) {
        self.pluginID = pluginID
        self.policy = policy
    }

    // MARK: text

    /// A single line shown in the UI (titles, names): no line breaks, controls or bidi overrides, bounded.
    func line(_ s: String, limit: Int = PluginLimits.maximumTitleLength) -> String {
        PluginText.line(s, limit: limit)
    }

    func optionalLine(_ s: String?, limit: Int = PluginLimits.maximumTitleLength) -> String? {
        s.map { line($0, limit: limit) }
    }

    /// Longer text shown in the UI (descriptions, comments): line breaks kept, controls and bidi overrides removed, bounded.
    func text(_ s: String, limit: Int = PluginLimits.maximumTextLength) -> String {
        PluginText.text(s, limit: limit)
    }

    func optionalText(_ s: String?, limit: Int = PluginLimits.maximumTextLength) -> String? {
        s.map { text($0, limit: limit) }
    }

    /// An identifier the app only hands back to plugins (content and channel
    /// URLs, which the address bar resolves through plugins only): controls
    /// removed and bounded, otherwise opaque.
    func reference(_ s: String) -> String {
        PluginText.line(s, limit: PluginLimits.maximumURLLength)
    }

    // MARK: URLs

    /// A URL the app fetches itself (thumbnails, images, banners): http(s),
    /// no user info, and not a non-public address by its form (loopback, LAN,
    /// `.local`), unless it is a host the user approved for this plugin.
    /// Thumbnails need not be allow-listed (CDNs differ from API hosts).
    func webURL(_ s: String?) -> String? {
        guard let url = parsedWebURL(s), let host = url.host(percentEncoded: false) else { return nil }
        let normalized = PluginNetworkPolicy.normalizedHost(host)
        let approved = policy.approvals.contains { $0.host == normalized }
        if !approved {
            if let literal = IPAddress(literal: normalized), !literal.scope.isPublic { return nil }
            if AddressClassifier.isLocalName(normalized) { return nil }
        }
        return url.absoluteString
    }

    /// A media URL (stream, subtitle file): http(s) and no user info. Where it
    /// may be fetched from is decided when it is fetched, by the plugin's
    /// network policy.
    func mediaURL(_ s: String?) -> String? {
        parsedWebURL(s)?.absoluteString
    }

    /// A URL the app may open outside itself or share: http(s), allow-listed
    /// by the plugin's config, never a local address.
    func navigableURL(_ s: String?) -> NavigableURL? {
        guard let url = parsedWebURL(s), policy.mayReference(url) else { return nil }
        return NavigableURL(contained: url)
    }

    private func parsedWebURL(_ s: String?) -> URL? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= PluginLimits.maximumURLLength,
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || PluginText.isSpoofingScalar($0) }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return url
    }

    // MARK: lists

    func list<T>(_ items: [T], limit: Int = PluginLimits.maximumListLength) -> [T] {
        items.count > limit ? Array(items.prefix(limit)) : items
    }

    func contained<T: PluginOutput>(_ items: [T], limit: Int = PluginLimits.maximumListLength) -> [T] {
        list(items, limit: limit).map { var item = $0; item.contain(self); return item }
    }
}

/// A URL that survived containment for opening outside the app (or one the
/// app itself owns). `ExternalURLLink` only takes this, so a plugin-supplied
/// string cannot reach the system's URL opener without passing
/// `PluginOutputContext.navigableURL`.
struct NavigableURL: Hashable, Sendable {
    let url: URL

    fileprivate init(contained url: URL) { self.url = url }

    /// A link the app itself ships (help pages, policies). Static strings only.
    init?(appOwned string: StaticString) {
        guard let url = URL(string: "\(string)"), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        self.url = url
    }
}

// MARK: - Text sanitising

/// Plugin text as plain text. HTML is never rendered: tags are dropped,
/// script and style contents removed, entities decoded, and characters used
/// to spoof surrounding UI (bidi overrides and isolates, controls) removed.
enum PluginText {
    /// Bidi embedding/override (U+202A–U+202E) and isolate (U+2066–U+2069) controls.
    static func isSpoofingScalar(_ s: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value)
    }

    private static func isControl(_ s: Unicode.Scalar, keepingNewlines: Bool) -> Bool {
        if keepingNewlines, s == "\n" || s == "\t" { return false }
        return s.value < 0x20 || (0x7f...0x9f).contains(s.value) || s.value == 0x2028 || s.value == 0x2029
    }

    /// One line: line breaks become spaces, controls and spoofing characters go, bounded.
    static func line(_ s: String, limit: Int = PluginLimits.maximumTitleLength) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in bounded(s, limit: limit).unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.value == 0x2028 || scalar.value == 0x2029 {
                scalars.append(" ")
            } else if !isControl(scalar, keepingNewlines: false) && !isSpoofingScalar(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Text: line breaks kept (CR LF folded to LF), controls and spoofing characters gone, bounded.
    static func text(_ s: String, limit: Int = PluginLimits.maximumTextLength) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in bounded(s, limit: limit).replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
            if scalar == "\r" { scalars.append("\n") }
            else if !isControl(scalar, keepingNewlines: true) && !isSpoofingScalar(scalar) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    /// HTML (or text with some markup) as plain text, sanitised like `text`.
    static func plain(_ html: String, limit: Int = PluginLimits.maximumTextLength) -> String {
        // Bound the work before any regular expression runs.
        var s = String(bounded(html, limit: limit * 4))
        s = s.replacingOccurrences(of: "(?is)<(script|style|template|noscript)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|li|h[1-6])\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        // An unterminated tag keeps its text out rather than rendering it.
        if let open = s.lastIndex(of: "<"), !s[open...].contains(">"),
           s[s.index(after: open)...].first.map({ $0.isLetter || $0 == "/" || $0 == "!" }) == true {
            s = String(s[..<open])
        }
        return text(decodeEntities(s), limit: limit)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "nbsp": "\u{00A0}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
    ]

    /// Decodes named and numeric entities in one pass (so "&amp;lt;" stays "&lt;").
    /// Numeric entities that name controls, surrogates or out-of-range values are dropped.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var index = s.startIndex
        while index < s.endIndex {
            let ch = s[index]
            guard ch == "&", let semicolon = s[index...].prefix(12).firstIndex(of: ";") else {
                out.append(ch)
                index = s.index(after: index)
                continue
            }
            let name = String(s[s.index(after: index)..<semicolon])
            if let replacement = namedEntities[name.lowercased()] {
                out += replacement
            } else if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let value: UInt32? = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                if let value, let scalar = Unicode.Scalar(value), value >= 0x20, !(0x7f...0x9f).contains(value) {
                    out.unicodeScalars.append(scalar)
                } else if value == nil {
                    out += "&" + name + ";"
                }
            } else {
                out += "&" + name + ";"
            }
            index = s.index(after: semicolon)
        }
        return out
    }

    private static func bounded(_ s: String, limit: Int) -> Substring {
        // Character counting is linear; check the cheap UTF-8 length first.
        s.utf8.count <= limit ? Substring(s) : s.prefix(limit)
    }
}

// MARK: - Primitive results

extension String: PluginOutput {
    /// Raw strings (generated manifests, subtitle files, URL lists) are only
    /// bounded by the runtime's result-size cap; display them through
    /// `PluginLine` or a model type instead.
    mutating func contain(_ context: PluginOutputContext) {}
}

extension Int: PluginOutput { mutating func contain(_ context: PluginOutputContext) {} }
extension Bool: PluginOutput { mutating func contain(_ context: PluginOutputContext) {} }
extension Double: PluginOutput { mutating func contain(_ context: PluginOutputContext) {} }

extension Optional: PluginOutput where Wrapped: PluginOutput {
    mutating func contain(_ context: PluginOutputContext) {
        guard var value = self else { return }
        value.contain(context)
        self = value
    }
}

extension Array: PluginOutput where Element: PluginOutput {
    mutating func contain(_ context: PluginOutputContext) {
        self = context.contained(self)
    }
}

extension Dictionary: PluginOutput where Key == String, Value: PluginOutput {
    mutating func contain(_ context: PluginOutputContext) {
        var out: [String: Value] = [:]
        for (key, value) in self.prefix(PluginLimits.maximumListLength) {
            var v = value
            v.contain(context)
            out[context.line(key)] = v
        }
        self = out
    }
}

/// A short string a plugin returned for display (a search suggestion).
struct PluginLine: PluginOutput, Hashable {
    var text: String

    init(from decoder: Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    mutating func contain(_ context: PluginOutputContext) { text = context.line(text) }
}

// MARK: - Toasts

/// A message a plugin asked to show. Always attributed to the plugin that
/// sent it and bounded, so a plugin cannot pass it off as the app's own UI.
struct PluginToast: Equatable, Sendable, Identifiable {
    let pluginName: String
    let message: String
    let id = UUID()

    init(pluginName: String, message: String) {
        self.pluginName = PluginText.line(pluginName, limit: 60)
        self.message = PluginText.line(message, limit: PluginLimits.maximumToastLength)
    }
}

/// Drops toasts beyond `PluginLimits.toastsPerMinute` per plugin.
final class PluginToastLimiter: Sendable {
    static let shared = PluginToastLimiter()
    private let buckets = Mutex<[String: TokenBucket]>([:])
    private let rate: Double
    private let burst: Double

    init(perMinute: Int = PluginLimits.toastsPerMinute) {
        rate = Double(perMinute) / 60
        burst = Double(perMinute)
    }

    func allow(pluginID: String, now: Date = Date()) -> Bool {
        buckets.withLock { buckets in
            var bucket = buckets[pluginID] ?? TokenBucket(rate: rate, burst: burst, now: now)
            let allowed = bucket.tryTake(now: now)
            buckets[pluginID] = bucket
            return allowed
        }
    }
}
