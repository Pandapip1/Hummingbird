import Foundation

/// A setting declared in a plugin config. Values are stored as strings that the script receives after JSON parsing.
struct PluginSetting: Codable, Identifiable, Hashable {
    var name: String
    var description: String?
    var type: String?
    var `default`: String?
    var variable: String?
    var dependency: String?
    var warningDialog: String?
    var options: [String]?
    var isAdvanced: Bool?

    var key: String { variable ?? name }
    var id: String { key }
    var kind: String { (type ?? "").lowercased() }
}

struct PluginAuthConfig: Codable, Hashable {
    var loginUrl: String
    var completionUrl: String?
    var allowedDomains: [String]?
    var headersToFind: [String]?
    var cookiesToFind: [String]?
    var cookiesExclOthers: Bool?
    var userAgent: String?
    var loginButton: String?
    var domainHeadersToFind: [String: [String]]?
    var loginWarning: String?
}

struct PluginCaptchaConfig: Codable, Hashable {
    var captchaUrl: String?
    var completionUrl: String?
    var cookiesToFind: [String]?
    var userAgent: String?
    var cookiesExclOthers: Bool?
}

/// The plugin config JSON. Every key besides `name` is optional; defaults follow the plugin documentation.
struct PluginConfig: Codable, Hashable, Identifiable {
    var name: String
    var description: String = ""
    var author: String = ""
    var authorUrl: String = ""
    var repositoryUrl: String?
    var scriptUrl: String = ""
    var version: Int = -1
    var iconUrl: String?
    var id: String = UUID().uuidString
    var scriptSignature: String?
    var scriptPublicKey: String?
    var allowEval: Bool = false
    var allowUrls: [String] = []
    var packages: [String] = []
    var packagesOptional: [String] = []
    var settings: [PluginSetting] = []
    var captcha: PluginCaptchaConfig?
    var authentication: PluginAuthConfig?
    var sourceUrl: String?
    var constants: [String: String] = [:]
    var platformUrl: String?
    var subscriptionRateLimit: Int?
    var enableInSearch: Bool = true
    var enableInHome: Bool = true
    var enableInShorts: Bool = true
    var supportedClaimTypes: [Int] = []
    var primaryClaimFieldType: Int?
    var developerSubmitUrl: String?
    var allowAllHttpHeaderAccess: Bool = false
    var maxDownloadParallelism: Int = 0
    var changelog: [String: [String]]?

