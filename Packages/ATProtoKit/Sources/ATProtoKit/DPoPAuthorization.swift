import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies DPoP-bound access tokens to XRPC, refreshes expiring sessions, and
/// retries once when a resource server rotates its required DPoP nonce.
public actor DPoPAuthorization: ATProtoAuthorizationProvider {
    private var credential: ATProtoOAuthCredential
    private let oauth: ATProtoOAuthClient
    private let store: OAuthCredentialStore?

    public init(credential: ATProtoOAuthCredential, oauth: ATProtoOAuthClient,
                store: OAuthCredentialStore? = nil) {
        self.credential = credential
        self.oauth = oauth
        self.store = store
    }

    public func authorize(_ request: URLRequest) async throws -> URLRequest {
        if let expiresAt = credential.session.expiresAt,
           expiresAt <= Date().addingTimeInterval(60), credential.session.refreshToken != nil {
            credential = try await oauth.refresh(credential)
            try store?.save(credential)
        }
        guard let url = request.url, let method = request.httpMethod else { throw URLError(.badURL) }
        var request = request
        let token = credential.session.accessToken
        request.setValue("DPoP \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            try credential.signer().proof(method: method, url: url,
                                          nonce: credential.session.dpopNonce(for: url), accessToken: token),
            forHTTPHeaderField: "DPoP"
        )
        return request
    }

    public func didReceive(_ response: HTTPURLResponse, data: Data, for request: URLRequest) async throws -> Bool {
        guard let nonce = response.value(forHTTPHeaderField: "DPoP-Nonce"),
              let url = request.url,
              nonce != credential.session.dpopNonce(for: url) else { return false }
        credential.session.setDPoPNonce(nonce, for: url)
        try store?.save(credential)
        guard response.statusCode == 401 else { return false }
        let challenge = response.value(forHTTPHeaderField: "WWW-Authenticate")?.lowercased() ?? ""
        let bodyError = (try? JSONDecoder().decode(DPoPFailure.self, from: data))?.error
        return challenge.contains("use_dpop_nonce") || bodyError == "use_dpop_nonce"
    }

    public func currentCredential() -> ATProtoOAuthCredential { credential }
}

private struct DPoPFailure: Decodable { let error: String? }
