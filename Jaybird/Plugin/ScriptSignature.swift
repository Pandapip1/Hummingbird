import Foundation
import Security

/// Verifies a plugin script signature: RSA with SHA-512 (PKCS#1 v1.5) over the script text.
/// The public key is a Base64 SubjectPublicKeyInfo (X.509) string and the signature is Base64.
enum ScriptSignature {
    static func verify(script: String, signatureBase64: String, publicKeyBase64: String) -> Bool {
        guard let sig = Data(base64Encoded: stripWhitespace(signatureBase64)),
              let spki = Data(base64Encoded: stripWhitespace(publicKeyBase64)),
              let pkcs1 = rsaPublicKeyBody(fromSPKI: spki) else { return false }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else { return false }
        let message = Data(script.utf8)
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA512, message as CFData, sig as CFData, &error)
    }

    private static func stripWhitespace(_ s: String) -> String {
        s.filter { !$0.isWhitespace }
    }

    // SecKey wants the inner PKCS#1 RSAPublicKey, so unwrap the X.509 SubjectPublicKeyInfo:
    // SEQUENCE { SEQUENCE { algorithm... }, BIT STRING { 0x00, RSAPublicKey } }
    static func rsaPublicKeyBody(fromSPKI der: Data) -> Data? {
        let bytes = [UInt8](der)
        var i = 0
        func readLength() -> Int? {
            guard i < bytes.count else { return nil }
            let first = bytes[i]; i += 1
            if first < 0x80 { return Int(first) }
            let n = Int(first & 0x7f)
            guard n > 0, n <= 4, i + n <= bytes.count else { return nil }
            var len = 0
            for _ in 0..<n { len = (len << 8) | Int(bytes[i]); i += 1 }
            return len
        }
        func expect(_ tag: UInt8) -> Int? {
            guard i < bytes.count, bytes[i] == tag else { return nil }
            i += 1
            return readLength()
        }
        guard expect(0x30) != nil else { return nil }          // outer SEQUENCE
        guard let algLen = expect(0x30) else { return nil }    // AlgorithmIdentifier
        i += algLen
        guard let bitLen = expect(0x03), bitLen > 1, i + bitLen <= bytes.count else { return nil }
        guard bytes[i] == 0x00 else { return nil }             // no unused bits
        i += 1
        return Data(bytes[i..<(i + bitLen - 1)])
    }
}
