import Foundation
import ATAppSync
import CredentialStorage
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

@MainActor
func makeTestAppModel(persistence: AppPersistenceSnapshot = .empty) -> AppModel {
    // Never the real Storage.directory: AppModel registers its profile there.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "HummingbirdProfileTests-\(UUID())", isDirectory: true
    )
    return AppModel(
        persistence: persistence,
        credentialStore: TestCredentialStore(),
        profileStorageDirectory: root.appendingPathComponent("profile-sync", isDirectory: true),
        appSyncStorageDirectory: root,
        localProfileID: UUID(),
        localNetworkSyncEnabled: false
    )
}
