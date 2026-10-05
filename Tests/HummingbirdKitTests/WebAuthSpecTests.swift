import XCTest
@testable import HummingbirdKit

final class WebAuthSpecTests: XCTestCase {
    func testCompletionQueryWildcardMatchesOnlySameEndpoint() throws {
        let spec = WebAuthSpec(title: "Auth", completionURL: "https://example.com/auth?*", hostAllowed: { _ in true })
        for raw in ["https://EXAMPLE.com:443/auth?code=1#done", "https://example.com/auth"] {
            XCTAssertTrue(spec.matchesCompletion(try XCTUnwrap(URL(string: raw))), raw)
        }
        for raw in ["https://example.com/authorize", "https://example.com/auth-evil",
                    "https://example.com/auth/child?code=1", "http://example.com/auth",
                    "https://example.com:8443/auth", "https://example.com.evil/auth"] {
            XCTAssertFalse(spec.matchesCompletion(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testCompletionWithoutWildcardPreservesExactMatch() throws {
        let spec = WebAuthSpec(title: "Auth", completionURL: "https://example.com/auth?ok=1#done", hostAllowed: { _ in true })
        XCTAssertTrue(spec.matchesCompletion(try XCTUnwrap(URL(string: "https://EXAMPLE.com:443/auth?ok=1#done"))))
        XCTAssertFalse(spec.matchesCompletion(try XCTUnwrap(URL(string: "https://example.com/auth?ok=0"))))
        XCTAssertFalse(spec.matchesCompletion(try XCTUnwrap(URL(string: "https://example.com/auth?ok=1#wrong"))))
        XCTAssertFalse(spec.matchesCompletion(try XCTUnwrap(URL(string: "https://example.com/auth?ok=1&extra=1#done"))))
    }

    func testCompletionRequiresHeadersFromThatRequest() throws {
        let spec = WebAuthSpec(title: "Auth", headersToFind: ["Authorization"],
                               domainHeadersToFind: [".example.com": ["X-Session"]], hostAllowed: { _ in true })
        let url = try XCTUnwrap(URL(string: "https://example.com/auth"))
        XCTAssertFalse(spec.hasCompletionHeaders([:], url: url))
        XCTAssertFalse(spec.hasCompletionHeaders(["Authorization": "undefined", "X-Session": "session"], url: url))
        XCTAssertFalse(spec.hasCompletionHeaders(["authorization": "Bearer token"], url: url))
        XCTAssertTrue(spec.hasCompletionHeaders(["authorization": "Bearer token", "x-session": "session"], url: url))
    }

    func testCompletionNormalizesEscapesWithoutChangingQueryStructure() throws {
        let spec = WebAuthSpec(title: "Auth", completionURL: "https://example.com/auth?v=%2f%26next#%2f", hostAllowed: { _ in true })
        XCTAssertTrue(spec.matchesCompletion(try XCTUnwrap(URL(string: "https://EXAMPLE.com:443/auth?v=%2F%26next#%2F"))))
        XCTAssertFalse(spec.matchesCompletion(try XCTUnwrap(URL(string: "https://example.com/auth?v=%2F&next#%2F"))))
    }
}
