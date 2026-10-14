import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OAuthClientConfiguration: Codable, Hashable, Sendable {
    public let clientID: URL
    public let redirectURI: URL
    public let scopes: [String]

    public init(clientID: URL, redirectURI: URL, scopes: [String]) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

public struct OAuthProtectedResourceMetadata: Decodable, Sendable {
    public let resource: URL?
    public let authorizationServers: [URL]

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
    }
}

public struct OAuthAuthorizationServerMetadata: Decodable, Sendable {
    public let issuer: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let pushedAuthorizationRequestEndpoint: URL
    public let scopesSupported: [String]

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case pushedAuthorizationRequestEndpoint = "pushed_authorization_request_endpoint"
        case scopesSupported = "scopes_supported"
    }
}

public struct ATProtoOAuthSession: Codable, Hashable, Sendable {
    public let account: DID
    public let handle: String?
    public let pds: URL
    public let authorizationServer: URL
    public var accessToken: String
    public var refreshToken: String?
    public var scope: String
    public var tokenType: String
    public var expiresAt: Date?
    /// DPoP nonces are scoped to the server origin that issued them. An
    /// authorization server nonce must never be sent to a distinct PDS origin.
    public var dpopNonces: [String: String]

    public init(account: DID, handle: String?, pds: URL, authorizationServer: URL,
                accessToken: String, refreshToken: String?, scope: String,
                tokenType: String, expiresAt: Date?, dpopNonces: [String: String] = [:]) {
        self.account = account
        self.handle = handle
        self.pds = pds
        self.authorizationServer = authorizationServer
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.scope = scope
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.dpopNonces = dpopNonces
    }

    public func dpopNonce(for url: URL) -> String? { dpopNonces[url.oauthOrigin] }

    public mutating func setDPoPNonce(_ nonce: String?, for url: URL) {
        dpopNonces[url.oauthOrigin] = nonce
    }

    enum CodingKeys: String, CodingKey {
        case account, handle, pds, authorizationServer, accessToken, refreshToken
        case scope, tokenType, expiresAt, dpopNonces, dpopNonce
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        account = try values.decode(DID.self, forKey: .account)
        handle = try values.decodeIfPresent(String.self, forKey: .handle)
        pds = try values.decode(URL.self, forKey: .pds)
        authorizationServer = try values.decode(URL.self, forKey: .authorizationServer)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
        scope = try values.decode(String.self, forKey: .scope)
        tokenType = try values.decode(String.self, forKey: .tokenType)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        dpopNonces = try values.decodeIfPresent([String: String].self, forKey: .dpopNonces) ?? [:]
        if let legacy = try values.decodeIfPresent(String.self, forKey: .dpopNonce) {
            dpopNonces[authorizationServer.oauthOrigin] = legacy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(account, forKey: .account)
        try values.encodeIfPresent(handle, forKey: .handle)
        try values.encode(pds, forKey: .pds)
        try values.encode(authorizationServer, forKey: .authorizationServer)
        try values.encode(accessToken, forKey: .accessToken)
        try values.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try values.encode(scope, forKey: .scope)
        try values.encode(tokenType, forKey: .tokenType)
        try values.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try values.encode(dpopNonces, forKey: .dpopNonces)
    }
}

private extension URL {
    var oauthOrigin: String {
        var components = URLComponents()
        components.scheme = scheme?.lowercased()
        components.host = host?.lowercased()
        components.port = port
        return components.string ?? absoluteString
    }
}

public struct ATProtoOAuthCredential: Codable, Hashable, Sendable {
    public var session: ATProtoOAuthSession
    /// ANSI X9.63 private-key representation, stored only in the platform
    /// credential store and never included in application replication.
    let dpopPrivateKey: Data

    init(session: ATProtoOAuthSession, dpopKey: P256.Signing.PrivateKey) {
        self.session = session
        dpopPrivateKey = dpopKey.x963Representation
    }

    func signer() throws -> DPoPSigner {
        try DPoPSigner(key: P256.Signing.PrivateKey(x963Representation: dpopPrivateKey))
    }
}

public struct OAuthAuthorizationRequest: Sendable {
    public let authorizationURL: URL
    public let callback: OAuthCallbackMatcher
    public let state: String
    let verifier: String
    let issuer: URL
    let pds: URL
    let account: DID
    let loginHint: String?
    let dpopKey: P256.Signing.PrivateKey
    let dpopNonce: String?
}

public enum OAuthCallbackMatcher: Hashable, Sendable {
    case customScheme(String)
    case https(host: String, path: String)

    public init?(redirectURI: URL) {
        guard let scheme = redirectURI.scheme?.lowercased() else { return nil }
        if scheme == "https", let host = redirectURI.host {
            self = .https(host: host, path: redirectURI.path)
        } else if scheme != "http" {
            self = .customScheme(scheme)
        } else {
            return nil
        }
    }
}

public enum OAuthError: LocalizedError, Sendable {
    case invalidIdentifier
    case invalidMetadata(String)
    case invalidCallback
    case stateMismatch
    case issuerMismatch
    case authorizationFailed(String)
    case tokenResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The account handle or DID is invalid."
        case .invalidMetadata(let reason): "Invalid OAuth metadata: \(reason)"
        case .invalidCallback: "The OAuth callback URL is invalid."
        case .stateMismatch: "The OAuth callback did not match this sign-in request."
        case .issuerMismatch: "The OAuth callback came from an unexpected authorization server."
        case .authorizationFailed(let reason): "Authorization failed: \(reason)"
        case .tokenResponse(let reason): "Invalid token response: \(reason)"
        }
    }
}

struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresIn: Int?
    let scope: String
    let sub: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope, sub
    }
}

struct PushedAuthorizationResponse: Decodable {
    let requestURI: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case requestURI = "request_uri"
        case expiresIn = "expires_in"
    }
}

enum OAuthRandom {
    static func token(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return data.base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
