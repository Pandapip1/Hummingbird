import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

/// What a login or captcha web view should wait for before it hands credentials back.
struct WebAuthSpec {
    var title: String
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

    static func login(for plugin: PluginConfig) -> WebAuthSpec? {
        guard let a = plugin.authentication, let url = URL(string: a.loginUrl) else { return nil }
        return WebAuthSpec(title: "Log in to \(plugin.name)", startURL: url, html: nil, userAgent: a.userAgent,
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
        return WebAuthSpec(title: "Captcha for \(plugin.name)", startURL: start, html: html, userAgent: c?.userAgent,
                           completionURL: c?.completionUrl, allowedDomains: nil,
                           cookiesToFind: c?.cookiesToFind ?? [], cookiesExclOthers: c?.cookiesExclOthers ?? true,
                           hostAllowed: { plugin.allowsHost($0) })
    }
}
