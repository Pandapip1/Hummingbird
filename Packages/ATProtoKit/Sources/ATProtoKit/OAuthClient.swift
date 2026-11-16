import Crypto
import Foundation
import SecureMemory
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor ATProtoOAuthClient {
    private let configuration: OAuthClientConfiguration
    private let session: URLSession
    private let resolver: ATProtoIdentityResolver

    public init(configuration: OAuthClientConfiguration, session: URLSession = .shared,
                resolver: ATProtoIdentityResolver? = nil) {
        self.configuration = configuration
        self.session = session
        self.resolver = resolver ?? ATProtoIdentityResolver(session: session)
    }

    public func begin(identifier: String) async throws -> OAuthAuthorizationRequest {
        guard configuration.scopes.contains("atproto") else {
            throw OAuthError.invalidMetadata("The atproto scope is required.")
        }
        let identity = try await resolver.resolve(identifier)
        let metadata = try await discover(pds: identity.pds)
        let callback = try callbackMatcher()
        let verifier = OAuthRandom.token(bytes: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = OAuthRandom.token()
        var form = [
            "client_id": configuration.clientID.absoluteString,
            "response_type": "code",
            "redirect_uri": configuration.redirectURI.absoluteString,
            "scope": configuration.scopes.joined(separator: " "),
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "login_hint": Self.loginHint(for: identity),
        ]
        // Public native clients intentionally have no client secret or client assertion.
        let signer = DPoPSigner()
        let (data, response, nonce) = try await sendDPoPForm(
            to: metadata.pushedAuthorizationRequestEndpoint, form: form, signer: signer
        )
        try Self.requireSuccess(response, data: data)
        let pushed = try JSONDecoder().decode(PushedAuthorizationResponse.self, from: data)
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        form = ["client_id": configuration.clientID.absoluteString, "request_uri": pushed.requestURI]
        components.queryItems = form.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        guard let authorizationURL = components.url else { throw OAuthError.invalidMetadata("Bad authorization endpoint.") }
        return OAuthAuthorizationRequest(
            authorizationURL: authorizationURL, callback: callback, state: state,
            verifier: verifier, issuer: metadata.issuer, pds: identity.pds, account: identity.did,
            loginHint: identity.handle, dpopSigner: signer, dpopNonce: nonce
        )
    }

    /// What the authorization server gets as `login_hint`: the identity as
    /// resolved, not as typed, so a displayed-form "@alice.example.com" or
    /// stray capitals and spaces don't make it reject the request.
    static func loginHint(for identity: ResolvedIdentity) -> String {
        identity.handle ?? identity.did.rawValue
    }

    public func complete(_ request: OAuthAuthorizationRequest, callbackURL: URL) async throws -> ATProtoOAuthCredential {
        guard request.callback.matches(callbackURL) else { throw OAuthError.invalidCallback }
        let parameters = OAuthCallbackParameters(callbackURL)
        func value(_ name: String) -> String? { parameters[name] }
        guard value("state") == request.state else { throw OAuthError.stateMismatch }
        if let error = value("error") {
            throw OAuthError.authorizationDenied(error: error, description: value("error_description"))
        }
        guard value("iss") == request.issuer.absoluteString else { throw OAuthError.issuerMismatch }
        guard let code = value("code") else { throw OAuthError.invalidCallback }
        let metadata = try await authorizationMetadata(issuer: request.issuer)
        let form = [
            "grant_type": "authorization_code", "code": code,
            "client_id": configuration.clientID.absoluteString,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "code_verifier": request.verifier,
        ]
        let signer = request.dpopSigner
        // `data` is a var so the token response can be wiped after decoding.
        var data: Data
        let response: URLResponse, nonce: String?
        (data, response, nonce) = try await sendDPoPForm(
            to: metadata.tokenEndpoint, form: form, signer: signer, initialNonce: request.dpopNonce
        )
        try Self.requireSuccess(response, data: data)
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        // Best effort: the response body held the tokens in ordinary memory.
        data.resetBytes(in: data.startIndex..<data.endIndex)
        guard token.sub == request.account.rawValue else {
            throw OAuthError.tokenResponse("Account DID did not match the authorization request.")
        }
        let granted = Set(token.scope.split(separator: " ").map(String.init))
        guard token.tokenType.caseInsensitiveCompare("DPoP") == .orderedSame else {
            throw OAuthError.tokenResponse("The authorization server did not issue a DPoP-bound token.")
        }
        guard Set(configuration.scopes).isSubset(of: granted) else {
            throw OAuthError.tokenResponse("The authorization server omitted a requested scope.")
        }
        var session = ATProtoOAuthSession(
            account: request.account, handle: request.loginHint, pds: request.pds,
            authorizationServer: request.issuer, accessToken: SecureBytes(copyingUTF8: token.accessToken),
            refreshToken: token.refreshToken.map(SecureBytes.init(copyingUTF8:)), scope: token.scope, tokenType: token.tokenType,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
        session.setDPoPNonce(nonce, for: metadata.tokenEndpoint)
        return ATProtoOAuthCredential(session: session, dpopPrivateKey: await signer.exportForStorage())
    }

    public func refresh(_ credential: ATProtoOAuthCredential) async throws -> ATProtoOAuthCredential {
        guard let refreshToken = credential.session.refreshToken else {
            throw OAuthError.tokenResponse("This session has no refresh token.")
        }
        let metadata = try await authorizationMetadata(issuer: credential.session.authorizationServer)
        let signer = try credential.signer()
        // Protection ends here: the form body needs the refresh token as a
        // String. The copy lives only until the request has been sent.
        guard let refreshTokenString = refreshToken.unsafeUnprotectedString() else {
            throw OAuthError.tokenResponse("The stored refresh token is not valid UTF-8.")
        }
        let form = [
            "grant_type": "refresh_token", "refresh_token": refreshTokenString,
            "client_id": configuration.clientID.absoluteString,
        ]
        // `data` is a var so the token response can be wiped after decoding.
        var data: Data
        let response: URLResponse, nonce: String?
        (data, response, nonce) = try await sendDPoPForm(
            to: metadata.tokenEndpoint, form: form, signer: signer,
            initialNonce: credential.session.dpopNonce(for: metadata.tokenEndpoint)
        )
        try Self.requireSuccess(response, data: data)
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        // Best effort: the response body held the tokens in ordinary memory.
        data.resetBytes(in: data.startIndex..<data.endIndex)
        guard token.sub == credential.session.account.rawValue else {
            throw OAuthError.tokenResponse("Refreshed account DID changed.")
        }
        guard token.tokenType.caseInsensitiveCompare("DPoP") == .orderedSame,
              token.scope.split(separator: " ").contains("atproto") else {
            throw OAuthError.tokenResponse("The refreshed token is not a valid atproto DPoP token.")
        }
        var updated = credential.session
        updated.accessToken = SecureBytes(copyingUTF8: token.accessToken)
        updated.refreshToken = token.refreshToken.map(SecureBytes.init(copyingUTF8:)) ?? refreshToken
        updated.tokenType = token.tokenType
        updated.scope = token.scope
        updated.expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        updated.setDPoPNonce(nonce, for: metadata.tokenEndpoint)
        // Same key as before; it is already in protected memory.
        return ATProtoOAuthCredential(session: updated, dpopPrivateKey: credential.dpopPrivateKey)
    }

    private func discover(pds: URL) async throws -> OAuthAuthorizationServerMetadata {
        let resourceURL = try Self.wellKnown("oauth-protected-resource", on: pds)
        let resource: OAuthProtectedResourceMetadata = try await getJSON(resourceURL)
        guard resource.authorizationServers.count == 1, let issuer = resource.authorizationServers.first else {
            throw OAuthError.invalidMetadata("Expected exactly one authorization server.")
        }
        return try await authorizationMetadata(issuer: issuer)
    }

    private func authorizationMetadata(issuer: URL) async throws -> OAuthAuthorizationServerMetadata {
        let url = try Self.wellKnown("oauth-authorization-server", on: issuer)
        let metadata: OAuthAuthorizationServerMetadata = try await getJSON(url)
        guard metadata.issuer == issuer, metadata.scopesSupported.contains("atproto") else {
            throw OAuthError.invalidMetadata("Authorization-server issuer or scopes are invalid.")
        }
        return metadata
    }

    private func getJSON<Value: Decodable>(_ url: URL) async throws -> Value {
        let (data, response) = try await session.data(from: url)
        try Self.requireSuccess(response, data: data)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func sendDPoPForm(to url: URL, form: [String: String], signer: DPoPSigner,
                              initialNonce: String? = nil) async throws -> (Data, URLResponse, String?) {
        var nonce = initialNonce
        for attempt in 0...1 {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(try await signer.proof(method: "POST", url: url, nonce: nonce), forHTTPHeaderField: "DPoP")
            request.httpBody = Self.formBody(form)
            let (data, response) = try await session.data(for: request)
            let receivedNonce = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "DPoP-Nonce")
            if let receivedNonce { nonce = receivedNonce }
            let oauthFailure = try? JSONDecoder().decode(OAuthFailure.self, from: data)
            if attempt == 0, let http = response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode), receivedNonce != nil,
               oauthFailure?.error == "use_dpop_nonce" { continue }
            return (data, response, nonce)
        }
        throw URLError(.badServerResponse)
    }

    private func callbackMatcher() throws -> OAuthCallbackMatcher {
        guard let callback = OAuthCallbackMatcher(redirectURI: configuration.redirectURI) else {
            throw OAuthError.invalidMetadata("Native redirect must use HTTPS or a custom scheme.")
        }
        return callback
    }

    private static func wellKnown(_ name: String, on origin: URL) throws -> URL {
        guard origin.scheme == "https", origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil else {
            throw OAuthError.invalidMetadata("Server origin must be a plain HTTPS URL.")
        }
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = "/.well-known/" + name
        guard let url = components.url else { throw OAuthError.invalidMetadata("Invalid server origin.") }
        return url
    }

    private static func formBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(OAuthFailure.self, from: data)).map {
                $0.errorDescription ?? $0.error
            } ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw OAuthError.authorizationFailed(message)
        }
    }
}

private struct OAuthFailure: Decodable {
    let error: String
    let errorDescription: String?
    enum CodingKeys: String, CodingKey { case error; case errorDescription = "error_description" }
}
