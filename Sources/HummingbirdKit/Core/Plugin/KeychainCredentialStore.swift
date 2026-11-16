import CredentialStorage
import Foundation
import Synchronization

/// Which store `KeychainCredentialStore` currently uses, or why it uses none.
public enum CredentialStoreStatus: Equatable, Sendable {
    /// The protected store: the Data Protection Keychain on Apple platforms,
    /// the Secret Service on Linux.
    case dataProtection
    /// The protected store refused this process for a reason other than a
    /// missing entitlement. No fallback is offered for this.
    case unavailable(CredentialVaultError)
    #if os(macOS)
    /// The Data Protection Keychain is unavailable and the user opted in to
    /// the much less secure login keychain on this device.
    case loginKeychainFallback(CredentialVaultError)
    /// The Data Protection Keychain is unavailable (usually because the build
    /// is not team-signed) and the user has not yet been asked about the
    /// login keychain. Nothing is stored until they answer.
    case fallbackConsentRequired(CredentialVaultError)
    /// The Data Protection Keychain is unavailable and the user declined the
    /// login keychain, so credentials cannot be stored.
    case fallbackDeclined(CredentialVaultError)
    #endif
}

/// Why `KeychainCredentialStore` refused a credential operation.
public enum CredentialStoreAccessError: LocalizedError, Equatable, Sendable {
    case protectedStoreUnavailable(CredentialVaultError)
    #if os(macOS)
    case fallbackConsentRequired(CredentialVaultError)
    case fallbackDeclined(CredentialVaultError)
    /// A migrated item did not read back from the Data Protection Keychain,
    /// so its login-keychain copy was kept.
    case migrationNotPersisted(account: String)
    #endif

    public var errorDescription: String? {
        switch self {
        case .protectedStoreUnavailable(let error):
            "Hummingbird can’t use the protected keychain: \(error.localizedDescription)"
        #if os(macOS)
        case .fallbackConsentRequired(let error):
            "Hummingbird can’t store credentials in the protected data-protection keychain "
                + "(\(error.localizedDescription)). This usually means this copy of Hummingbird isn’t "
                + "signed by an Apple development team. Sign-ins, plugin credentials and sync are "
                + "unavailable until you choose whether to allow the less secure login keychain."
        case .fallbackDeclined(let error):
            "Sign-ins, plugin credentials and sync are unavailable: this copy of Hummingbird can’t use "
                + "the protected data-protection keychain (\(error.localizedDescription)), and you chose "
                + "not to store credentials in the less secure login keychain. You can change this in "
                + "Settings under Credential Storage."
        case .migrationNotPersisted:
            "A credential moved to the protected keychain could not be read back, so its "
                + "login-keychain copy was kept."
        #endif
        }
    }
}

#if os(macOS)
/// The user's answer to the login-keychain fallback question on this device.
public enum LoginKeychainFallbackConsent: String, Sendable {
    case undecided, accepted, declined
}

public protocol LoginKeychainFallbackConsentStore: Sendable {
    func consent() -> LoginKeychainFallbackConsent
    func setConsent(_ consent: LoginKeychainFallbackConsent)
}

/// Keeps the answer in this device's user defaults, which are not synced.
public struct UserDefaultsLoginKeychainFallbackConsentStore: LoginKeychainFallbackConsentStore {
    public let key: String

    public init(key: String) { self.key = key }

    public func consent() -> LoginKeychainFallbackConsent {
        UserDefaults.standard.string(forKey: key).flatMap(LoginKeychainFallbackConsent.init(rawValue:))
            ?? .undecided
    }

    public func setConsent(_ consent: LoginKeychainFallbackConsent) {
        if consent == .undecided {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(consent.rawValue, forKey: key)
        }
    }
}
#endif

/// App-facing adapter around SwiftOpenUI's platform credential vault.
///
/// The Data Protection Keychain is always preferred. On macOS, when it refuses
/// this process for a missing entitlement (ad-hoc signed builds), the store
/// does not fall back on its own: it reports `fallbackConsentRequired` and
/// throws until the app has asked the user, and uses the login keychain only
/// after they accept. When the Data Protection Keychain becomes available
/// again, it is used immediately and any login-keychain items are offered for
/// migration.
public final class KeychainCredentialStore: CredentialStore {
    /// What this process last read from or wrote to the active store for an
    /// account. `nil` records that the item is absent.
    private struct CachedSecret: Sendable {
        let value: SecureBytes?
    }

