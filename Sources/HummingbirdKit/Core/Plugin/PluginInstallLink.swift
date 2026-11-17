import Foundation

/// A `grayjay://plugin/<config URL>` link, as plugin sites and QR codes use
/// to offer a plugin. It only ever names a plugin's config: opening one opens
/// Add Source with that URL, which shows the plugin, its signature check and
/// warnings, and installs nothing until the user agrees.
///
/// Links come from anywhere (web pages, other apps, QR codes), so anything
/// but a plain http(s) URL to a host is refused: other schemes (file:,
/// javascript:, data:, another grayjay: link), credentials in the URL,
/// whitespace or control characters, and overlong links.
struct PluginInstallLink: Equatable, Sendable {
    static let scheme = "grayjay"
    static let maximumLength = 2048

    /// The plugin's config URL (http or https).
    let configURL: URL

    /// A link the app was opened with.
    init?(_ url: URL) {
        self.init(text: url.absoluteString)
    }

    /// A link as text, such as a QR code's contents.
    init?(text: String) {
        guard text.count <= Self.maximumLength,
              let schemeEnd = text.range(of: "://"),
              text[..<schemeEnd.lowerBound].lowercased() == Self.scheme else { return nil }
        let rest = text[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/"), rest[..<slash].lowercased() == "plugin" else { return nil }
        var payload = String(rest[rest.index(after: slash)...])
        // The config URL is usually percent-encoded as one path segment.
        if !payload.contains("://"), let decoded = payload.removingPercentEncoding { payload = decoded }
        guard payload.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: payload),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(percentEncoded: false), !host.isEmpty,
              url.user(percentEncoded: false) == nil, url.password(percentEncoded: false) == nil else { return nil }
        configURL = url
    }
}
