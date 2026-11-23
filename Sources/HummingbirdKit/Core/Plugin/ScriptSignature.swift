import Foundation
#if canImport(Security)
import Security
#else
import Crypto
import _CryptoExtras
#endif

/// A plugin's script exactly as its author published it. The only way to
/// make one is `ScriptSignature.check`, which verifies the signature when the
/// plugin is signed, and `PluginRuntime` accepts nothing else. So no code path
/// can rewrite a plugin's source before it runs: changing the text means
/// checking it again, and a changed signed script fails that check.
struct CheckedScript: Sendable, Hashable {
    let pluginID: String
    let text: String
    /// true: signed, and the signature verified; false: an unsigned plugin.
    let isSigned: Bool

    fileprivate init(pluginID: String, text: String, isSigned: Bool) {
        self.pluginID = pluginID
        self.text = text
        self.isSigned = isSigned
    }
}

/// Verifies a plugin script signature: RSA with SHA-512 (PKCS#1 v1.5) over the script text.
/// The public key is a Base64 SubjectPublicKeyInfo (X.509) string and the signature is Base64.
enum ScriptSignature {
    enum CheckError: LocalizedError, Equatable {
        case invalidSignature
        case signatureMissing

        var errorDescription: String? {
            switch self {
            case .invalidSignature: return "The script signature is invalid. The plugin may have been tampered with."
            case .signatureMissing: return "The plugin names a signing key but its script isn’t signed."
            }
        }
    }

    /// Checks `text` against `config`'s signature. A config that names a key
    /// or a signature must carry both, and they must verify; one with
    /// neither is an unsigned plugin. RSA verification over megabytes of
    /// script is not for the main actor.
    static func check(_ text: String, for config: PluginConfig) throws -> CheckedScript {
        let signature = config.scriptSignature ?? "", key = config.scriptPublicKey ?? ""
        guard !signature.isEmpty || !key.isEmpty else {
            return CheckedScript(pluginID: config.id, text: text, isSigned: false)
        }
        guard !signature.isEmpty, !key.isEmpty else { throw CheckError.signatureMissing }
        guard verify(script: text, signatureBase64: signature, publicKeyBase64: key) else {
            throw CheckError.invalidSignature
        }
        return CheckedScript(pluginID: config.id, text: text, isSigned: true)
    }

    static func verify(script: String, signatureBase64: String, publicKeyBase64: String) -> Bool {
        guard let sig = Data(base64Encoded: stripWhitespace(signatureBase64)),
              let spki = Data(base64Encoded: stripWhitespace(publicKeyBase64)),
              let pkcs1 = rsaPublicKeyBody(fromSPKI: spki) else { return false }
        let message = Data(script.utf8)
        #if canImport(Security)
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA512, message as CFData, sig as CFData, &error)
        #else
        guard let key = try? _RSA.Signing.PublicKey(derRepresentation: spki) else { return false }
        return key.isValidSignature(_RSA.Signing.RSASignature(rawRepresentation: sig),
                                    for: SHA512.hash(data: message), padding: .insecurePKCS1v1_5)
        #endif
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
