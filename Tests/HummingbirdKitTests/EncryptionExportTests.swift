import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
import Crypto
#endif

/// Info.plist declares ITSAppUsesNonExemptEncryption = false because every
/// cryptographic operation in the Apple builds is a standard algorithm run by
/// Apple's own frameworks: CryptoKit (via swift-crypto, which re-exports it on
/// Apple platforms), Security, and URLSession's TLS. If any of that changes,
/// for example swift-crypto building its own BoringSSL implementation or
/// libsodium being linked, these tests fail and the declaration (and the App
/// Store Connect export compliance answers) must be revisited. See
/// Web/DEPLOYMENT.md.
final class EncryptionExportTests: XCTestCase {
    private static var infoPlist: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HummingbirdKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Apps/iOS/Info.plist")
    }

    func testInfoPlistDeclaresNoNonExemptEncryption() throws {
        let data = try Data(contentsOf: Self.infoPlist)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    }

    #if canImport(CryptoKit)
    /// swift-crypto must forward to the OS's CryptoKit, not ship its own code.
    func testSwiftCryptoIsAppleCryptoKit() {
        XCTAssertTrue(Crypto.AES.GCM.SealedBox.self == CryptoKit.AES.GCM.SealedBox.self)
        XCTAssertTrue(Crypto.P256.KeyAgreement.PrivateKey.self == CryptoKit.P256.KeyAgreement.PrivateKey.self)
        XCTAssertTrue(Crypto.HMAC<Crypto.SHA256>.self == CryptoKit.HMAC<CryptoKit.SHA256>.self)
    }

    /// No non-Apple cryptography implementation is linked into the Apple
    /// build. Package code is linked statically into this test bundle, so its
    /// symbol table shows whether BoringSSL (swift-crypto's own backend) or
    /// libsodium came along.
    func testNoBundledCryptographyLibraryIsLinked() throws {
        let symbols = try Self.definedSymbols()
        // The table must cover statically linked C targets for this check to
        // mean anything: swift-nio's CNIODarwin is one on every Apple build.
        XCTAssertTrue(symbols.contains("_CNIODarwin_CMSG_FIRSTHDR"),
                      "nm didn't list a statically linked C symbol; the check below proves nothing")
        let bundled = symbols.filter {
            $0.hasPrefix("_CCryptoBoringSSL_") || $0.hasPrefix("_sodium_") || $0.hasPrefix("_crypto_aead_")
        }
        XCTAssertEqual(bundled, [], "non-Apple cryptography is linked into the Apple build")
    }

    private static func definedSymbols() throws -> Set<String> {
        let binary = try XCTUnwrap(Bundle(for: EncryptionExportTests.self).executablePath)
        let nm = Process()
        nm.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        nm.arguments = ["-gjU", binary]   // external, defined, names only
        let output = Pipe()
        nm.standardOutput = output
        try nm.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        nm.waitUntilExit()
        XCTAssertEqual(nm.terminationStatus, 0)
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init))
    }
    #endif
}