    private static let sharedStores = Mutex<[String: KeychainCredentialStore]>([:])

    /// The process-wide store for a service. Every caller shares its
    /// availability probe and its secret cache, so each item is read from the
    /// keychain at most once per process. (A login-keychain read is a
    /// potential access prompt.)
    public static func shared(serviceNamespace: String? = nil) -> KeychainCredentialStore {
        sharedStores.withLock { stores in
            let key = service(namespace: serviceNamespace)
            if let store = stores[key] { return store }
            let store = KeychainCredentialStore(serviceNamespace: serviceNamespace)
            stores[key] = store
            return store
        }
    }

    /// Secrets held in protected memory after their first keychain access.
    /// Held under the lock across the keychain call, so concurrent first
    /// reads of an item produce one access (and at most one prompt).
    private let secrets = Mutex<[String: CachedSecret]>([:])
    private let preferred: PlatformCredentialVault
    #if os(macOS)
    private let fallback: PlatformCredentialVault
    private let consentStore: any LoginKeychainFallbackConsentStore
    /// The probe writes a marker item, so it runs once per store; `shared`
    /// gives each service one store per process.
    private let preferredAvailability = Mutex<CredentialVaultAvailability?>(nil)
    #endif

    #if os(macOS)
    public init(serviceNamespace: String? = nil, backend: any KeychainItemBackend = SystemKeychainBackend(),
                consentStore: (any LoginKeychainFallbackConsentStore)? = nil) {
        let service = Self.service(namespace: serviceNamespace)
        preferred = PlatformCredentialVault(service: service, backend: backend)
        fallback = PlatformCredentialVault(service: service, mode: .legacyLoginKeychain, backend: backend)
        self.consentStore = consentStore
            ?? UserDefaultsLoginKeychainFallbackConsentStore(key: "\(service).loginKeychainFallback")
    }
    #else
    public init(serviceNamespace: String? = nil, backend: any KeychainItemBackend = SystemKeychainBackend()) {
        preferred = PlatformCredentialVault(service: Self.service(namespace: serviceNamespace), backend: backend)
    }
    #endif

    private static func service(namespace: String?) -> String {
        "app.hummingbird\(namespace.map { ".\($0)" } ?? "").credentials.v3"
    }

    public var credentialVaultID: String { preferred.service }

    public var status: CredentialStoreStatus {
        #if os(macOS)
        switch probedAvailability() {
        case .available, .locked:
            return .dataProtection
        case .failed(let error):
            return .unavailable(error)
        case .dataProtectionKeychainUnavailable(let error):
            switch consentStore.consent() {
            case .accepted: return .loginKeychainFallback(error)
            case .declined: return .fallbackDeclined(error)
            case .undecided: return .fallbackConsentRequired(error)
            }
        }
        #else
        // Linux's Secret Service and the iOS-family keychains have no weaker
        // alternative to offer, so there is nothing to probe for.
        return .dataProtection
        #endif
    }

    public func requiresExplicitUnlock() -> Bool {
        guard status == .dataProtection, let account = activeInstanceAccount,
              secrets.withLock({ $0[account] }) == nil else { return false }
        return preferred.access(to: account) == .locked
    }

    public func requestUnlock() throws {
        guard status == .dataProtection, let account = activeInstanceAccount else { return }
        try preferred.requestAccess(to: account)
    }

    public func load(account: String) throws -> SecureBytes? {
        let vault = try activeVault()
        return try secrets.withLock { secrets in
            if let known = secrets[account] { return known.value }
            let loaded = try vault.load(account: account)
            secrets[account] = CachedSecret(value: loaded)
            return loaded
        }
    }

    /// Writes only when the value differs from what this process last read or
    /// wrote, so re-saving unchanged state never touches the keychain.
    public func save(_ secret: SecureBytes, account: String) throws {
        let vault = try activeVault()
        try secrets.withLock { secrets in
            if let known = secrets[account], known.value == secret { return }
            try vault.save(secret, account: account)
            secrets[account] = CachedSecret(value: secret)
        }
    }

