#if os(macOS)
import CredentialStorage
import Foundation
@testable import HummingbirdKit
import Security
import Synchronization

/// In-memory Security item calls with the Data Protection Keychain and the
/// file-based login keychain kept apart, as on macOS. While
/// `dataProtectionStatus` is set, Data Protection writes and deletes fail with
/// it and lookups report `errSecItemNotFound`, which is what an unentitled
/// (ad-hoc signed) process observes from the real keychain.
final class FakeKeychainBackend: KeychainItemBackend {
    private struct Key: Hashable {
        let dataProtection: Bool
        let service: String
        let account: String
    }

    private struct State {
        var items: [Key: Data] = [:]
        /// Each item's accessibility class, as the vault asked for it.
        var accessibility: [Key: String] = [:]
        var device = DeviceLock.unlocked
        var dataProtectionStatus: OSStatus?
        var accesses = KeychainAccessCounts()
    }

    private let state: Mutex<State>

    init(dataProtectionStatus: OSStatus? = nil) {
        state = Mutex(State(dataProtectionStatus: dataProtectionStatus))
    }

    func setDataProtectionStatus(_ status: OSStatus?) {
        state.withLock { $0.dataProtectionStatus = status }
    }

    /// The device's lock state, as the keychain sees it.
    enum DeviceLock: Sendable { case unlocked, lockedAfterFirstUnlock, beforeFirstUnlock }

    func setDevice(_ lock: DeviceLock) { state.withLock { $0.device = lock } }

    /// Whether an item of `accessibility` can be read in the current state,
    /// as the system keychain decides it.
    private static func readable(_ accessibility: String?, device: DeviceLock) -> Bool {
        switch device {
        case .unlocked: true
        case .lockedAfterFirstUnlock: accessibility == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            || accessibility == (kSecAttrAccessibleAfterFirstUnlock as String)
        case .beforeFirstUnlock: false
        }
    }

    func accounts(dataProtection: Bool) -> [String] {
        state.withLock { state in
            state.items.keys.filter { $0.dataProtection == dataProtection }.map(\.account).sorted()
        }
    }

    func value(account: String, dataProtection: Bool) -> String? {
        state.withLock { state in
            state.items.first { $0.key.account == account && $0.key.dataProtection == dataProtection }
                .map { String(decoding: $0.value, as: UTF8.self) }
        }
    }

    var accesses: KeychainAccessCounts { state.withLock { $0.accesses } }

    func resetAccesses() { state.withLock { $0.accesses = KeychainAccessCounts() } }

    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        let dataProtection = Self.isDataProtection(query)
        return state.withLock { state in
            state.accesses.record(dataProtection ? "copy.dp" : "copy.login", query)
            if dataProtection, state.dataProtectionStatus != nil { return (errSecItemNotFound, nil) }
            let service = query[kSecAttrService] as? String
            if query[kSecMatchLimit] as? String == kSecMatchLimitAll as String {
                let rows: [[String: Any]] = state.items.keys
                    .filter { $0.dataProtection == dataProtection && $0.service == service }
                    .map { [kSecAttrAccount as String: $0.account] }
                return rows.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, rows as NSArray)
            }
            guard let key = Self.key(query), let value = state.items[key] else { return (errSecItemNotFound, nil) }
            // Locked: an item whose class doesn't allow reading now is refused.
            guard !Self.isDataProtection(query) || Self.readable(state.accessibility[key], device: state.device) else {
                return (CredentialVaultError.interactionNotAllowedStatus, nil)
            }
            return (errSecSuccess, value as NSData)
        }
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        state.withLock { state in
            state.accesses.record(Self.isDataProtection(attributes) ? "add.dp" : "add.login", attributes)
            if Self.isDataProtection(attributes), let status = state.dataProtectionStatus { return status }
            guard let key = Self.key(attributes), let value = Self.copy(attributes[kSecValueData]) else {
                return errSecParam
            }
            guard state.items[key] == nil else { return errSecDuplicateItem }
            state.items[key] = value
            state.accessibility[key] = attributes[kSecAttrAccessible] as? String
            return errSecSuccess
        }
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        state.withLock { state in
            state.accesses.record(Self.isDataProtection(query) ? "update.dp" : "update.login", query)
            if Self.isDataProtection(query), let status = state.dataProtectionStatus { return status }
            guard let key = Self.key(query), let value = Self.copy(attributes[kSecValueData]) else {
                return errSecParam
            }
            guard state.items[key] != nil else { return errSecItemNotFound }
            state.items[key] = value
            return errSecSuccess
        }
    }

    func delete(_ query: [CFString: Any]) -> OSStatus {
        state.withLock { state in
            state.accesses.record(Self.isDataProtection(query) ? "delete.dp" : "delete.login", query)
            if Self.isDataProtection(query), let status = state.dataProtectionStatus { return status }
            guard let key = Self.key(query) else { return errSecParam }
            return state.items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    private static func isDataProtection(_ query: [CFString: Any]) -> Bool {
        query[kSecUseDataProtectionKeychain] as? Bool == true
    }

    private static func key(_ query: [CFString: Any]) -> Key? {
        guard let service = query[kSecAttrService] as? String,
              let account = query[kSecAttrAccount] as? String else { return nil }
        return Key(dataProtection: isDataProtection(query), service: service, account: account)
    }

    /// The vault wipes its value buffer after each call, so copy it now.
    private static func copy(_ value: Any?) -> Data? {
        (value as? Data).map { Data(Array($0)) }
    }
}

final class MemoryFallbackConsentStore: LoginKeychainFallbackConsentStore {
    private let value: Mutex<LoginKeychainFallbackConsent>

    init(_ consent: LoginKeychainFallbackConsent = .undecided) {
        value = Mutex(consent)
    }

    func consent() -> LoginKeychainFallbackConsent { value.withLock { $0 } }
    func setConsent(_ consent: LoginKeychainFallbackConsent) { value.withLock { $0 = consent } }
}
#endif

#if os(macOS)
/// Every Security item call a test made, by operation and by account.
struct KeychainAccessCounts: Equatable, Sendable {
    private(set) var byOperation: [String: Int] = [:]
    /// Lookups that return secret data, per account: each one is a potential
    /// keychain access prompt for login-keychain items.
    private(set) var secretReads: [String: Int] = [:]

    var total: Int { byOperation.values.reduce(0, +) }
    var totalSecretReads: Int { secretReads.values.reduce(0, +) }

    mutating func record(_ operation: String, _ query: [CFString: Any]) {
        byOperation[operation, default: 0] += 1
        if query[kSecReturnData] as? Bool == true, let account = query[kSecAttrAccount] as? String {
            secretReads[account, default: 0] += 1
        }
    }
}
#endif
