#if os(macOS) && !BACKEND_GTK
import AppKit
import ATAppSync
import CredentialStorage
import Foundation
@testable import HummingbirdKit
import SwiftUI
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

    /// One installed plugin with a sign-in saved by an earlier launch, behind
    /// an opted-in login-keychain store installed as `AuthKeychain.store`.
    private struct PluginSession {
        let keychain: FakeKeychainBackend
        let store: KeychainCredentialStore
        let pluginAccount: String
        let profileID: UUID
        let persistence: AppPersistenceSnapshot
        let storageDirectory: URL

        @MainActor
        func openWindow() -> AppModel {
            AppModel(
                persistence: persistence, credentialStore: store,
                profileStorageDirectory: storageDirectory.appendingPathComponent("profile-sync", isDirectory: true),
                appSyncStorageDirectory: storageDirectory,
                localProfileID: profileID, localNetworkSyncEnabled: false
            )
        }
    }

    @MainActor
    private func startPluginSession() throws -> PluginSession {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let consent = MemoryFallbackConsentStore(.accepted)
        let profileID = UUID()
        let pluginAccount = "profile.\(profileID.uuidString.lowercased()).example.auth"
        try makeStore(keychain, consent: consent).save(
            SecureBytes(jsonEncoding: SourceAuth(headers: ["plugins.example": ["authorization": "Bearer t"]])),
            account: pluginAccount
        )
        let store = makeStore(keychain, consent: consent)
        let previousStore = AuthKeychain.store
        AuthKeychain.store = store
        let configJSON = #"{"name":"Example","id":"example","sourceUrl":"https://plugins.example/config.json"}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(configJSON.utf8))
        var persistence = AppPersistenceSnapshot.empty
        persistence.plugins = [InstalledPlugin(config: config, script: "plugin = {};")]
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HummingbirdKeychainSession-\(UUID())", isDirectory: true
        )
        addTeardownBlock { @MainActor in
            AuthKeychain.store = previousStore
            try? FileManager.default.removeItem(at: storageDirectory)
        }
        keychain.resetAccesses()
        return PluginSession(
            keychain: keychain, store: store, pluginAccount: pluginAccount, profileID: profileID,
            persistence: persistence, storageDirectory: storageDirectory
        )
    }

    /// Re-renders the plugin screen (which shows sign-in state) and the
    /// settings screen many times. View evaluation must never reach the
    /// keychain: credentials are loaded when the model is created.
    @MainActor
    func testRenderingCredentialScreensNeverTouchesTheKeychain() throws {
        let session = try startPluginSession()
        let app = session.openWindow()
        let afterLaunch = session.keychain.accesses
        XCTAssertEqual(afterLaunch.secretReads[session.pluginAccount], 1)

        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        for pass in 0..<50 {
            host.rootView = AnyView(
                VStack {
                    NavigationStack { PluginDetailView(pluginID: "example") }
                    NavigationStack { AppSettingsView(browserToolbar: nil) }
                }
                .environment(app)
                .id(pass)
            )
            host.layoutSubtreeIfNeeded()
            host.display()
            XCTAssertTrue(app.plugins.isLoggedIn("example"))
        }

        XCTAssertEqual(session.keychain.accesses, afterLaunch, "A view evaluation reached the keychain")
    }

    /// A login-keychain session as the user saw it: the app opens a profile,
    /// local sync ticks, remote plugin changes rebuild runtimes, views refresh
    /// sign-in state, and a second window opens the same profile. With an
    /// untrusted signature every secret read can be a keychain prompt, so each
    /// secret must be read at most once per process and written only when it
    /// changes.
    @MainActor
    func testLocalSyncSessionReadsEachSecretAtMostOnce() async throws {
        let session = try startPluginSession()
        let keychain = session.keychain
        let pluginAccount = session.pluginAccount
        func openWindow() -> AppModel { session.openWindow() }

        let window = openWindow()
        for _ in 0..<10 {
            for _ in 0..<3 { XCTAssertTrue(window.plugins.isLoggedIn("example")) }
            _ = window.localProfiles
            await window.profileAccount.sync()
            window.plugins.invalidate("example")
            _ = await window.plugins.runtime(for: "example")
        }
        let secondWindow = openWindow()
        XCTAssertTrue(secondWindow.plugins.isLoggedIn("example"))
        _ = await secondWindow.plugins.runtime(for: "example")
        XCTAssertNil(window.plugins.credentialStorageError)

        let accesses = keychain.accesses
        print("Keychain accesses during the session: \(accesses.total) \(accesses.byOperation.sorted { $0.key < $1.key })")
        print("Secret reads per account: \(accesses.secretReads.sorted { $0.key < $1.key })")
        for (account, reads) in accesses.secretReads {
            XCTAssertLessThanOrEqual(reads, 1, "\(account) was read \(reads) times")
        }
        XCTAssertEqual(accesses.secretReads[pluginAccount], 1)
        XCTAssertLessThanOrEqual(accesses.byOperation["add.dp", default: 0], 1, "The availability probe ran again")
        XCTAssertEqual(accesses.byOperation["update.login", default: 0], 0, "An unchanged secret was rewritten")
    }

    @MainActor
    func testAppModelExplainsWhyThePeerIdentityIsMissing() {
        let keychain = FakeKeychainBackend(dataProtectionStatus: CredentialVaultError.missingEntitlementStatus)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HummingbirdKeychainTests-\(UUID())", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(
            credentialStore: makeStore(keychain, consent: .init(.declined)),
            profileStorageDirectory: root.appendingPathComponent("profile-sync", isDirectory: true),
            appSyncStorageDirectory: root,
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
