import Foundation
import XCTest
@testable import ATProtoKit

final class OAuthCallbackTests: XCTestCase {
    // MARK: Callback parameters

    func testCallbackParametersAreFormDecoded() throws {
        let url = try XCTUnwrap(URL(string: "com.example.app:/oauth/callback?error=access_denied"
            + "&error_description=This+request+was+initiated+from+another+device%2C+100%25+%2B+more"
            + "&state=a%2Bb&iss=https%3A%2F%2Fbsky.social"))
        let parameters = OAuthCallbackParameters(url)
        XCTAssertEqual(parameters["error"], "access_denied")
        XCTAssertEqual(parameters["error_description"], "This request was initiated from another device, 100% + more")
        XCTAssertEqual(parameters["state"], "a+b", "an encoded plus is a plus, a bare plus a space")
        XCTAssertEqual(parameters["iss"], "https://bsky.social")
        XCTAssertNil(parameters["code"])
    }

    func testRepeatedCallbackParametersKeepTheFirst() throws {
        let parameters = OAuthCallbackParameters(try XCTUnwrap(URL(string: "app:/cb?code=one&code=two&empty=")))
        XCTAssertEqual(parameters["code"], "one")
        XCTAssertEqual(parameters["empty"], "")
    }

    func testAuthorizationDeniedReadsCleanly() {
        let mismatch = OAuthError.authorizationDenied(
            error: "access_denied", description: "This request was initiated from another device"
        )
        XCTAssertEqual(mismatch.localizedDescription,
                       "The account provider refused the sign-in: This request was initiated from another device (access_denied)")
        XCTAssertTrue(mismatch.isRequestDeviceMismatch)
        let declined = OAuthError.authorizationDenied(error: "access_denied", description: "Access denied")
        XCTAssertFalse(declined.isRequestDeviceMismatch, "a user declining must not be retried")
        XCTAssertEqual(OAuthError.authorizationDenied(error: "server_error", description: nil).localizedDescription,
                       "The account provider refused the sign-in (server_error).")
    }

    // MARK: Retry after a replayed load

    @MainActor
    func testADeviceMismatchIsRetriedOnceWithAFreshRequest() async throws {
        let flow = FakeFlow(outcomes: [
            .failure(OAuthError.authorizationDenied(error: "access_denied",
                                                    description: "This request was initiated from another device")),
            .success(()),
        ])
        let presenter = ImmediatePresenter()
        let credential = try await ATProtoOAuthAuthenticator(flow: flow, presenter: presenter)
            .signIn(identifier: "alice.example.com")
        XCTAssertEqual(credential.session.account.rawValue, "did:plc:alice")
        let begun = await flow.begun
        XCTAssertEqual(begun, 2, "the retry starts a new authorization request")
        XCTAssertEqual(presenter.presented.count, 2)
        XCTAssertNotEqual(presenter.presented[0], presenter.presented[1])
    }

    @MainActor
    func testADeviceMismatchIsRetriedOnlyOnce() async {
        let mismatch = OAuthError.authorizationDenied(error: "access_denied",
                                                      description: "This request was initiated from another device")
        let flow = FakeFlow(outcomes: [.failure(mismatch), .failure(mismatch), .success(())])
        do {
            _ = try await ATProtoOAuthAuthenticator(flow: flow, presenter: ImmediatePresenter())
                .signIn(identifier: "alice.example.com")
            XCTFail("Expected the second mismatch to surface")
        } catch let error as OAuthError {
            XCTAssertTrue(error.isRequestDeviceMismatch)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        let begun = await flow.begun
        XCTAssertEqual(begun, 2)
    }

    @MainActor
    func testOtherDenialsAreNotRetried() async {
        let flow = FakeFlow(outcomes: [
            .failure(OAuthError.authorizationDenied(error: "access_denied", description: "Access denied")),
            .success(()),
        ])
        do {
            _ = try await ATProtoOAuthAuthenticator(flow: flow, presenter: ImmediatePresenter())
                .signIn(identifier: "alice.example.com")
            XCTFail("Expected the denial to surface")
        } catch {}
        let begun = await flow.begun
        XCTAssertEqual(begun, 1)
    }
}

/// Begins a fresh request each time and completes with scripted outcomes.
private actor FakeFlow: OAuthAuthorizationFlow {
    private var outcomes: [Result<Void, any Error>]
    private(set) var begun = 0

    init(outcomes: [Result<Void, any Error>]) { self.outcomes = outcomes }

    func begin(identifier: String) async throws -> OAuthAuthorizationRequest {
        begun += 1
        return OAuthAuthorizationRequest(
            authorizationURL: URL(string: "https://auth.example/authorize?request_uri=req-\(begun)")!,
            callback: .customScheme("com.example.app"), state: "state-\(begun)", verifier: "v",
            issuer: URL(string: "https://auth.example")!, pds: URL(string: "https://pds.example")!,
            account: DID(rawValue: "did:plc:alice")!, loginHint: nil, dpopSigner: DPoPSigner(), dpopNonce: nil
        )
    }

    func complete(_ request: OAuthAuthorizationRequest, callbackURL: URL) async throws -> ATProtoOAuthCredential {
        try outcomes.removeFirst().get()
        let session = ATProtoOAuthSession(
            account: request.account, handle: nil, pds: request.pds, authorizationServer: request.issuer,
            accessToken: SecureBytes(copyingUTF8: "a"), refreshToken: nil, scope: "atproto",
            tokenType: "DPoP", expiresAt: nil
        )
        return ATProtoOAuthCredential(session: session, dpopPrivateKey: await request.dpopSigner.exportForStorage())
    }
}

@MainActor
private final class ImmediatePresenter: ATProtoOAuthPresenter {
    var presented: [URL] = []
    func authorize(_ authorizationURL: URL, callback: OAuthCallbackMatcher) async throws -> URL {
        presented.append(authorizationURL)
        return URL(string: "com.example.app:/cb?code=c")!
    }
}
