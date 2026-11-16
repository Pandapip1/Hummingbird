import XCTest
@testable import ATProtoKit

final class LoginHintTests: XCTestCase {
    func testHandlesAreNormalizedAsTyped() {
        XCTAssertEqual(ATProtoIdentityResolver.normalizedHandle("@pandapip1.bsky.social"), "pandapip1.bsky.social")
        XCTAssertEqual(ATProtoIdentityResolver.normalizedHandle("  @Alice.Example.COM \n"), "alice.example.com")
        XCTAssertEqual(ATProtoIdentityResolver.normalizedHandle("alice.example.com"), "alice.example.com")
    }

    /// The authorization server rejects "@pandapip1.bsky.social" as an invalid
    /// login hint, so the hint must be the resolved handle, not the input.
    func testLoginHintIsTheResolvedHandle() throws {
        let identity = ResolvedIdentity(
            did: try XCTUnwrap(DID(rawValue: "did:plc:example")),
            handle: ATProtoIdentityResolver.normalizedHandle("@Pandapip1.bsky.social"),
            pds: try XCTUnwrap(URL(string: "https://pds.example.com"))
        )
        XCTAssertEqual(ATProtoOAuthClient.loginHint(for: identity), "pandapip1.bsky.social")
    }

    func testLoginHintFallsBackToTheDID() throws {
        let identity = ResolvedIdentity(
            did: try XCTUnwrap(DID(rawValue: "did:plc:example")),
            handle: nil,
            pds: try XCTUnwrap(URL(string: "https://pds.example.com"))
        )
        XCTAssertEqual(ATProtoOAuthClient.loginHint(for: identity), "did:plc:example")
    }
}
