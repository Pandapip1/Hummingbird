import Foundation
import XCTest
@testable import ATProtoKit

final class OAuthScopeSupportTests: XCTestCase {
    private let space = "space:com.example.profile?authority=self&skey=self&manage=create"
    /// What bsky.social advertises.
    private let bluesky = ["atproto", "transition:email", "transition:generic", "transition:chat.bsky"]

    // MARK: Availability

    func testExactMatchesAreAdvertised() {
        XCTAssertEqual(OAuthScopeAvailability.of("atproto", scopesSupported: bluesky), .advertised)
        XCTAssertEqual(OAuthScopeAvailability.of("transition:generic", scopesSupported: bluesky), .advertised)
        XCTAssertEqual(OAuthScopeAvailability.of(space, scopesSupported: ["atproto", space]), .advertised)
    }

    func testAListedResourceCoversItsParameterizedScopes() {
        XCTAssertEqual(OAuthScopeAvailability.of(space, scopesSupported: ["atproto", "space"]), .advertised)
        XCTAssertEqual(OAuthScopeAvailability.of(space, scopesSupported: ["atproto", "space:com.other.thing"]), .advertised)
        XCTAssertEqual(OAuthScopeAvailability.of(space, scopesSupported: ["atproto", "space?authority=self"]), .advertised)
        XCTAssertEqual(OAuthScopeAvailability.of("space?type=x", scopesSupported: ["space"]), .advertised)
    }

    func testPrefixMatchingNeedsTheWholeResourceName() {
        XCTAssertEqual(OAuthScopeAvailability.of(space, scopesSupported: ["atproto", "spaces"]), .notAdvertised)
        XCTAssertEqual(OAuthScopeAvailability.of(space, scopesSupported: ["atproto", "spaceship:x"]), .notAdvertised)
        XCTAssertEqual(OAuthScopeAvailability.of(space, scopesSupported: ["atproto", "spa"]), .notAdvertised)
    }

    func testTransitionScopesOnlyMatchExactly() {
        XCTAssertEqual(OAuthScopeAvailability.of("transition:other", scopesSupported: bluesky), .notAdvertised)
    }

    func testAnUnlistedSpaceScopeIsNotAdvertisedByBluesky() {
        XCTAssertEqual(OAuthScopeAvailability.of(space, scopesSupported: bluesky), .notAdvertised)
    }

    /// The reference server supports the permission spec's resources
    /// without listing them ("other atproto scopes can't be enumerated").
    func testUnlistedPermissionSpecResourcesAreUnknown() {
        XCTAssertEqual(OAuthScopeAvailability.of("repo:app.bsky.feed.post", scopesSupported: bluesky), .unknown)
        XCTAssertEqual(OAuthScopeAvailability.of("rpc:app.bsky.actor.getProfile?aud=*", scopesSupported: bluesky), .unknown)
        XCTAssertEqual(OAuthScopeAvailability.of("include:com.example.set", scopesSupported: bluesky), .unknown)
    }

    func testWithoutScopesSupportedEverythingIsUnknown() {
        XCTAssertEqual(OAuthScopeAvailability.of(space, scopesSupported: nil), .unknown)
        XCTAssertEqual(OAuthScopeAvailability.of("atproto", scopesSupported: nil), .unknown)
    }

    // MARK: Preparing a request

    private func prepare(_ scopesSupported: [String]?, scopes: [String]? = nil,
                         required: Set<String> = ["atproto"]) throws -> ATProtoPreparedAuthorization {
        try ATProtoPreparedAuthorization(
            identity: testIdentity(), metadata: testMetadata(scopesSupported: scopesSupported),
            scopes: scopes ?? ["atproto", space], requiredScopes: required
        )
    }

    func testSupportedOptionalScopeIsRequested() throws {
        let prepared = try prepare(["atproto", "space"])
        XCTAssertEqual(prepared.requestedScopes, ["atproto", space])
        XCTAssertEqual(prepared.unsupportedScopes, [])
    }

    func testUnsupportedOptionalScopeIsReportedAndNotRequested() throws {
        let prepared = try prepare(bluesky)
        XCTAssertEqual(prepared.requestedScopes, ["atproto"])
        XCTAssertEqual(prepared.unsupportedScopes, [space])
    }

    func testUnsupportedRequiredScopeFailsBeforeAnythingOpens() {
        XCTAssertThrowsError(try prepare(["transition:generic"])) { error in
            guard case OAuthError.requiredScopesUnsupported(_, let scopes) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(scopes, ["atproto"])
            XCTAssertEqual(error.localizedDescription,
                           "auth.example doesn’t support the permissions this app needs: atproto.")
        }
        XCTAssertThrowsError(try prepare(bluesky, required: ["atproto", space]))
    }

    func testMissingScopesSupportedRequestsEverything() throws {
        let prepared = try prepare(nil)
        XCTAssertEqual(prepared.requestedScopes, ["atproto", space])
        XCTAssertEqual(prepared.unsupportedScopes, [])
    }

    func testMetadataWithoutScopesSupportedDecodes() throws {
        let json = Data("""
        {"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/a",
         "token_endpoint":"https://auth.example/t","pushed_authorization_request_endpoint":"https://auth.example/p"}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(OAuthAuthorizationServerMetadata.self, from: json).scopesSupported)
    }

    // MARK: Authenticator

    @MainActor
    func testTheAppSeesThePreparedScopesBeforeAnythingOpens() async throws {
        let flow = FakeFlow(scopesSupported: bluesky, scopes: ["atproto", space])
        let presenter = ImmediatePresenter()
        var seen: [String] = []
        _ = try await ATProtoOAuthAuthenticator(flow: flow, presenter: presenter).signIn(identifier: "alice") { prepared in
            seen = prepared.unsupportedScopes
            XCTAssertTrue(presenter.presented.isEmpty, "nothing is shown before the app decides")
            return true
        }
        XCTAssertEqual(seen, [space])
        let requested = await flow.requestedScopes
        XCTAssertEqual(requested, [["atproto"]], "the unsupported scope is not requested")
        XCTAssertEqual(presenter.presented.count, 1)
    }

    @MainActor
    func testDecliningOpensNothing() async {
        let flow = FakeFlow(scopesSupported: bluesky, scopes: ["atproto", space])
        let presenter = ImmediatePresenter()
        do {
            _ = try await ATProtoOAuthAuthenticator(flow: flow, presenter: presenter).signIn(identifier: "alice") { _ in false }
            XCTFail("Expected cancellation")
        } catch OAuthError.cancelled {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let begun = await flow.begun
        XCTAssertEqual(begun, 0, "no authorization request is pushed")
        XCTAssertTrue(presenter.presented.isEmpty)
    }
}
