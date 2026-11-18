import Foundation
import XCTest
@testable import HummingbirdKit

/// The plugin browser and the plugin sign-in/captcha sheets are web views a
/// plugin steers. They must stay within the plugin's allow-list (and, for a
/// non-public host, the user's exact approval), never become a general web
/// browser, open no windows, and hand back only bounded data. These tests
/// exercise the pure decisions those views apply; no network is involved.
final class PluginWebContainmentTests: XCTestCase {
    private func config(_ json: String) throws -> PluginConfig {
        try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
    }

    private func policy(_ allowUrls: [String], approvals: [LocalHostApproval] = []) throws -> PluginNetworkPolicy {
        let encoded = String(decoding: try JSONEncoder().encode(allowUrls), as: UTF8.self)
        return PluginNetworkPolicy(config: try config(#"{"name":"Web","allowUrls":\#(encoded)}"#), approvals: approvals)
    }

    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text), text) }

    private func approval(_ host: String, _ port: Int, _ cidr: String) throws -> LocalHostApproval {
        LocalHostApproval(host: host, port: port, networks: [try XCTUnwrap(IPNetwork(cidr: cidr))])
    }

    // MARK: plugin browser navigation

    func testBrowserNavigatesOnlyToAllowListedHTTP() throws {
        let policy = try policy([".example.com", "api.other.net:8443"])
        let allowed = ["https://www.example.com/x", "http://example.com/", "https://api.other.net:8443/v1",
                       "about:blank", "about:srcdoc", "data:text/html,hello"]
        let refused = ["https://evil.net/", "https://example.com.evil.net/", "https://api.other.net/",
                       "file:///etc/passwd", "javascript:alert(1)", "hummingbird://settings", "grayjay://plugin/x",
                       "ftp://example.com/", "blob:https://www.example.com/1234", "about:config", "tel:123"]
        for text in allowed {
            XCTAssertTrue(PluginBrowserPolicy.allowsNavigation(to: try url(text), policy: policy), text)
        }
        for text in refused {
            XCTAssertFalse(PluginBrowserPolicy.allowsNavigation(to: try url(text), policy: policy), text)
        }
        XCTAssertFalse(PluginBrowserPolicy.allowsNavigation(to: nil, policy: policy))
    }

    func testBrowserReachesLocalHostsOnlyWithTheExactApproval() throws {
        let entries = ["192.168.1.20:8096", "nas.local:8096", "127.0.0.1"]
        let unapproved = try policy(entries)
        for text in ["http://192.168.1.20:8096/", "http://nas.local:8096/", "http://127.0.0.1/"] {
            XCTAssertFalse(PluginBrowserPolicy.allowsNavigation(to: try url(text), policy: unapproved), text)
        }
        let approved = try policy(entries, approvals: [
            try approval("192.168.1.20", 8096, "192.168.1.20"),
            try approval("nas.local", 8096, "192.168.1.21"),
        ])
        XCTAssertTrue(PluginBrowserPolicy.allowsNavigation(to: try url("http://192.168.1.20:8096/web"), policy: approved))
        XCTAssertTrue(PluginBrowserPolicy.allowsNavigation(to: try url("http://nas.local:8096/web"), policy: approved))
        XCTAssertFalse(PluginBrowserPolicy.allowsNavigation(to: try url("http://192.168.1.20:8097/"), policy: approved),
                       "the approval is for one port")
        XCTAssertFalse(PluginBrowserPolicy.allowsNavigation(to: try url("http://127.0.0.1/"), policy: approved))
    }

    func testEverywhereStillExcludesNonPublicAndMetadataAddresses() throws {
        let policy = try policy(["everywhere", "169.254.169.254"],
                                approvals: [try approval("169.254.169.254", 80, "169.254.169.254")])
        XCTAssertTrue(PluginBrowserPolicy.allowsNavigation(to: try url("https://anything.example/"), policy: policy))
        for text in ["http://169.254.169.254/latest/meta-data/", "http://10.0.0.1/", "http://[::1]/", "http://localhost:8080/",
                     "http://100.101.102.103/", "http://[fd7a:115c:a1e0::1]/", "http://router.home.arpa/"] {
            XCTAssertFalse(PluginBrowserPolicy.allowsNavigation(to: try url(text), policy: policy), text)
        }
    }

    // MARK: content rules

    /// Applies WebKit content-rule semantics (in order; `block` blocks,
    /// `ignore-previous-rules` undoes earlier matches) to one resource.
    private func blocked(_ resource: String, type: String = "script", rules json: String) throws -> Bool {
        let rules = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        var isBlocked = false
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let action = try XCTUnwrap(rule["action"] as? [String: Any])
            let filter = try XCTUnwrap(trigger["url-filter"] as? String)
            if let types = trigger["resource-type"] as? [String], !types.contains(type) { continue }
            let regex = try NSRegularExpression(pattern: filter, options: [.caseInsensitive])
            let range = NSRange(resource.startIndex..., in: resource)
            guard regex.firstMatch(in: resource, range: range) != nil else { continue }
            switch action["type"] as? String {
            case "block": isBlocked = true
            case "ignore-previous-rules": isBlocked = false
            default: XCTFail("unexpected action \(action)")
            }
        }
        return isBlocked
    }

    func testContentRulesAllowOnlyAllowListedSubresources() throws {
        let rules = PluginBrowserPolicy.contentRules(for: try policy([".example.com", "cdn.other.net"]))
        for allowed in ["https://www.example.com/a.js", "https://example.com/b.js", "https://cdn.other.net/c.js",
                        "wss://live.example.com/socket", "data:text/javascript,1", "blob:https://www.example.com/1"] {
            XCTAssertFalse(try blocked(allowed, rules: rules), allowed)
        }
        for refused in ["https://evil.net/x.js", "https://example.com.evil.net/x.js", "https://example.com:pw@evil.net/x.js",
                        "https://sub.cdn.other.net/x.js", "http://127.0.0.1:8080/x", "http://192.168.0.1/x",
                        "http://[::1]/x", "http://nas.local/x", "ftp://example.com/x"] {
            XCTAssertTrue(try blocked(refused, rules: rules), refused)
        }
        XCTAssertTrue(try blocked("https://www.example.com/x.png", type: "image", rules: rules),
                      "nothing on the hidden page is ever seen")
    }

    func testContentRulesForEverywhereStillBlockNonPublicLiterals() throws {
        let rules = PluginBrowserPolicy.contentRules(for: try policy(["everywhere"]))
        XCTAssertFalse(try blocked("https://anything.net/x.js", rules: rules))
        XCTAssertFalse(try blocked("http://100.200.1.1/x.js", rules: rules), "100.200/16 is public")
        for refused in ["http://10.1.2.3/x", "http://100.100.1.1/x", "http://172.20.0.1:3000/x", "http://169.254.169.254/x",
                        "http://0.0.0.0/x", "http://[fe80::1]/x", "http://printer.local/x", "http://localhost:9000/x",
                        "http://224.0.0.251/x"] {
            XCTAssertTrue(try blocked(refused, rules: rules), refused)
        }
    }

    func testContentRulesAdmitApprovedLocalHostOnly() throws {
        let rules = PluginBrowserPolicy.contentRules(for: try policy(
            ["192.168.1.20:8096"], approvals: [try approval("192.168.1.20", 8096, "192.168.1.20")]
        ))
        XCTAssertFalse(try blocked("http://192.168.1.20:8096/web/main.js", rules: rules))
        XCTAssertTrue(try blocked("http://192.168.1.21:8096/web/main.js", rules: rules))
        XCTAssertTrue(try blocked("http://192.168.1.20:22/", rules: rules))
    }

    func testContentRuleIdentifierFollowsThePolicy() throws {
        let a = PluginBrowserPolicy.contentRules(for: try policy([".example.com"]))
        let b = PluginBrowserPolicy.contentRules(for: try policy([".other.com"]))
        XCTAssertEqual(PluginBrowserPolicy.ruleListIdentifier(for: a), PluginBrowserPolicy.ruleListIdentifier(for: a))
        XCTAssertNotEqual(PluginBrowserPolicy.ruleListIdentifier(for: a), PluginBrowserPolicy.ruleListIdentifier(for: b))
    }

    // MARK: bounds

    func testScriptsAndCallbacksAreBounded() {
        XCTAssertTrue(PluginBrowserPolicy.acceptsScript("1 + 1"))
        XCTAssertFalse(PluginBrowserPolicy.acceptsScript(String(repeating: "x", count: PluginBrowserPolicy.maximumScriptBytes + 1)))
        XCTAssertEqual(PluginBrowserPolicy.boundedCallback(id: "a", value: "v")?.value, "v")
        let huge = String(repeating: "y", count: PluginBrowserPolicy.maximumCallbackBytes + 1)
        XCTAssertEqual(PluginBrowserPolicy.boundedCallback(id: "a", value: huge)?.value, "", "an oversized value is dropped")
        XCTAssertNil(PluginBrowserPolicy.boundedCallback(id: "", value: "v"))
        XCTAssertNil(PluginBrowserPolicy.boundedCallback(id: String(repeating: "i", count: 300), value: "v"))
    }

    // MARK: sign-in and captcha sheets

    private let signInConfig = #"""
    {"name":"Example","allowUrls":[".example.com","everywhere"],
     "authentication":{"loginUrl":"https://accounts.example.com/login","completionUrl":"https://www.example.com/done",
                       "allowedDomains":[".example.com"],"cookiesToFind":["SID"]}}
    """#

    func testSignInSheetStaysWithinItsDomains() throws {
        let spec = try XCTUnwrap(WebAuthSpec.login(for: try config(signInConfig)))
        for text in ["https://accounts.example.com/next", "https://www.example.com/done", "about:blank"] {
            XCTAssertTrue(spec.allowsNavigation(to: try url(text)), text)
        }
        // "everywhere" lets the plugin's HTTP reach any public host, but never
        // turns its sign-in sheet into a browser.
        for text in ["https://evil.net/", "https://example.com.evil.net/", "javascript:alert(1)", "file:///etc/hosts",
                     "data:text/html,form", "http://169.254.169.254/", "http://192.168.1.1/"] {
            XCTAssertFalse(spec.allowsNavigation(to: try url(text)), text)
        }
    }

    func testSignInSheetExportsOnlyItsOwnDomainsCredentials() throws {
        let spec = try XCTUnwrap(WebAuthSpec.login(for: try config(signInConfig)))
        XCTAssertTrue(spec.mayExportCredentials(for: ".example.com"), "a parent-domain sign-in cookie")
        XCTAssertTrue(spec.mayExportCredentials(for: "accounts.example.com"))
        XCTAssertFalse(spec.mayExportCredentials(for: "tracker.net"), "third-party cookies stay in the sheet's store")
        XCTAssertFalse(spec.mayExportCredentials(for: ""))
    }

    func testSignInSheetOpensALocalHostOnlyWhenApproved() throws {
        let lan = try config(#"""
        {"name":"LAN","allowUrls":["192.168.1.30:8096"],
         "authentication":{"loginUrl":"http://192.168.1.30:8096/login","cookiesToFind":["token"]}}
        """#)
        XCTAssertNil(WebAuthSpec.login(for: lan), "a local login page needs the user's approval")
        let spec = try XCTUnwrap(WebAuthSpec.login(for: lan, approvals: [try approval("192.168.1.30", 8096, "192.168.1.30")]))
        XCTAssertTrue(spec.allowsNavigation(to: try url("http://192.168.1.30:8096/next")))
        XCTAssertFalse(spec.allowsNavigation(to: try url("http://192.168.1.31:8096/")))
        let file = try config(#"{"name":"File","authentication":{"loginUrl":"file:///etc/passwd"}}"#)
        XCTAssertNil(WebAuthSpec.login(for: file))
    }

    func testCaptchaURLFromThePluginMustBeItsOwn() throws {
        let plugin = try config(#"{"name":"Example","allowUrls":[".example.com"]}"#)
        XCTAssertNil(WebAuthSpec.captcha(for: plugin, url: "https://phish.evil.net/login", body: nil),
                     "a plugin cannot open an arbitrary page as its captcha")
        XCTAssertNil(WebAuthSpec.captcha(for: plugin, url: "file:///etc/passwd", body: nil))
        let spec = try XCTUnwrap(WebAuthSpec.captcha(for: plugin, url: "https://www.example.com/captcha", body: nil))
        XCTAssertFalse(spec.allowsNavigation(to: try url("https://phish.evil.net/")))
        let everywhere = try config(#"{"name":"Any","allowUrls":["everywhere"]}"#)
        XCTAssertNil(WebAuthSpec.captcha(for: everywhere, url: "https://phish.evil.net/", body: nil),
                     "\"everywhere\" does not make any page a captcha page")
    }
}
