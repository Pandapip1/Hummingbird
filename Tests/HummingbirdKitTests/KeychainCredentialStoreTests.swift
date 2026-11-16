#if os(macOS) && !BACKEND_GTK
import ATAppSync
import CredentialStorage
import Foundation
@testable import HummingbirdKit
import XCTest

final class KeychainCredentialStoreTests: XCTestCase {
    private let missingEntitlement = CredentialVaultError(status: CredentialVaultError.missingEntitlementStatus)

    private func makeStore(_ keychain: FakeKeychainBackend,
                           consent: MemoryFallbackConsentStore = .init()) -> KeychainCredentialStore {
        KeychainCredentialStore(serviceNamespace: "tests", backend: keychain, consentStore: consent)
    }

    /// `swift test` binaries are not team-signed, like Hummingbird.app built
    /// from source with xtool, so this exercises the real Security.framework
    /// path. It only probes the Data Protection Keychain; nothing reaches the
    /// login keychain because no consent is given.
    func testUnsignedProcessIsAskedForConsentByTheRealKeychain() throws {
        let store = KeychainCredentialStore(
            serviceNamespace: "tests.\(UUID().uuidString.lowercased())", consentStore: MemoryFallbackConsentStore()
        )
        if store.status == .dataProtection {
            throw XCTSkip("This test process is entitled to the Data Protection Keychain.")
        }
        XCTAssertEqual(store.status, .fallbackConsentRequired(missingEntitlement))
        XCTAssertEqual(CredentialStorageDecision.pending(for: store), .fallbackConsent(missingEntitlement))
        XCTAssertThrowsError(try store.save(SecureBytes(copyingUTF8: "secret"), account: "a")) {
            XCTAssertEqual($0 as? CredentialStoreAccessError, .fallbackConsentRequired(missingEntitlement))
        }
    }

    func testUsesTheDataProtectionKeychainWhenItWorks() throws {
        let keychain = FakeKeychainBackend()
        let store = makeStore(keychain, consent: .init(.accepted))

        XCTAssertEqual(store.status, .dataProtection)
        try store.save(SecureBytes(copyingUTF8: "secret"), account: "a")

        XCTAssertEqual(keychain.value(account: "a", dataProtection: true), "secret")
        XCTAssertEqual(keychain.accounts(dataProtection: false), [])
    }

    func testMissingEntitlementNeverFallsBackWithoutConsent() {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let store = makeStore(keychain)

        XCTAssertEqual(store.status, .fallbackConsentRequired(missingEntitlement))
        XCTAssertThrowsError(try store.save(SecureBytes(copyingUTF8: "secret"), account: "a")) {
            XCTAssertEqual($0 as? CredentialStoreAccessError, .fallbackConsentRequired(missingEntitlement))
        }
        XCTAssertThrowsError(try store.load(account: "a")) {
            XCTAssertEqual($0 as? CredentialStoreAccessError, .fallbackConsentRequired(missingEntitlement))
        }
        XCTAssertEqual(keychain.accounts(dataProtection: false), [])
        XCTAssertEqual(keychain.accounts(dataProtection: true), [])
    }

    func testDecliningLeavesCredentialsUnavailableWithAnExplanation() {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let consent = MemoryFallbackConsentStore()
        let store = makeStore(keychain, consent: consent)

        store.setLoginKeychainFallbackAllowed(false)

        XCTAssertEqual(consent.consent(), .declined)
        XCTAssertEqual(store.status, .fallbackDeclined(missingEntitlement))
        XCTAssertThrowsError(try store.save(SecureBytes(copyingUTF8: "secret"), account: "a")) { error in
            XCTAssertEqual(error as? CredentialStoreAccessError, .fallbackDeclined(missingEntitlement))
            XCTAssertTrue(error.localizedDescription.contains("chose not to store credentials"))
            XCTAssertTrue(error.localizedDescription.contains("-34018"))
        }
        XCTAssertEqual(keychain.accounts(dataProtection: false), [])
    }

    func testOptingInUsesTheLoginKeychain() throws {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let store = makeStore(keychain)

        store.setLoginKeychainFallbackAllowed(true)
        XCTAssertEqual(store.status, .loginKeychainFallback(missingEntitlement))
        try store.save(SecureBytes(copyingUTF8: "secret"), account: "a")

        XCTAssertEqual(try store.load(account: "a")?.unsafeUnprotectedString(), "secret")
        XCTAssertEqual(keychain.value(account: "a", dataProtection: false), "secret")
        try store.delete(account: "a")
        XCTAssertEqual(keychain.accounts(dataProtection: false), [])
    }

