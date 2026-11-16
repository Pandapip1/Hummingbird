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
    /// The DID document does not claim the handle back, or its DNS records
    /// name more than one DID.
    case handleNotVerified(String)
    /// Neither DNS nor HTTPS gave the handle a DID.
    case handleNotResolved(HandleResolutionFailure)
    /// The authorization server redirected back with an error, such as the
    /// user declining (`access_denied`).
    case authorizationDenied(error: String, description: String?)

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
        case .handleNotVerified(let reason): "The handle could not be verified: \(reason)"
        case .handleNotResolved(let failure): failure.summary
        case .authorizationDenied(let error, let description):
            if let description, !description.isEmpty {
                "The account provider refused the sign-in: \(description) (\(error))"
            } else {
                "The account provider refused the sign-in (\(error))."
            }
        }
    }

    /// The server refused an authorization request because it was presented
    /// from a different device than the one that first loaded it. With a
    /// single page load this means the network delivered that load twice
    /// (a transport-level retry), so a fresh request can succeed.
    var isRequestDeviceMismatch: Bool {
        guard case .authorizationDenied(let error, let description) = self else { return false }
        return error == "access_denied"
            && description?.range(of: "initiated from another device", options: .caseInsensitive) != nil
    }
}

/// Why a handle did not resolve, with the underlying errors kept for logs.
public struct HandleResolutionFailure: Error, Sendable, CustomDebugStringConvertible {
    public let handle: String
    public let dnsFailure: (any Error)?
    public let httpsFailure: (any Error)?

    /// One line for people: "alice.example.com didn't resolve to an atproto
    /// account (DNS: timed out; HTTPS: host not found)".
    public var summary: String {
        let dns = dnsFailure.map(Self.describe) ?? "no _atproto record"
        let https = httpsFailure.map(Self.describe) ?? "no DID"
        return "\(handle) didn't resolve to an atproto account (DNS: \(dns); HTTPS: \(https))"
    }

    public var debugDescription: String {
        "HandleResolutionFailure(handle: \(handle), dns: \(dnsFailure.map { String(reflecting: $0) } ?? "no record"), "
            + "https: \(httpsFailure.map { String(reflecting: $0) } ?? "no DID"))"
    }

    /// A few words for an error, without NSError user-info dumps.
    static func describe(_ error: any Error) -> String {
        switch error {
        case DNSTXTError.timedOut: return "timed out"
        case DNSTXTError.lookupFailed: return "lookup failed"
        case let error as URLError:
            switch error.code {
            case .timedOut: return "timed out"
            case .cannotFindHost, .dnsLookupFailed: return "host not found"
            case .cannotConnectToHost: return "could not connect"
            case .notConnectedToInternet: return "offline"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "TLS failed"
            case .badServerResponse:
                return (error.userInfo[NSLocalizedDescriptionKey] as? String) ?? "bad response"
            default: return "network error \(error.code.rawValue)"
            }
        case let error as OAuthError: return error.errorDescription ?? "invalid response"
        default: return "failed"
        }
    }
}

/// The parameters of an authorization callback. RFC 6749 encodes them as
/// application/x-www-form-urlencoded, so "+" is a space and is decoded
/// before percent escapes; `URLComponents.queryItems` would keep the "+".
struct OAuthCallbackParameters {
    private var values: [String: String] = [:]

    init(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = Self.decode(parts[0]) else { continue }
            let value = parts.count > 1 ? Self.decode(parts[1]) : ""
            // Parameters must not repeat; the first occurrence wins.
            if values[name] == nil, let value { values[name] = value }
        }
    }

    subscript(name: String) -> String? { values[name] }

    private static func decode(_ component: Substring) -> String? {
        component.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
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
