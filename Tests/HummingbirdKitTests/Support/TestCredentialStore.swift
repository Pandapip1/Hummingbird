import Foundation
import ATAppSync
import CredentialStorage
import XCTest
@testable import HummingbirdKit

final class TestCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SecureBytes] = [:]

    func load(account: String) -> SecureBytes? {
        lock.withLock { values[account] }
    }

    func save(_ secret: SecureBytes, account: String) {
        lock.withLock { values[account] = secret }
    }

    func delete(account: String) {
        lock.withLock { values[account] = nil }
    }
}

extension XCTestCase {
    /// A fresh directory for this test alone, removed when the test ends.
    func makeTestDirectory(_ label: String = "HummingbirdTests") -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A UserDefaults domain for this test alone. Its name is a path, so its
    /// plist is written inside the test's own directory (not
    /// `~/Library/Preferences`) and removed with it.
    func makeTestPreferences(in directory: URL? = nil) -> PreferencesDomain {
        let directory = directory ?? makeTestDirectory("HummingbirdPreferences")
        return .suite(directory.appendingPathComponent("preferences", isDirectory: false).path)
    }

    /// Stores for this test alone: an in-memory SQLite database in place of
    /// `storage.sqlite3`, an in-memory credential store unless the test
    /// supplies one, and a fresh temporary directory for what ATAppSync and
    /// the media cache keep as files (profile registry, profile-sync logs,
    /// peer messages, permission record, media cache) and for a private
    /// UserDefaults domain. Everything is removed when the test ends. Nothing
    /// here can reach the user's real Application Support, Caches,
    /// preferences or keychain.
    func makeTestStores(credentialStore: (any CredentialStore)? = nil) -> AppDataStores {
        let root = makeTestDirectory()
        let stores = AppDataStores(
            dataDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            cachesDirectory: root.appendingPathComponent("Caches", isDirectory: true),
            preferences: makeTestPreferences(in: root),
            credentialStore: credentialStore ?? TestCredentialStore(),
            storage: .inMemory()
        )
        // Runs before the directory's removal (teardown blocks run last-in,
        // first-out), so no queued write is still running when it goes.
        addTeardownBlock { await stores.flush() }
        return stores
    }

    @MainActor
    func makeTestAppModel(persistence: AppPersistenceSnapshot = .empty,
                          stores: AppDataStores? = nil) -> AppModel {
        AppModel(
            persistence: persistence,
            stores: stores ?? makeTestStores(),
            localProfileID: UUID(),
            localNetworkSyncEnabled: false,
            // Never touch this machine's permission record from tests.
            permissions: PermissionGate(system: PlatformPermissions(), ledger: InMemoryPermissionLedger())
        )
    }

    @MainActor
    func makeTestPlayerModel(backend: (any MediaBackend)? = nil,
                             playbackConfirmationTimeout: Duration = .milliseconds(200)) -> PlayerModel {
        let model = PlayerModel(stores: makeTestStores(), backend: backend)
        // Fake backends rarely advance time; do not wait long for first frames.
        model.playbackConfirmationTimeout = playbackConfirmationTimeout
        return model
    }
}
