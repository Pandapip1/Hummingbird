import XCTest
#if canImport(Security)
import Security
#else
import Crypto
import _CryptoExtras
#endif
@testable import JaybirdKit

final class ConfigAndSignatureTests: XCTestCase {
    func testConfigDefaultsAndRelativeURLs() throws {
        let json = #"{"name":"Demo","id":"abc","scriptUrl":"./Demo.js","iconUrl":"icon.png","version":3,"allowUrls":["example.com",".cdn.example.org"],"packages":["Http"]}"#
        let c = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.name, "Demo")
        XCTAssertFalse(c.allowEval)
        XCTAssertTrue(c.enableInSearch)
        XCTAssertEqual(c.version, 3)
        let base = URL(string: "https://plugins.example.com/Demo/DemoConfig.json")
        XCTAssertEqual(c.resolve(c.scriptUrl, base: base)?.absoluteString, "https://plugins.example.com/Demo/Demo.js")
        XCTAssertEqual(c.resolve("https://other.test/x.js", base: base)?.absoluteString, "https://other.test/x.js")
    }

    func testAllowList() throws {
        var c = try JSONDecoder().decode(PluginConfig.self, from: Data(#"{"name":"d","allowUrls":["api.example.com",".media.example.org"]}"#.utf8))
        XCTAssertTrue(c.allowsHost("api.example.com"))
        XCTAssertTrue(c.allowsHost("API.Example.com"))
        XCTAssertFalse(c.allowsHost("example.com"))
        XCTAssertTrue(c.allowsHost("media.example.org"))
        XCTAssertTrue(c.allowsHost("a.b.media.example.org"))
        XCTAssertFalse(c.allowsHost("evilmedia.example.org"))
        c.allowUrls = ["everywhere"]
        XCTAssertTrue(c.allowsHost("anything.test"))
    }

    func testSettingsDecodeWithReservedWordKey() throws {
        let json = #"{"name":"d","settings":[{"variable":"v","name":"N","type":"Boolean","default":"true"}]}"#
        let c = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.settings.first?.default, "true")
        XCTAssertEqual(c.settings.first?.key, "v")
    }

    // MARK: signature

    #if canImport(Security)
    private func der(tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        if body.count < 0x80 { out.append(UInt8(body.count)) }
        else if body.count < 0x100 { out += [0x81, UInt8(body.count)] }
        else { out += [0x82, UInt8(body.count >> 8), UInt8(body.count & 0xff)] }
        return out + body
    }

    /// Returns (SPKI base64, signature base64) for `script`.
    private func sign(_ script: String) throws -> (String, String) {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var err: Unmanaged<CFError>?
        let priv = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, &err))
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(priv))
        let pkcs1 = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, &err) as Data?)
        // Wrap the PKCS#1 key in an X.509 SubjectPublicKeyInfo, the format plugin configs carry.
        let algorithm: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        let spki = der(tag: 0x30, algorithm + der(tag: 0x03, [0x00] + [UInt8](pkcs1)))
        let sig = try XCTUnwrap(SecKeyCreateSignature(priv, .rsaSignatureMessagePKCS1v15SHA512, Data(script.utf8) as CFData, &err) as Data?)
        return (Data(spki).base64EncodedString(), sig.base64EncodedString())
    }
    #else
    private func sign(_ script: String) throws -> (String, String) {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let sig = try key.signature(for: SHA512.hash(data: Data(script.utf8)), padding: .insecurePKCS1v1_5)
        return (key.publicKey.derRepresentation.base64EncodedString(), sig.rawRepresentation.base64EncodedString())
    }
    #endif

    func testSignatureRoundTrip() throws {
        let script = "source.getHome = function() { return new VideoPager([], false); };"
        let (keyB64, sigB64) = try sign(script)
        XCTAssertTrue(ScriptSignature.verify(script: script, signatureBase64: sigB64, publicKeyBase64: keyB64))
        XCTAssertFalse(ScriptSignature.verify(script: script + " ", signatureBase64: sigB64, publicKeyBase64: keyB64))
        XCTAssertFalse(ScriptSignature.verify(script: script, signatureBase64: "AAAA", publicKeyBase64: keyB64))
        XCTAssertFalse(ScriptSignature.verify(script: script, signatureBase64: sigB64, publicKeyBase64: "not base64!"))
    }
}
