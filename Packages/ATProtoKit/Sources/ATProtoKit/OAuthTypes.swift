import Crypto
import Foundation
// Sessions hold their tokens as SecureBytes, so it is part of this API.
@_exported import SecureMemory
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
    /// Held in protected memory; see `DPoPAuthorization` for where it
    /// becomes an HTTP header.
    public var accessToken: SecureBytes
    public var refreshToken: SecureBytes?
    public var scope: String
    public var tokenType: String
    public var expiresAt: Date?
    /// DPoP nonces are scoped to the server origin that issued them. An
    /// authorization server nonce must never be sent to a distinct PDS origin.
    public var dpopNonces: [String: String]

    public init(account: DID, handle: String?, pds: URL, authorizationServer: URL,
                accessToken: SecureBytes, refreshToken: SecureBytes?, scope: String,
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
        accessToken = try values.decodeSecret(forKey: .accessToken)
        refreshToken = try values.decodeSecretIfPresent(forKey: .refreshToken)
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
        try values.encodeSecret(accessToken, forKey: .accessToken)
        if let refreshToken { try values.encodeSecret(refreshToken, forKey: .refreshToken) }
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
    let dpopPrivateKey: SecureBytes

    init(session: ATProtoOAuthSession, dpopPrivateKey: SecureBytes) {
        self.session = session
        self.dpopPrivateKey = dpopPrivateKey
    }

    /// A signer that owns a key restored straight from protected memory.
    func signer() throws -> DPoPSigner {
        try DPoPSigner(x963Representation: dpopPrivateKey)
    }

    enum CodingKeys: String, CodingKey { case session, dpopPrivateKey }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        session = try values.decode(ATProtoOAuthSession.self, forKey: .session)
        var key = try values.decode(Data.self, forKey: .dpopPrivateKey)
        dpopPrivateKey = SecureBytes(wiping: &key)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(session, forKey: .session)
        // Protection ends for this transient copy: JSON needs Data to base64
        // it. It is wiped as soon as the encoder has consumed it.
        var key = dpopPrivateKey.unsafeUnprotectedData()
        defer { key.resetBytes(in: key.startIndex..<key.endIndex) }
        try values.encode(key, forKey: .dpopPrivateKey)
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
    let dpopSigner: DPoPSigner
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

    /// Whether `url` is the redirect this matcher describes.
    public func matches(_ url: URL) -> Bool {
        switch self {
        case .customScheme(let scheme): url.scheme?.lowercased() == scheme.lowercased()
        case .https(let host, let path):
            url.scheme?.lowercased() == "https" && url.host?.lowercased() == host.lowercased() && url.path == path
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
    /// The user dismissed the authorization page before it redirected back.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The account handle or DID is invalid."
        case .invalidMetadata(let reason): "Invalid OAuth metadata: \(reason)"
        case .invalidCallback: "The OAuth callback URL is invalid."
        case .stateMismatch: "The OAuth callback did not match this sign-in request."
        case .issuerMismatch: "The OAuth callback came from an unexpected authorization server."
        case .authorizationFailed(let reason): "Authorization failed: \(reason)"
        case .tokenResponse(let reason): "Invalid token response: \(reason)"
        case .cancelled: "Sign-in was cancelled."
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

private struct SecretIsNotUTF8: Error {}

extension KeyedDecodingContainer {
    /// JSON delivers the secret as a `String`, which cannot be wiped; it is
    /// moved into protected memory immediately and the string dropped.
    func decodeSecret(forKey key: Key) throws -> SecureBytes {
        SecureBytes(copyingUTF8: try decode(String.self, forKey: key))
    }

    func decodeSecretIfPresent(forKey key: Key) throws -> SecureBytes? {
        try decodeIfPresent(String.self, forKey: key).map(SecureBytes.init(copyingUTF8:))
    }
}

extension KeyedEncodingContainer {
    /// Protection ends for the transient `String` JSON needs. Credentials
    /// are encoded through `SecureBytes(jsonEncoding:)`, which wipes the
    /// encoder's output once it is copied into protected memory.
    mutating func encodeSecret(_ secret: SecureBytes, forKey key: Key) throws {
        guard let string = secret.unsafeUnprotectedString() else {
            throw EncodingError.invalidValue(secret, .init(
                codingPath: codingPath + [key], debugDescription: "Secret is not valid UTF-8."
            ))
        }
        try encode(string, forKey: key)
    }
}
