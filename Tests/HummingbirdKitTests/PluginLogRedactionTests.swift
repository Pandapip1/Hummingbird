import Foundation
import XCTest
@testable import HummingbirdKit

/// What reaches the plugin log (`PluginLog`) is `LogRedaction.text`: tokens,
/// cookies, addresses and recent searches are removed from plugin output.
final class PluginLogRedactionTests: XCTestCase {
    func testPluginLogTextLosesTokensCookiesAddressesAndSearches() {
        let query = "zebra migration documentary \(UUID().uuidString.prefix(6))"
        LogRedaction.remember([query])
        let line = """
        [TwitchPlugin] gql failed for "\(query)" from 192.168.1.20 \
        Cookie: auth-token=abc123; unique_id=xyz \
        Authorization: OAuth s3cr3tvalue url=https://gql.twitch.tv/gql?client_id=kimne78&token=deadbeef \
        jwt=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln
        """
        let text = LogRedaction.text(line).description

        XCTAssertTrue(text.contains("gql failed"), text)
        for secret in [query, "192.168.1.20", "abc123", "xyz", "s3cr3tvalue", "kimne78", "deadbeef", "eyJhbGci"] {
            XCTAssertFalse(text.contains(secret), "\(secret) leaked: \(text)")
        }
    }

    func testRecentSearchesAreForgottenAfterTwenty() {
        let first = "pangolin\(UUID().uuidString.prefix(6))"
        LogRedaction.remember([first])
        for n in 0..<20 { LogRedaction.remember(["otter\(n)x\(UUID().uuidString.prefix(6))"]) }
        XCTAssertTrue(LogRedaction.text("echo \(first)").description.contains(first))
    }

    /// Ordinary redaction (feed errors, hosts) is unaffected by searches;
    /// those pass their own terms.
    func testRememberedSearchesOnlyApplyToPluginLogText() {
        let query = "aardvark \(UUID().uuidString.prefix(6))"
        LogRedaction.remember([query])
        XCTAssertEqual(LogRedaction.redact("looking for \(query)"), "looking for \(query)")
    }
}
