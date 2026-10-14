import Crypto
import Foundation

struct DPoPSigner: Sendable {
    let key: P256.Signing.PrivateKey

    func proof(method: String, url: URL, nonce: String? = nil, accessToken: String? = nil,
               now: Date = Date()) throws -> String {
        let publicBytes = key.publicKey.x963Representation
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
            payload["ath"] = .string(Data(SHA256.hash(data: Data(accessToken.utf8))).base64URLEncodedString())
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
