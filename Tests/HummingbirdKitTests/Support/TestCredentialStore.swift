import Foundation
import ATAppSync
@testable import HummingbirdKit

final class TestCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func load(account: String) -> Data? {
        lock.withLock { values[account] }
    }

    func save(_ data: Data?, account: String) {
        lock.withLock { values[account] = data }
    }
}

@MainActor
func makeTestAppModel(persistence: AppPersistenceSnapshot = .empty) -> AppModel {
    AppModel(persistence: persistence, credentialStore: TestCredentialStore())
}
