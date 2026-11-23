import Foundation

/// Where a sign-in or captcha page may take its main frame: the source's own
/// domains and its sign-in provider's, and nowhere else. This keeps login
/// sheets from becoming a general web browser (App Store: "Unrestricted Web
/// Access: No"); a navigation outside the scope is cancelled and nothing else
/// is opened in its place.
struct LoginNavigationScope: Sendable, Equatable {
    /// Each entry allows itself and its subdomains.
    let domains: [String]

    init(domains: [String]) {
        self.domains = Array(Set(domains.map { Self.normalized($0) }.filter { !$0.isEmpty })).sorted()
    }

    func allows(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "about": return url.absoluteString == "about:blank"
        case "https", "http": break
        default: return false
        }
        guard let host = url.host?.lowercased() else { return false }
        return domains.contains { domainMatches(host: host, domain: $0) }
    }

    /// A plugin's sign-in: its allowed hosts, its declared login domains, and
    /// the sites of the login and completion URLs.
    static func login(for plugin: PluginConfig) -> Self {
        let auth = plugin.authentication
        let urls = [auth?.loginUrl, auth?.completionUrl].compactMap { $0 }.compactMap { URL(string: $0) }
        return Self(domains: plugin.declaredHosts + (auth?.allowedDomains ?? []) + urls.compactMap(site))
    }

    /// A plugin's captcha page: its allowed hosts and the captcha page's site.
    static func captcha(for plugin: PluginConfig, start: URL?) -> Self {
        Self(domains: plugin.declaredHosts + [start.flatMap(site)].compactMap { $0 })
    }

    /// An OAuth authorization: the authorization server's site.
    static func oauth(authorizationURL: URL) -> Self {
        Self(domains: [site(of: authorizationURL)].compactMap { $0 })
    }

    /// A URL's site: its host, widened to the parent domain when that is not
    /// a public suffix (accounts.google.com → google.com). Without a public
    /// suffix list, two-letter country domains with a generic second level
    /// (co.uk, com.au) are kept at three labels.
    static func site(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count >= 3, Double(labels.last ?? "") == nil else { return host }
        let genericSecondLevels: Set<Substring> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"]
        let keep = labels.last?.count == 2 && genericSecondLevels.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    private static func normalized(_ domain: String) -> String {
        var d = domain.lowercased()
        if d.hasPrefix("*.") { d.removeFirst(2) }
        if d.hasPrefix(".") { d.removeFirst() }
        return d
    }
}

private func site(_ url: URL) -> String? { LoginNavigationScope.site(of: url) }

private extension PluginConfig {
    /// The hosts in `allowUrls`, without the "everywhere" wildcard: a plugin
    /// allowed to fetch anywhere still may not browse anywhere.
    var declaredHosts: [String] {
        allowUrls.map { $0.lowercased() }.filter {
            ($0.hasPrefix("*.") || !$0.contains("*")) && !$0.isEmpty && $0 != "everywhere"
        }
    }
}
