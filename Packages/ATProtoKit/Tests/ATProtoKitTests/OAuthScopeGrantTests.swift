import Foundation
import XCTest
@testable import ATProtoKit

final class OAuthScopeGrantTests: XCTestCase {
    private func token(scope: String, sub: String = "did:plc:alice", type: String = "DPoP") -> OAuthTokenResponse {
        OAuthTokenResponse(accessToken: "a", refreshToken: nil, tokenType: type, expiresIn: 60, scope: scope, sub: sub)
    }

    private let alice = DID(rawValue: "did:plc:alice")!

    func testAReducedGrantIsAccepted() throws {
        XCTAssertNoThrow(try ATProtoOAuthClient.validate(token(scope: "atproto"), account: alice, requiredScopes: ["atproto"]))
    }

    func testAGrantWithoutAtprotoIsRejected() {
        XCTAssertThrowsError(try ATProtoOAuthClient.validate(
            token(scope: "space:com.example.profile"), account: alice, requiredScopes: []
        ), "atproto is required even when the client does not list it")
    }

    func testARequiredOptionalScopeMustBeGranted() {
        XCTAssertThrowsError(try ATProtoOAuthClient.validate(
            token(scope: "atproto"), account: alice, requiredScopes: ["atproto", "transition:generic"]
        ))
    }

    func testATokenForAnotherAccountIsRejected() {
        XCTAssertThrowsError(try ATProtoOAuthClient.validate(
            token(scope: "atproto", sub: "did:plc:mallory"), account: alice, requiredScopes: ["atproto"]
        ))
    }

    func testABearerTokenIsRejected() {
        XCTAssertThrowsError(try ATProtoOAuthClient.validate(
            token(scope: "atproto", type: "Bearer"), account: alice, requiredScopes: ["atproto"]
        ))
    }

    func testConfigurationAlwaysRequiresAtproto() throws {
        let configuration = OAuthClientConfiguration(
            clientID: try XCTUnwrap(URL(string: "https://app.example/client.json")),
            redirectURI: try XCTUnwrap(URL(string: "com.example.app:/cb")),
            scopes: ["atproto", "space:x"], requiredScopes: []
        )
        XCTAssertEqual(configuration.requiredScopes, ["atproto"])
        let legacy = Data(#"{"clientID":"https://app.example/client.json","redirectURI":"com.example.app:/cb","scopes":["atproto"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(OAuthClientConfiguration.self, from: legacy).requiredScopes, ["atproto"])
    }

    func testSessionReportsGrantedScopes() throws {
        let session = ATProtoOAuthSession(
            account: alice, handle: nil, pds: try XCTUnwrap(URL(string: "https://pds.example")),
            authorizationServer: try XCTUnwrap(URL(string: "https://auth.example")),
            accessToken: SecureBytes(copyingUTF8: "a"), refreshToken: nil,
            scope: "atproto  space:com.example.profile", tokenType: "DPoP", expiresAt: nil
        )
        XCTAssertEqual(session.grantedScopes, ["atproto", "space:com.example.profile"])
    }
}
