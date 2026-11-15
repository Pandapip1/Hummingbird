import Foundation
import SecureMemory
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies DPoP-bound access tokens to XRPC, refreshes expiring sessions, and
/// retries once when a resource server rotates its required DPoP nonce.
public actor DPoPAuthorization: ATProtoAuthorizationProvider {
    private var credential: ATProtoOAuthCredential
    private let oauth: ATProtoOAuthClient
    private let store: OAuthCredentialStore?
    /// Built once from the stored key; refreshes keep the same DPoP key.
    private var cachedSigner: DPoPSigner?

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
        let proof = try await signer().proof(
            method: method, url: url, nonce: credential.session.dpopNonce(for: url), accessToken: token
        )
        // Protection ends here: URLRequest headers are plain Strings, so the
        // token is copied out of protected memory for as long as this request
        // (and URLSession's copy of it) lives.
        guard let tokenString = token.unsafeUnprotectedString() else {
            throw OAuthError.tokenResponse("The stored access token is not valid UTF-8.")
        }
        request.setValue("DPoP \(tokenString)", forHTTPHeaderField: "Authorization")
        request.setValue(proof, forHTTPHeaderField: "DPoP")
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

    private func signer() throws -> DPoPSigner {
        if let cachedSigner { return cachedSigner }
        let signer = try credential.signer()
        cachedSigner = signer
        return signer
    }
}

private struct DPoPFailure: Decodable { let error: String? }
