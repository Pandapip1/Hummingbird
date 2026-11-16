import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ATProtoKit
import XCTest

/// AT Protocol requests carry no ambient state: unless a session is
/// injected, each client has its own ephemeral session with no cookie jar,
/// credential store or cache, never `URLSession.shared`.
final class EphemeralSessionTests: XCTestCase {
    func testDefaultConfigurationKeepsNothing() {
        let configuration = ATProtoHTTPSession.makeConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testClientsDefaultToTheirOwnEphemeralSessions() throws {
        let configuration = OAuthClientConfiguration(
            clientID: try XCTUnwrap(URL(string: "https://client.example/metadata.json")),
            redirectURI: try XCTUnwrap(URL(string: "com.example:/callback")),
            scopes: ["atproto"]
        )
        let oauth = ATProtoOAuthClient(configuration: configuration)
        let otherOAuth = ATProtoOAuthClient(configuration: configuration)
        let xrpc = XRPCClient(service: try XCTUnwrap(URL(string: "https://pds.example")))
        let resolver = ATProtoIdentityResolver()
        let resolverSession = try XCTUnwrap(resolver.session)

        for session in [oauth.session, otherOAuth.session, xrpc.session, resolverSession] {
            XCTAssertFalse(session === URLSession.shared)
            XCTAssertNil(session.configuration.httpCookieStorage)
            XCTAssertNil(session.configuration.urlCache)
        }
        XCTAssertFalse(oauth.session === otherOAuth.session, "Clients do not share a session")
    }

    func testAnInjectedSessionIsUsed() {
        let injected = URLSession(configuration: .ephemeral)
        XCTAssertTrue(ATProtoIdentityResolver(session: injected).session === injected)
    }
}