    enum CodingKeys: String, CodingKey {
        case name, description, author, authorUrl, repositoryUrl, scriptUrl, version, iconUrl, id
        case scriptSignature, scriptPublicKey, allowEval, allowUrls, packages, packagesOptional, settings
        case captcha, authentication, sourceUrl, constants, platformUrl, subscriptionRateLimit
        case enableInSearch, enableInHome, enableInShorts, supportedClaimTypes, primaryClaimFieldType
        case developerSubmitUrl, allowAllHttpHeaderAccess, maxDownloadParallelism, changelog
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorUrl = try c.decodeIfPresent(String.self, forKey: .authorUrl) ?? ""
        repositoryUrl = try c.decodeIfPresent(String.self, forKey: .repositoryUrl)
        scriptUrl = try c.decodeIfPresent(String.self, forKey: .scriptUrl) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? -1
        iconUrl = try c.decodeIfPresent(String.self, forKey: .iconUrl)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        scriptSignature = try c.decodeIfPresent(String.self, forKey: .scriptSignature)
        scriptPublicKey = try c.decodeIfPresent(String.self, forKey: .scriptPublicKey)
        allowEval = try c.decodeIfPresent(Bool.self, forKey: .allowEval) ?? false
        allowUrls = try c.decodeIfPresent([String].self, forKey: .allowUrls) ?? []
        packages = try c.decodeIfPresent([String].self, forKey: .packages) ?? []
        packagesOptional = try c.decodeIfPresent([String].self, forKey: .packagesOptional) ?? []
        settings = try c.decodeIfPresent([PluginSetting].self, forKey: .settings) ?? []
        captcha = try c.decodeIfPresent(PluginCaptchaConfig.self, forKey: .captcha)
        authentication = try c.decodeIfPresent(PluginAuthConfig.self, forKey: .authentication)
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl)
        constants = try c.decodeIfPresent([String: String].self, forKey: .constants) ?? [:]
        platformUrl = try c.decodeIfPresent(String.self, forKey: .platformUrl)
        subscriptionRateLimit = try c.decodeIfPresent(Int.self, forKey: .subscriptionRateLimit)
        enableInSearch = try c.decodeIfPresent(Bool.self, forKey: .enableInSearch) ?? true
        enableInHome = try c.decodeIfPresent(Bool.self, forKey: .enableInHome) ?? true
        enableInShorts = try c.decodeIfPresent(Bool.self, forKey: .enableInShorts) ?? true
        supportedClaimTypes = try c.decodeIfPresent([Int].self, forKey: .supportedClaimTypes) ?? []
        primaryClaimFieldType = try c.decodeIfPresent(Int.self, forKey: .primaryClaimFieldType)
        developerSubmitUrl = try c.decodeIfPresent(String.self, forKey: .developerSubmitUrl)
        allowAllHttpHeaderAccess = try c.decodeIfPresent(Bool.self, forKey: .allowAllHttpHeaderAccess) ?? false
        maxDownloadParallelism = try c.decodeIfPresent(Int.self, forKey: .maxDownloadParallelism) ?? 0
        changelog = try c.decodeIfPresent([String: [String]].self, forKey: .changelog)
    }

    // MARK: URLs

    /// Resolves a possibly-relative URL (script, icon) against `sourceUrl`.
    func resolve(_ ref: String?, base: URL?) -> URL? {
        guard let ref, !ref.isEmpty else { return nil }
        if let abs = URL(string: ref), abs.scheme != nil { return abs }
        guard let base else { return nil }
        return URL(string: ref, relativeTo: base)?.absoluteURL
    }

    // MARK: allow-list

    /// Whether the plugin may talk to `host`. "everywhere" allows all hosts; otherwise an entry matches the exact host,
    /// or, when it begins with ".", the domain and its subdomains.
    func allowsHost(_ host: String) -> Bool {
        let h = host.lowercased()
        let entries = allowUrls.map { $0.lowercased() }.filter { !$0.isEmpty }
        if entries.contains("everywhere") { return true }
        for e in entries {
            if e == h { return true }
            if e.hasPrefix("."), domainMatches(host: h, domain: e) { return true }
        }
        return false
    }

    /// Install-time warnings shown before the user accepts a plugin.
    func warnings(signatureValid: Bool?) -> [(title: String, detail: String)] {
        var out: [(title: String, detail: String)] = []
        if (scriptSignature ?? "").isEmpty || (scriptPublicKey ?? "").isEmpty {
            out.append(("Missing signature", "This plugin is not signed, so its code cannot be verified."))
        } else if signatureValid == false {
            out.append(("Invalid signature", "The script does not match its signature. It may have been tampered with."))
        }
        if allowEval { out.append(("Eval access", "The plugin may execute dynamically generated code.")) }
        if allowUrls.contains(where: { $0.lowercased() == "everywhere" }) {
            out.append(("Unrestricted web access", "The plugin may contact any website."))
        }
        if allowAllHttpHeaderAccess {
            out.append(("Unrestricted HTTP header access", "The plugin may read every response header, including cookies."))
        }
        return out
    }
}

/// `domain` may start with "." or "*."; matches the domain itself and all subdomains.
func domainMatches(host: String, domain: String) -> Bool {
    var d = domain.lowercased()
    if d.hasPrefix("*.") { d.removeFirst(2) }
    if d.hasPrefix(".") { d.removeFirst() }
    let h = host.lowercased()
    return h == d || h.hasSuffix("." + d)
}
