import CredentialStorage
import Foundation
import XCTest
@testable import HummingbirdKit

/// Keeps tests away from the user's real data. `LiveData` makes the real
/// locations unavailable in a test process and `RealDataGuard` fails any test
/// that changes them; these tests keep both of those working, and keep the
/// app's code from reaching the real locations by any other route.
final class TestIsolationTests: XCTestCase {
    func testThisProcessIsRecognizedAsATestProcess() {
        // Without this, AppDataStores.live and PreferencesDomain.standard
        // would hand tests the user's real data instead of stopping them.
        XCTAssertTrue(LiveData.isTestProcess)
    }

    #if os(macOS)
    /// Revoking and migrating the login-keychain fallback delete every item
    /// under the store's service. Through the in-memory fake backend they
    /// touch nothing real; tests never run them against the system keychain.
    func testKeychainTestsUseAnInMemoryBackend() throws {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let store = KeychainCredentialStore(
            backend: keychain, consentStore: MemoryFallbackConsentStore(.accepted),
            preferences: makeTestPreferences()
        )
        try store.save(SecureBytes(copyingUTF8: "secret"), account: "a")
        XCTAssertEqual(keychain.accounts(dataProtection: false), ["a"])
        try store.revokeLoginKeychainFallback()
        XCTAssertEqual(keychain.accounts(dataProtection: false), [])
    }
    #endif

    func testTestStoresKeepTheDatabaseInMemory() async throws {
        let stores = makeTestStores()
        stores.storage.save(["value"], name: "probe")
        await stores.flush()
        XCTAssertEqual(stores.storage.load([String].self, name: "probe"), ["value"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stores.dataDirectory.appendingPathComponent("storage.sqlite3").path
        ))
    }

    func testTestStoresLiveInTheirOwnTemporaryDirectory() throws {
        let stores = makeTestStores()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertTrue(stores.dataDirectory.standardizedFileURL.path.hasPrefix(temporary))
        XCTAssertTrue(stores.cachesDirectory.standardizedFileURL.path.hasPrefix(temporary))
        guard case .suite(let suite) = stores.preferences else {
            return XCTFail("Test stores must not use the app's own UserDefaults domain")
        }
        XCTAssertTrue(suite.hasPrefix(temporary), "The preferences plist must be written inside the test directory")
        XCTAssertTrue(stores.credentialStore is TestCredentialStore)

        stores.defaults.set("value", forKey: "isolation-probe")
        XCTAssertEqual(PreferencesDomain.suite(suite).defaults.string(forKey: "isolation-probe"), "value")
        XCTAssertNotEqual(makeTestStores().dataDirectory, stores.dataDirectory, "Each test gets fresh stores")
    }

    /// Only `LiveData` names the real locations, and only the application
    /// entry points open the real stores. Anything else would bypass the
    /// guard that stops tests from reaching them.
    func testOnlyLiveDataReachesTheRealLocations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let rules: [(pattern: String, allowed: Set<String>)] = [
            ("UserDefaults.standard", ["Sources/HummingbirdKit/Core/Support/LiveData.swift"]),
            ("for: .applicationSupportDirectory", ["Sources/HummingbirdKit/Core/Support/LiveData.swift"]),
            ("for: .cachesDirectory", ["Sources/HummingbirdKit/Core/Support/LiveData.swift"]),
            ("for: .libraryDirectory", []),
            ("for: .documentDirectory", []),
            ("NSHomeDirectory", []),
            ("homeDirectoryForCurrentUser", []),
            ("@AppStorage(\"", []),
            ("KeychainCredentialStore.shared(", ["Sources/HummingbirdKit/Core/Services/AppDataStores.swift"]),
            // The keychain guard sits in KeychainCredentialStore's initializer.
            ("SystemKeychainBackend(", ["Sources/HummingbirdKit/Core/Plugin/KeychainCredentialStore.swift"]),
            ("PlatformCredentialVault(", ["Sources/HummingbirdKit/Core/Plugin/KeychainCredentialStore.swift"]),
            ("AppDataStores.live(", [
                "Sources/HummingbirdKit/Core/Services/AppDataStores.swift",
                "Apps/iOS/HummingbirdApp.swift",
                "Sources/HummingbirdGTK/main.swift",
            ]),
        ]
        var violations: [String] = []
        for directory in ["Sources", "Apps"] {
            let base = root.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                return XCTFail("Could not read \(base.path)")
            }
            for case let file as URL in files where file.pathExtension == "swift" {
                let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { continue }
                    for rule in rules where code.contains(rule.pattern) && !rule.allowed.contains(relative) {
                        violations.append("\(relative):\(index + 1): \(rule.pattern)")
                    }
                }
            }
        }
        XCTAssertEqual(violations, [], "Reach persistent state through AppDataStores, not directly")
    }
}
