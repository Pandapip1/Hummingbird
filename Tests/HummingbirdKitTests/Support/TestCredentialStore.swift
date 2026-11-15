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

    func save(_ secret: SecureBytes?, account: String) {
        lock.withLock { values[account] = secret }
    }
}

@MainActor
func makeTestAppModel(persistence: AppPersistenceSnapshot = .empty) -> AppModel {
    AppModel(
        persistence: persistence,
        credentialStore: TestCredentialStore(),
        profileStorageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "HummingbirdProfileTests-\(UUID())", isDirectory: true
        ),
        localProfileID: UUID(),
        localNetworkSyncEnabled: false
    )
}
