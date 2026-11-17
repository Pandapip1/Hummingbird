import Foundation
import XCTest
@testable import HummingbirdKit

/// grayjay://plugin/ links name a plugin's config URL and nothing else;
/// anything hostile or malformed is refused.
final class PluginInstallLinkTests: XCTestCase {
    private func config(_ text: String) -> String? {
        PluginInstallLink(text: text)?.configURL.absoluteString
    }

    func testReadsEncodedAndPlainConfigURLs() {
        XCTAssertEqual(config("grayjay://plugin/https%3A%2F%2Fplugins.grayjay.app%2FYoutube%2FYoutubeConfig.json"),
                       "https://plugins.grayjay.app/Youtube/YoutubeConfig.json")
        XCTAssertEqual(config("grayjay://plugin/https://example.com/Config.json"),
                       "https://example.com/Config.json")
        XCTAssertEqual(config("GRAYJAY://Plugin/http://192.168.1.20:8080/Config.json"),
                       "http://192.168.1.20:8080/Config.json", "scheme and host are case-insensitive; LAN http is allowed")
        XCTAssertEqual(PluginInstallLink(URL(string: "grayjay://plugin/https%3A%2F%2Fexample.com%2Fc.json")!)?
            .configURL.absoluteString, "https://example.com/c.json")
    }

    func testRefusesHostileOrMalformedLinks() {
        let hostile = [
            "grayjay://plugin/file:///etc/passwd",
            "grayjay://plugin/javascript:alert(1)",
            "grayjay://plugin/data:text/html,<script>alert(1)</script>",
            "grayjay://plugin/grayjay://plugin/https://example.com/c.json",
            "grayjay://plugin/https://user:secret@example.com/c.json",
            "grayjay://plugin/https://example.com/c.json\nhttps://evil.example/x",
            "grayjay://plugin/https://exa mple.com/c.json",
            "grayjay://plugin/https:///c.json",
            "grayjay://plugin/",
            "grayjay://plugin",
            "grayjay://channel/https://example.com/c.json",
            "grayjayx://plugin/https://example.com/c.json",
            "https://example.com/c.json",
            "grayjay://plugin/https://example.com/" + String(repeating: "a", count: 3000),
        ]
        for text in hostile {
            XCTAssertNil(PluginInstallLink(text: text), "accepted \(text)")
        }
    }

    /// Opening a link never installs anything: it asks Add Source to show the
    /// plugin, and only a valid link does.
    @MainActor
    func testOpeningALinkOnlyOffersThePlugin() {
        let model = makeTestAppModel()
        model.handleIncomingURL(URL(string: "grayjay://plugin/https%3A%2F%2Fexample.com%2Fc.json")!)
        XCTAssertEqual(model.incomingPluginInstall?.configURL.absoluteString, "https://example.com/c.json")
        XCTAssertTrue(model.plugins.installed.isEmpty)

        let other = makeTestAppModel()
        other.handleIncomingURL(URL(string: "grayjay://plugin/file:///etc/passwd")!)
        XCTAssertNil(other.incomingPluginInstall)
    }
}