    func testOtherProtectedStoreFailuresAreNotOfferedTheFallback() {
        let keychain = FakeKeychainBackend(dataProtectionStatus: -25295)
        let store = makeStore(keychain, consent: .init(.accepted))

        XCTAssertEqual(store.status, .unavailable(CredentialVaultError(status: -25295)))
        XCTAssertThrowsError(try store.save(SecureBytes(copyingUTF8: "secret"), account: "a")) {
            XCTAssertEqual(
                $0 as? CredentialStoreAccessError, .protectedStoreUnavailable(CredentialVaultError(status: -25295))
            )
        }
        XCTAssertEqual(keychain.accounts(dataProtection: false), [])
        XCTAssertNil(CredentialStorageDecision.pending(for: store))
    }

    func testMigratesFallbackItemsOnceTheDataProtectionKeychainWorks() throws {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let consent = MemoryFallbackConsentStore(.accepted)
        let adHoc = makeStore(keychain, consent: consent)
        try adHoc.save(SecureBytes(copyingUTF8: "old-a"), account: "a")
        try adHoc.save(SecureBytes(copyingUTF8: "old-b"), account: "b")

        // A team-signed build on the same Mac.
        keychain.setDataProtectionStatus(nil)
        let signed = makeStore(keychain, consent: consent)
        XCTAssertEqual(signed.status, .dataProtection)
        // Written after the protected store became available, so it is newer.
        try signed.save(SecureBytes(copyingUTF8: "new-b"), account: "b")
        XCTAssertEqual(try signed.migrationCandidates(), ["a", "b"])
        XCTAssertEqual(CredentialStorageDecision.pending(for: signed), .migration(count: 2))

        XCTAssertEqual(try signed.migrateLoginKeychainItems(), 2)

        XCTAssertEqual(keychain.value(account: "a", dataProtection: true), "old-a")
        XCTAssertEqual(keychain.value(account: "b", dataProtection: true), "new-b")
        XCTAssertEqual(keychain.accounts(dataProtection: false), [])
        XCTAssertEqual(consent.consent(), .undecided)
        XCTAssertNil(CredentialStorageDecision.pending(for: signed))
    }

    func testMigrationIsNotOfferedWithoutPriorConsent() throws {
        let keychain = FakeKeychainBackend()
        let store = makeStore(keychain, consent: .init(.declined))
        XCTAssertEqual(try store.migrationCandidates(), [])
        XCTAssertNil(CredentialStorageDecision.pending(for: store))
    }

    func testMigrationRefusesWhileTheDataProtectionKeychainIsUnavailable() throws {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let store = makeStore(keychain, consent: .init(.accepted))
        try store.save(SecureBytes(copyingUTF8: "secret"), account: "a")

        XCTAssertThrowsError(try store.migrateLoginKeychainItems()) {
            XCTAssertEqual($0 as? CredentialStoreAccessError, .protectedStoreUnavailable(missingEntitlement))
        }
        XCTAssertEqual(keychain.accounts(dataProtection: false), ["a"])
    }

    func testRevokingDeletesFallbackItems() throws {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let consent = MemoryFallbackConsentStore(.accepted)
        let store = makeStore(keychain, consent: consent)
        try store.save(SecureBytes(copyingUTF8: "1"), account: "a")
        try store.save(SecureBytes(copyingUTF8: "2"), account: "b")
        XCTAssertEqual(try store.loginKeychainItemAccounts(), ["a", "b"])

        try store.revokeLoginKeychainFallback()

        XCTAssertEqual(keychain.accounts(dataProtection: false), [])
        XCTAssertEqual(consent.consent(), .declined)
        XCTAssertEqual(store.status, .fallbackDeclined(missingEntitlement))
    }

    func testLaunchAsksForConsentBeforeAnySecretIsWritten() {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        XCTAssertEqual(
            CredentialStorageDecision.pending(for: makeStore(keychain)), .fallbackConsent(missingEntitlement)
        )
        XCTAssertEqual(keychain.accounts(dataProtection: false), [])
    }

    func testInstanceIdentityReportsThePreciseStoreError() {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let identities = AppSyncPeerIdentityStore(credentialStore: makeStore(keychain), profileID: UUID())

        XCTAssertThrowsError(try identities.identity()) {
            XCTAssertEqual($0 as? CredentialStoreAccessError, .fallbackConsentRequired(missingEntitlement))
        }
    }

    @MainActor
    func testAppModelExplainsWhyThePeerIdentityIsMissing() {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let app = AppModel(
            credentialStore: makeStore(keychain, consent: .init(.declined)),
            profileStorageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "HummingbirdKeychainTests-\(UUID())", isDirectory: true
            ),
            localProfileID: UUID(),
            localNetworkSyncEnabled: false
        )

        XCTAssertNil(app.peerService)
        XCTAssertEqual(
            app.peerServiceFailure,
            CredentialStoreAccessError.fallbackDeclined(missingEntitlement).localizedDescription
        )
    }
}
#endif
