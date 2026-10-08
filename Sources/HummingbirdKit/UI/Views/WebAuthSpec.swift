import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

/// What a login or captcha web view should wait for before it hands credentials back.
struct WebAuthSpec {
    var title: String
    var pluginID: String? = nil
    var pluginSourceURL: URL? = nil
    var startURL: URL?
    var html: String?
    var userAgent: String?
    var completionURL: String?
    var allowedDomains: [String]?
    var headersToFind: [String] = []
    var domainHeadersToFind: [String: [String]] = [:]
    var cookiesToFind: [String] = []
    var cookiesExclOthers = true
    var loginButtonSelector: String?
    /// Cookies are only kept for hosts the plugin is allowed to contact.
    var hostAllowed: (String) -> Bool

    var hasExplicitCompletion: Bool {
        completionURL != nil || !headersToFind.isEmpty || !domainHeadersToFind.isEmpty || !cookiesToFind.isEmpty
    }

    func matchesCompletion(_ url: URL) -> Bool {
        guard let target = completionURL else { return false }
        let ignoresQuery = target.hasSuffix("?*")
        guard let expected = URLComponents(string: ignoresQuery ? String(target.dropLast(2)) : target),
              let actual = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = expected.scheme?.lowercased(),
              let host = expected.host?.lowercased() else { return false }
        func port(_ components: URLComponents) -> Int? {
            components.port ?? (components.scheme?.lowercased() == "https" ? 443 :
                               components.scheme?.lowercased() == "http" ? 80 : nil)
        }
        // Hex casing does not change an escaped byte. Keep reserved bytes
        // escaped, so an encoded query separator cannot equal a real one.
        func encoded(_ value: String?) -> String? {
            guard let value else { return nil }
            var bytes = Array(value.utf8)
            var index = 0
            while index + 2 < bytes.count {
                if bytes[index] == 37 {
                    for offset in 1...2 where (97...102).contains(bytes[index + offset]) {
                        bytes[index + offset] -= 32
                    }
                    index += 3
                } else { index += 1 }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        func path(_ components: URLComponents) -> String {
            components.percentEncodedPath.isEmpty ? "/" : encoded(components.percentEncodedPath)!
        }
        return actual.scheme?.lowercased() == scheme && actual.host?.lowercased() == host &&
            port(actual) == port(expected) && path(actual) == path(expected) &&
            (ignoresQuery || (encoded(actual.percentEncodedQuery) == encoded(expected.percentEncodedQuery) &&
                             encoded(actual.percentEncodedFragment) == encoded(expected.percentEncodedFragment)))
    }

    /// Background completion cannot borrow required headers from an earlier
    /// request: they must accompany the successful completion request itself.
    func hasCompletionHeaders(_ headers: [String: String], url: URL) -> Bool {
        let names = Set(headers.compactMap { name, value in
            value.isEmpty || value == "undefined" ? nil : name.lowercased()
        })
        guard headersToFind.allSatisfy({ names.contains($0.lowercased()) }) else { return false }
        for (domain, required) in domainHeadersToFind where domainMatches(host: url.host ?? "", domain: domain) {
            if !required.allSatisfy({ names.contains($0.lowercased()) }) { return false }
        }
        return true
    }

    static func login(for plugin: PluginConfig) -> WebAuthSpec? {
        guard let a = plugin.authentication, let url = URL(string: a.loginUrl) else { return nil }
        return WebAuthSpec(title: "Log in to \(plugin.name)", pluginID: plugin.id,
                           pluginSourceURL: plugin.sourceUrl.flatMap(URL.init(string:)),
                           startURL: url, html: nil, userAgent: a.userAgent,
                           completionURL: a.completionUrl, allowedDomains: a.allowedDomains,
                           headersToFind: a.headersToFind ?? [], domainHeadersToFind: a.domainHeadersToFind ?? [:],
                           cookiesToFind: a.cookiesToFind ?? [], cookiesExclOthers: a.cookiesExclOthers ?? true,
                           loginButtonSelector: a.loginButton, hostAllowed: { plugin.allowsHost($0) })
    }

    static func captcha(for plugin: PluginConfig, url: String?, body: String?) -> WebAuthSpec? {
        let c = plugin.captcha
        let start = (c?.captchaUrl ?? url).flatMap(URL.init(string:))
        guard start != nil || body != nil else { return nil }
        // A captcha page's own body is only used when the plugin did not configure a captcha URL.
        let html = c?.captchaUrl == nil ? body : nil
        return WebAuthSpec(title: "Captcha for \(plugin.name)", pluginID: nil, pluginSourceURL: nil,
                           startURL: start, html: html, userAgent: c?.userAgent,
                           completionURL: c?.completionUrl, allowedDomains: nil,
                           cookiesToFind: c?.cookiesToFind ?? [], cookiesExclOthers: c?.cookiesExclOthers ?? true,
                           hostAllowed: { plugin.allowsHost($0) })
    }
}
