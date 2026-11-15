import Crypto
import Foundation
import SecureMemory

/// The single owner of a DPoP private key.
///
/// The key never leaves this actor: holders keep the signer, callers get
/// signatures (`proof`) and the public JWK, and persistence goes through
/// `exportForStorage()`, which writes the key straight into `SecureBytes`.
/// Being an actor, it is `Sendable` without the key type having to be
/// (swift-crypto's Linux key types are not).
actor DPoPSigner {
    private let key: P256.Signing.PrivateKey
    /// Uncompressed public point, used for the JWK header.
    nonisolated let publicKeyX963: Data

    /// Generates a fresh key.
    init() {
        let key = P256.Signing.PrivateKey()
        publicKeyX963 = key.publicKey.x963Representation
        self.key = key
    }

    /// Restores a key persisted by `exportForStorage()`, reading it directly
    /// from protected memory.
    init(x963Representation stored: SecureBytes) throws {
        let key = try P256.Signing.PrivateKey(x963Representation: stored)
        publicKeyX963 = key.publicKey.x963Representation
        self.key = key
    }

    /// The key in ANSI X9.63 form, in protected memory, for the credential
    /// vault. The intermediate `Data` from the crypto library is wiped.
    func exportForStorage() -> SecureBytes {
        var representation = key.x963Representation
        return SecureBytes(wiping: &representation)
    }

    func proof(method: String, url: URL, nonce: String? = nil, accessToken: SecureBytes? = nil,
               now: Date = Date()) throws -> String {
        let publicBytes = publicKeyX963
        precondition(publicBytes.count == 65 && publicBytes.first == 4)
        let header: [String: JSONValue] = [
            "typ": .string("dpop+jwt"),
            "alg": .string("ES256"),
            "jwk": .object([
                "kty": .string("EC"), "crv": .string("P-256"),
                "x": .string(Data(publicBytes[1..<33]).base64URLEncodedString()),
                "y": .string(Data(publicBytes[33..<65]).base64URLEncodedString()),
            ]),
        ]
        var payload: [String: JSONValue] = [
            "jti": .string(UUID().uuidString.lowercased()),
            "htm": .string(method.uppercased()),
            "htu": .string(Self.normalizedHTU(url)),
            "iat": .integer(Int(now.timeIntervalSince1970)),
        ]
        if let nonce { payload["nonce"] = .string(nonce) }
        if let accessToken {
            // Hash the token straight from protected memory.
            var hasher = SHA256()
            accessToken.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            payload["ath"] = .string(Data(hasher.finalize()).base64URLEncodedString())
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedHeader = try encoder.encode(JSONValue.object(header)).base64URLEncodedString()
        let encodedPayload = try encoder.encode(JSONValue.object(payload)).base64URLEncodedString()
        let signingInput = encodedHeader + "." + encodedPayload
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + signature.base64URLEncodedString()
    }

    private static func normalizedHTU(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.query = nil
        components.fragment = nil
        return components.url!.absoluteString
    }
}