    public func delete(account: String) throws {
        let vault = try activeVault()
        try secrets.withLock { secrets in
            if let known = secrets[account], known.value == nil { return }
            try vault.delete(account: account)
            secrets[account] = CachedSecret(value: nil)
        }
    }

    private func activeVault() throws -> PlatformCredentialVault {
        switch status {
        case .dataProtection: return preferred
        case .unavailable(let error): throw CredentialStoreAccessError.protectedStoreUnavailable(error)
        #if os(macOS)
        case .loginKeychainFallback: return fallback
        case .fallbackConsentRequired(let error): throw CredentialStoreAccessError.fallbackConsentRequired(error)
        case .fallbackDeclined(let error): throw CredentialStoreAccessError.fallbackDeclined(error)
        #endif
        }
    }

    private func forgetSecrets() {
        secrets.withLock { $0.removeAll() }
    }

    private var activeInstanceAccount: String? {
        guard let raw = UserDefaults.standard.string(forKey: "appsync.localProfileID"),
              let id = UUID(uuidString: raw) else { return nil }
        return "com.eightybps.appsync.profile.\(id.uuidString.lowercased()).instance-identity.v1"
    }

    #if os(macOS)
    public var loginKeychainFallbackConsent: LoginKeychainFallbackConsent { consentStore.consent() }

    /// Records the user's answer to the opt-in prompt.
    public func setLoginKeychainFallbackAllowed(_ allowed: Bool) {
        consentStore.setConsent(allowed ? .accepted : .declined)
        forgetSecrets()
    }

    /// Withdraws consent and deletes every item Hummingbird keeps in the login
    /// keychain. Consent is withdrawn first, so nothing new is written there
    /// even if a deletion fails.
    public func revokeLoginKeychainFallback() throws {
        consentStore.setConsent(.declined)
        forgetSecrets()
        for account in try fallback.accounts() {
            try fallback.delete(account: account)
        }
    }

    /// Accounts Hummingbird keeps in the login keychain. Reads attributes
    /// only, so it never shows a keychain access prompt.
    public func loginKeychainItemAccounts() throws -> [String] {
        try fallback.accounts()
    }

    /// Login-keychain items to offer for migration: present only once the
    /// Data Protection Keychain works and the fallback was in use.
    public func migrationCandidates() throws -> [String] {
        guard status == .dataProtection, consentStore.consent() == .accepted else { return [] }
        return try fallback.accounts()
    }

    /// Moves every login-keychain item into the Data Protection Keychain and
    /// deletes the login-keychain copies. An item already present in the Data
    /// Protection Keychain was written there after it became available, so it
    /// is newer and wins. Each copy is verified before its original is
    /// removed; on failure the remaining items stay where they are. Once
    /// everything has moved, the opt-in is cleared, so the user is asked again
    /// if the Data Protection Keychain ever becomes unavailable.
    @discardableResult
    public func migrateLoginKeychainItems() throws -> Int {
        switch status {
        case .dataProtection:
            break
        case .unavailable(let error), .loginKeychainFallback(let error),
             .fallbackConsentRequired(let error), .fallbackDeclined(let error):
            throw CredentialStoreAccessError.protectedStoreUnavailable(error)
        }
        let accounts = try fallback.accounts()
        for account in accounts {
            if try preferred.load(account: account) == nil, let secret = try fallback.load(account: account) {
                try preferred.save(secret, account: account)
                guard try preferred.load(account: account) == secret else {
                    throw CredentialStoreAccessError.migrationNotPersisted(account: account)
                }
            }
            try fallback.delete(account: account)
        }
        consentStore.setConsent(.undecided)
        forgetSecrets()
        return accounts.count
    }

    private func probedAvailability() -> CredentialVaultAvailability {
        if let known = preferredAvailability.withLock({ $0 }) { return known }
        let probed = preferred.probeAvailability()
        preferredAvailability.withLock { $0 = probed }
        return probed
    }
    #endif
}
