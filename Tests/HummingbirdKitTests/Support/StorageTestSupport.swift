import ATAppSync
import CredentialStorage
import Foundation
import Synchronization
@testable import HummingbirdKit

// Tests read values back to check them; the app itself reads with `read`,
// which can't be folded into an optional.

extension Storage {
    func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        if case .value(let value) = read(type, name: name) { value } else { nil }
    }
}

extension StorageBackend {
    func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        if case .value(let value) = read(type, name: name) { value } else { nil }
    }
}

extension StorageDatabase {
    func load(name: String) -> Data? {
        if case .value(let value) = read(name: name) { value } else { nil }
    }
}

/// A credential vault that can be locked, refusing reads and writes as a
/// keychain does before the first unlock.
final class LockableVault: CredentialDataVault {
    private struct State {
        var items: [String: SecureBytes] = [:]
        var locked = false
    }
    private let state = Mutex(State())
    struct Locked: Error {}

    var locked: Bool {
        get { state.withLock { $0.locked } }
        set { state.withLock { $0.locked = newValue } }
    }

    func load(account: String) throws -> SecureBytes? {
        try state.withLock { state in
            if state.locked { throw Locked() }
            return state.items[account]
        }
    }

    func save(_ secret: SecureBytes, account: String) throws {
        try state.withLock { state in
            if state.locked { throw Locked() }
            state.items[account] = secret
        }
    }

    func delete(account: String) throws { _ = state.withLock { $0.items.removeValue(forKey: account) } }
}
