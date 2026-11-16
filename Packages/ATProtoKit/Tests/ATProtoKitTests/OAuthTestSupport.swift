import Foundation
@testable import ATProtoKit

func testMetadata(scopesSupported: [String]?) -> OAuthAuthorizationServerMetadata {
    OAuthAuthorizationServerMetadata(
        issuer: URL(string: "https://auth.example")!,
        authorizationEndpoint: URL(string: "https://auth.example/oauth/authorize")!,
        tokenEndpoint: URL(string: "https://auth.example/oauth/token")!,
        pushedAuthorizationRequestEndpoint: URL(string: "https://auth.example/oauth/par")!,
        scopesSupported: scopesSupported
    )
}

func testIdentity() -> ResolvedIdentity {
    ResolvedIdentity(did: DID(rawValue: "did:plc:alice")!, handle: "alice.example.com",
                     pds: URL(string: "https://pds.example")!)
}

/// Prepares and begins a fresh request each time, and completes with
/// scripted outcomes.
actor FakeFlow: OAuthAuthorizationFlow {
    private var outcomes: [Result<Void, any Error>]
    private let scopesSupported: [String]?
    private let scopes: [String]
    private(set) var prepared = 0
    private(set) var begun = 0
    private(set) var requestedScopes: [[String]] = []

    init(outcomes: [Result<Void, any Error>] = [.success(())], scopesSupported: [String]? = ["atproto"],
         scopes: [String] = ["atproto"]) {
        self.outcomes = outcomes
        self.scopesSupported = scopesSupported
        self.scopes = scopes
    }

    func prepare(identifier: String) async throws -> ATProtoPreparedAuthorization {
        prepared += 1
        return try ATProtoPreparedAuthorization(
            identity: testIdentity(), metadata: testMetadata(scopesSupported: scopesSupported),
            scopes: scopes, requiredScopes: ["atproto"]
        )
    }

    func begin(_ prepared: ATProtoPreparedAuthorization) async throws -> OAuthAuthorizationRequest {
        begun += 1
        requestedScopes.append(prepared.requestedScopes)
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
final class ImmediatePresenter: ATProtoOAuthPresenter {
    var presented: [URL] = []
    func authorize(_ authorizationURL: URL, callback: OAuthCallbackMatcher) async throws -> URL {
        presented.append(authorizationURL)
        return URL(string: "com.example.app:/cb?code=c")!
    }
}
