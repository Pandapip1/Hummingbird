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
        var dataProtectionStatus: OSStatus?
    }

    private let state: Mutex<State>

    init(dataProtectionStatus: OSStatus? = nil) {
        state = Mutex(State(dataProtectionStatus: dataProtectionStatus))
    }

    func setDataProtectionStatus(_ status: OSStatus?) {
        state.withLock { $0.dataProtectionStatus = status }
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

    func copyMatching(_ query: [CFString: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        let dataProtection = Self.isDataProtection(query)
        return state.withLock { state in
            if dataProtection, state.dataProtectionStatus != nil { return (errSecItemNotFound, nil) }
            let service = query[kSecAttrService] as? String
            if query[kSecMatchLimit] as? String == kSecMatchLimitAll as String {
                let rows: [[String: Any]] = state.items.keys
                    .filter { $0.dataProtection == dataProtection && $0.service == service }
                    .map { [kSecAttrAccount as String: $0.account] }
                return rows.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, rows as NSArray)
            }
            guard let key = Self.key(query), let value = state.items[key] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, value as NSData)
        }
    }

    func add(_ attributes: [CFString: Any]) -> OSStatus {
        state.withLock { state in
            if Self.isDataProtection(attributes), let status = state.dataProtectionStatus { return status }
            guard let key = Self.key(attributes), let value = Self.copy(attributes[kSecValueData]) else {
                return errSecParam
            }
            guard state.items[key] == nil else { return errSecDuplicateItem }
            state.items[key] = value
            return errSecSuccess
        }
    }

    func update(_ query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
        state.withLock { state in
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
