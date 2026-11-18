import Foundation
import SwiftOpenUI

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
    /// Domains the sheet may navigate to (any frame), besides the start and
    /// completion hosts. A domain also covers its subdomains. Never the
    /// plugin's "everywhere": a sign-in sheet is not a browser.
    var navigationDomains: [String] = []
    /// Non-public hosts (LAN, loopback, tailnet) the user approved for this
    /// plugin. Without one, such a host cannot be opened, even as the start page.
    var localHostApprovals: [LocalHostApproval] = []

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

    // MARK: containment

    /// The hosts and domains the sheet may show: `navigationDomains`, plus
    /// the start and completion hosts.
    var navigationHosts: [String] {
        var hosts = navigationDomains
        if let host = startURL?.host(percentEncoded: false) { hosts.append(host) }
        if let target = completionURL {
            let trimmed = target.hasSuffix("?*") ? String(target.dropLast(2)) : target
            if let host = URLComponents(string: trimmed)?.host { hosts.append(host) }
        }
        return hosts.map { PluginNetworkPolicy.normalizedHost($0) }.filter { !$0.isEmpty }
    }

    /// Whether any frame of the sheet may navigate to `url`: http(s) within
    /// `navigationHosts`, where non-public addresses and local names also
    /// need the user's approval for that host and port; and the blank
    /// documents frames start as. Nothing else, so the sheet can never
    /// become a general web browser.
    func allowsNavigation(to url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" {
            let target = url.absoluteString.lowercased()
            return target == "about:blank" || target == "about:srcdoc"
        }
        guard scheme == "http" || scheme == "https",
              let raw = url.host(percentEncoded: false), !raw.isEmpty else { return false }
        let host = PluginNetworkPolicy.normalizedHost(raw)
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        if let literal = IPAddress(literal: host) {
            switch literal.scope {
            case .metadata: return false
            case .nonPublic:
                guard localHostApprovals.contains(where: { $0.permits(host: host, port: port, address: literal) }) else { return false }
            case .public: break
            }
        } else if AddressClassifier.isLocalName(host),
                  !localHostApprovals.contains(where: { $0.host == host && $0.port == port }) {
            return false
        }
        return navigationHosts.contains { domainMatches(host: host, domain: $0) }
    }

    /// Whether cookies or headers seen for `host` may be handed to the
    /// plugin: the plugin may contact the host, and it is one of the sheet's
    /// own hosts or a parent domain of one (a sign-in cookie set on
    /// `.example.com` by `accounts.example.com`). Third-party cookies that
    /// subresources leave in the sheet's store never leave it.
    func mayExportCredentials(for rawHost: String) -> Bool {
        var host = PluginNetworkPolicy.normalizedHost(rawHost)
        if host.hasPrefix(".") { host.removeFirst() }
        guard !host.isEmpty, hostAllowed(host) else { return false }
        return navigationHosts.contains { navigation in
            var bare = navigation
            if bare.hasPrefix("*.") { bare.removeFirst(2) }
            if bare.hasPrefix(".") { bare.removeFirst() }
            return domainMatches(host: host, domain: bare) || domainMatches(host: bare, domain: host)
        }
    }

    /// The allow-list's own hosts and domains, never "everywhere".
    private static func allowListDomains(_ plugin: PluginConfig) -> [String] {
        PluginNetworkPolicy.parse(plugin.allowUrls).compactMap { entry in
            switch entry.kind {
            case .everywhere: nil
            case .exact(let host): host
            case .domain(let domain): domain
            }
        }
    }

    /// The plugin's sign-in sheet, or nil when it has none or its login page
    /// is somewhere the sheet may not go (an unapproved local host, a
    /// non-http(s) URL). `approvals` are the plugin's local-host approvals.
    static func login(for plugin: PluginConfig, approvals: [LocalHostApproval] = []) -> WebAuthSpec? {
        guard let a = plugin.authentication, let url = URL(string: a.loginUrl) else { return nil }
        let spec = WebAuthSpec(title: "Log in to \(plugin.name)", pluginID: plugin.id,
                               pluginSourceURL: plugin.sourceUrl.flatMap(URL.init(string:)),
                               startURL: url, html: nil, userAgent: a.userAgent,
                               completionURL: a.completionUrl, allowedDomains: a.allowedDomains,
                               headersToFind: a.headersToFind ?? [], domainHeadersToFind: a.domainHeadersToFind ?? [:],
                               cookiesToFind: a.cookiesToFind ?? [], cookiesExclOthers: a.cookiesExclOthers ?? true,
                               loginButtonSelector: a.loginButton, hostAllowed: { plugin.allowsHost($0) },
                               navigationDomains: (a.allowedDomains ?? []) + allowListDomains(plugin),
                               localHostApprovals: approvals)
        return spec.allowsNavigation(to: url) ? spec : nil
    }

    /// The plugin's captcha sheet. A captcha URL the plugin supplies at run
    /// time (rather than in its config) is only opened when it is within the
    /// plugin's configured captcha hosts or its allow-list.
    static func captcha(for plugin: PluginConfig, url: String?, body: String?,
                        approvals: [LocalHostApproval] = []) -> WebAuthSpec? {
        let c = plugin.captcha
        var domains = allowListDomains(plugin)
        for configured in [c?.captchaUrl, c?.completionUrl] {
            if let host = configured.flatMap(URL.init(string:))?.host(percentEncoded: false) { domains.append(host) }
        }
        let configuredStart = c?.captchaUrl.flatMap(URL.init(string:))
        var start = configuredStart
        if start == nil, let supplied = url.flatMap(URL.init(string:)) {
            let check = WebAuthSpec(title: "", completionURL: nil, hostAllowed: { _ in true },
                                    navigationDomains: domains, localHostApprovals: approvals)
            guard check.allowsNavigation(to: supplied) else { return nil }
            start = supplied
        }
        guard start != nil || body != nil else { return nil }
        // A captcha page's own body is only used when the plugin did not configure a captcha URL.
        let html = c?.captchaUrl == nil ? body : nil
        let spec = WebAuthSpec(title: "Captcha for \(plugin.name)", pluginID: nil, pluginSourceURL: nil,
                               startURL: start, html: html, userAgent: c?.userAgent,
                               completionURL: c?.completionUrl, allowedDomains: nil,
                               cookiesToFind: c?.cookiesToFind ?? [], cookiesExclOthers: c?.cookiesExclOthers ?? true,
                               hostAllowed: { plugin.allowsHost($0) },
                               navigationDomains: domains, localHostApprovals: approvals)
        if let start, !spec.allowsNavigation(to: start) { return nil }
        return spec
    }
}
