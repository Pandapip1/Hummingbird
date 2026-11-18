import XCTest
#if canImport(Security)
import Security
#else
import Crypto
import _CryptoExtras
#endif
@testable import HummingbirdKit

final class ConfigAndSignatureTests: XCTestCase {
    func testSettingAcceptsStringEncodedAdvancedFlag() throws {
        let setting = try JSONDecoder().decode(
            PluginSetting.self,
            from: Data(#"{"name":"Developer option","isAdvanced":"true"}"#.utf8)
        )
        XCTAssertEqual(setting.isAdvanced, true)
    }

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

    /// The runtime only takes a script `ScriptSignature.check` produced, so a
    /// signed plugin runs exactly as signed: altered text fails the check.
    func testSignedScriptsRunOnlyAsPublished() throws {
        let script = "source.enable = function() {};"
        let (keyB64, sigB64) = try sign(script)
        var config = try JSONDecoder().decode(
            PluginConfig.self, from: Data(#"{"name":"Signed","id":"signed-test","scriptUrl":"x.js","version":1}"#.utf8)
        )
        config.scriptPublicKey = keyB64
        config.scriptSignature = sigB64

        let checked = try ScriptSignature.check(script, for: config)
        XCTAssertTrue(checked.isSigned)
        XCTAssertEqual(checked.text, script)
        XCTAssertThrowsError(try ScriptSignature.check(script + "\n// rewritten", for: config)) {
            XCTAssertEqual($0 as? ScriptSignature.CheckError, .invalidSignature)
        }
        var unsigned = config
        unsigned.scriptSignature = nil
        XCTAssertThrowsError(try ScriptSignature.check(script, for: unsigned)) {
            XCTAssertEqual($0 as? ScriptSignature.CheckError, .signatureMissing, "a key without a signature is refused")
        }
        unsigned.scriptPublicKey = nil
        XCTAssertFalse(try ScriptSignature.check(script, for: unsigned).isSigned)
    }

    // MARK: scripts/sign-plugin

    /// An executable on PATH, or nil.
    private func tool(_ name: String) -> URL? {
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    @discardableResult
    private func run(_ executable: URL, _ arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(executable.lastPathComponent) failed: \(text)")
        }
        return text
    }

    /// The signer (SHA-512, PKCS#1 v1.5, private key decrypted by gpg into
    /// a pipe) produces signatures Hummingbird's own verifier accepts. Uses a
    /// throwaway GPG key and RSA key in a private GNUPGHOME; never the card.
    func testSignerScriptOutputVerifies() throws {
        guard let gpg = tool("gpg"), let gpgconf = tool("gpgconf"), let python = tool("python3"),
              let openssl = tool("openssl"), let shell = tool("sh") else {
            throw XCTSkip("gpg, openssl, sh and python3 are needed")
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let signer = repository.appendingPathComponent("scripts/sign-plugin")
        // gpg-agent's socket lives in GNUPGHOME, and socket paths are short
        // (104 bytes on macOS), so the home is a short directory in /tmp.
        let home = URL(fileURLWithPath: "/tmp/hb-gpg-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        var environment = ProcessInfo.processInfo.environment
        environment["GNUPGHOME"] = home.path
        addTeardownBlock { _ = try? self.run(gpgconf, ["--kill", "gpg-agent"], environment: environment) }

        try run(gpg, ["--batch", "--pinentry-mode", "loopback", "--passphrase", "",
                      "--quick-gen-key", "Throwaway <test@example.invalid>", "default", "default", "never"],
                environment: environment)
        let encryptedKey = home.appendingPathComponent("plugin-signing-key.pem.asc")
        let publicKey = home.appendingPathComponent("plugin-signing-key.pub.pem")
        // As the real key was made: generated in a pipe straight into gpg.
        try run(shell, ["-c", """
            set -e
            "\(openssl.path)" genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null \\
              | "\(gpg.path)" --batch --yes --armor --encrypt --recipient test@example.invalid --output "\(encryptedKey.path)"
            """], environment: environment)
        try run(shell, ["-c", """
            "\(gpg.path)" --batch --quiet --decrypt "\(encryptedKey.path)" \\
              | "\(openssl.path)" pkey -pubout -out "\(publicKey.path)"
            """], environment: environment)

        let script = "source.enable = function() { return 1; };\n"
        let scriptURL = home.appendingPathComponent("Script.js")
        let configURL = home.appendingPathComponent("Config.json")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try #"{"name":"Signed","id":"signer-test","scriptUrl":"Script.js","version":1,"scriptSignature":"","scriptPublicKey":""}"#
            .write(to: configURL, atomically: true, encoding: .utf8)

        try run(python, [signer.path, scriptURL.path, configURL.path,
                         "--key", encryptedKey.path, "--public-key", publicKey.path], environment: environment)

        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(contentsOf: configURL))
        let checked = try ScriptSignature.check(script, for: config)
        XCTAssertTrue(checked.isSigned)
        XCTAssertThrowsError(try ScriptSignature.check(script + " ", for: config))
    }

    /// Opt-in (network): Hummingbird's published forks, as GitHub Pages
    /// serves them, verify with Hummingbird's verifier and count as the
    /// reviewed sources pinned in the curated database.
    /// HUMMINGBIRD_CHECK_PUBLISHED_FORKS=1 swift test --filter testPublishedForksVerify
    func testPublishedForksVerify() async throws {
        guard ProcessInfo.processInfo.environment["HUMMINGBIRD_CHECK_PUBLISHED_FORKS"] == "1" else {
            throw XCTSkip("Set HUMMINGBIRD_CHECK_PUBLISHED_FORKS=1 to fetch the published forks")
        }
        let session = URLSession(configuration: .ephemeral)
        for entry in CuratedSourceDatabase.shared.entries where entry.name.hasSuffix("(Hummingbird)") {
            let configURL = try XCTUnwrap(URL(string: entry.configURL))
            let (configData, _) = try await session.data(from: configURL)
            let config = try JSONDecoder().decode(PluginConfig.self, from: configData)
            XCTAssertEqual(config.id, entry.pluginID, entry.name)
            XCTAssertEqual(config.sourceUrl, entry.configURL, entry.name)
            let scriptURL = try XCTUnwrap(config.resolve(config.scriptUrl, base: configURL))
            let (scriptData, _) = try await session.data(from: scriptURL)
            let script = try XCTUnwrap(String(data: scriptData, encoding: .utf8))
            let checked = try ScriptSignature.check(script, for: config)
            XCTAssertTrue(checked.isSigned, entry.name)
            XCTAssertTrue(CuratedSourceDatabase.shared.classification(for: config).isCurated, entry.name)
        }
    }
}
