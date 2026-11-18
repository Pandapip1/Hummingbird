#if canImport(WebKit) && (os(macOS) || os(iOS) || os(visionOS))
import Foundation
import Synchronization
import XCTest
@testable import HummingbirdKit

/// The plugin browser is a hidden page that must keep running while a plugin
/// uses it, so it may not outlive that use: after an idle period the page is
/// torn down, and the plugin's next script transparently reloads it from the
/// URL and on-load scripts the plugin supplied.
final class PluginBrowserPackageTests: XCTestCase {
    private final class Results: Sendable {
        private let values = Mutex<[String: String]>([:])
        func set(_ id: String, _ value: String) { values.withLock { $0[id] = value } }
        func get(_ id: String) -> String? { values.withLock { $0[id] } }
    }

    /// A plugin that may reach nothing: these pages are `data:` documents.
    private static func policy() throws -> PluginNetworkPolicy {
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(#"{"name":"Browser test","allowUrls":[]}"#.utf8))
        return PluginNetworkPolicy(config: config, approvals: [])
    }

    func testIdlePageIsTornDownAndReloadedForTheNextScript() async throws {
        let results = Results()
        let browser = PluginBrowserPackage(policy: try Self.policy(), proxy: nil, idleTimeout: .milliseconds(500)) { results.set($0, $1) }
        defer { browser.close() }
        let page = "<!doctype html><script>window.pageState = 'ready';</script>"
        let url = "data:text/html;charset=utf-8," + (page.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")

        func run(_ id: String) async throws -> String? {
            _ = await Task.detached {
                browser.call("runWithReturn", payload: #"{"script":"window.hook + ':' + window.pageState","id":"\#(id)"}"#)
            }.value
            for _ in 0..<100 where results.get(id) == nil { try await Task.sleep(for: .milliseconds(50)) }
            return results.get(id)
        }

        let loaded = await Task.detached {
            _ = browser.call("initialize", payload: "")
            _ = browser.call("addScriptOnLoad", payload: "window.hook = 'hooked';")
            _ = browser.call("load", payload: url)
            return browser.call("waitTillLoaded", payload: "10000")
        }.value
        XCTAssertEqual(loaded, "1")
        let first = try await run("first")
        XCTAssertEqual(first, "hooked:ready")
        XCTAssertTrue(browser.hasLivePage)

        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(browser.hasLivePage, "an idle plugin page must not stay alive")

        let second = try await run("second")
        XCTAssertEqual(second, "hooked:ready", "the next script must run in a reloaded page with the plugin's on-load scripts")
        XCTAssertTrue(browser.hasLivePage)
    }

    func testInitializeForgetsThePreviousPage() async throws {
        let browser = PluginBrowserPackage(policy: try Self.policy(), proxy: nil) { _, _ in }
        defer { browser.close() }
        _ = await Task.detached {
            _ = browser.call("initialize", payload: "")
            _ = browser.call("load", payload: "data:text/html,x")
            _ = browser.call("initialize", payload: "")
            _ = browser.call("run", payload: #"{"script":"1","id":"x"}"#)
        }.value
        XCTAssertFalse(browser.hasLivePage, "a script must not reload a page the plugin discarded")
    }
}
#endif
