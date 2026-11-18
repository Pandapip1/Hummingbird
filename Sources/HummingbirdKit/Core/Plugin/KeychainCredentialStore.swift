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
    // The remaining cases arise only where the platform offers a weaker store
    // the user can opt in to (`CredentialStorageMode.optInFallback`: macOS's
    // login keychain).
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
}

/// Why `KeychainCredentialStore` refused a credential operation.
public enum CredentialStoreAccessError: LocalizedError, Equatable, Sendable {
    case protectedStoreUnavailable(CredentialVaultError)
    case fallbackConsentRequired(CredentialVaultError)
    case fallbackDeclined(CredentialVaultError)
    /// A migrated item did not read back from the Data Protection Keychain,
    /// so its login-keychain copy was kept.
    case migrationNotPersisted(account: String)

    public var errorDescription: String? {
        switch self {
        case .protectedStoreUnavailable(let error):
            "Hummingbird can’t use the protected keychain: \(error.localizedDescription)"
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
        }
    }
}

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
    public let preferences: PreferencesDomain

    public init(key: String, preferences: PreferencesDomain) {
        self.key = key
        self.preferences = preferences
    }

    public func consent() -> LoginKeychainFallbackConsent {
        preferences.defaults.string(forKey: key).flatMap(LoginKeychainFallbackConsent.init(rawValue:))
            ?? .undecided
    }

    public func setConsent(_ consent: LoginKeychainFallbackConsent) {
        if consent == .undecided {
            preferences.defaults.removeObject(forKey: key)
        } else {
            preferences.defaults.set(consent.rawValue, forKey: key)
        }
    }
}

/// App-facing adapter around SwiftOpenUI's platform credential vault.
///
/// The Data Protection Keychain is always preferred. Where the platform offers
/// a weaker store to opt in to (`CredentialStorageMode.optInFallback`, the
/// macOS login keychain) and the Data Protection Keychain refuses this
/// process for a missing entitlement (ad-hoc signed builds), the store
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
    public static func shared(serviceNamespace: String? = nil,
                              preferences: PreferencesDomain) -> KeychainCredentialStore {
        sharedStores.withLock { stores in
            let key = service(namespace: serviceNamespace)
            if let store = stores[key] { return store }
            let store = KeychainCredentialStore(serviceNamespace: serviceNamespace, preferences: preferences)
            stores[key] = store
            return store
        }
    }

    /// Secrets held in protected memory after their first keychain access.
    /// Held under the lock across the keychain call, so concurrent first
    /// reads of an item produce one access (and at most one prompt).
    private let secrets = Mutex<[String: CachedSecret]>([:])
    private let preferred: PlatformCredentialVault
    /// Where the open profile is recorded, to find the item an unlock reads.
    private let preferences: PreferencesDomain
    /// The opt-in weaker store, where the platform has one.
    private let fallback: PlatformCredentialVault?
    private let consentStore: any LoginKeychainFallbackConsentStore
    /// The probe writes a marker item, so it runs once per store; `shared`
    /// gives each service one store per process.
    private let preferredAvailability = Mutex<CredentialVaultAvailability?>(nil)

    /// In a test process the system keychain is reachable only when the run
    /// opted in with `HUMMINGBIRD_SYSTEM_KEYCHAIN_TESTS=1`, and then only
    /// under a per-test service namespace (`tests.<unique>`); anything else
    /// stops the process (see `LiveData`). Tests otherwise pass a fake backend.
    public init(serviceNamespace: String? = nil, backend: any KeychainItemBackend = SystemKeychainBackend(),
                consentStore: (any LoginKeychainFallbackConsentStore)? = nil,
                preferences: PreferencesDomain) {
        let service = Self.service(namespace: serviceNamespace)
        if backend is SystemKeychainBackend { LiveData.requireTestKeychainAccess(serviceNamespace: serviceNamespace) }
        preferred = PlatformCredentialVault(service: service, backend: backend)
        fallback = CredentialStorageMode.optInFallback.map {
            PlatformCredentialVault(service: service, mode: $0, backend: backend)
        }
        self.preferences = preferences
        self.consentStore = consentStore
            ?? UserDefaultsLoginKeychainFallbackConsentStore(
                key: "\(service).loginKeychainFallback", preferences: preferences
            )
    }

    private static func service(namespace: String?) -> String {
        "app.hummingbird\(namespace.map { ".\($0)" } ?? "").credentials.v3"
    }

    public var credentialVaultID: String { preferred.service }

    public var status: CredentialStoreStatus {
        // Without a weaker alternative (the iOS family, Linux's Secret
        // Service) there is no decision to make, so nothing is probed.
        guard fallback != nil else { return .dataProtection }
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
        case .loginKeychainFallback(let error):
            // Only reported where there is a fallback (see `status`).
            guard let fallback else { throw CredentialStoreAccessError.protectedStoreUnavailable(error) }
            return fallback
        case .fallbackConsentRequired(let error): throw CredentialStoreAccessError.fallbackConsentRequired(error)
        case .fallbackDeclined(let error): throw CredentialStoreAccessError.fallbackDeclined(error)
        }
    }

    private func forgetSecrets() {
        secrets.withLock { $0.removeAll() }
    }

    private var activeInstanceAccount: String? {
        guard let raw = preferences.defaults.string(forKey: AppDataStores.localProfileIDKey),
              let id = UUID(uuidString: raw) else { return nil }
        return "com.eightybps.appsync.profile.\(id.uuidString.lowercased()).instance-identity.v1"
    }

    /// Whether this platform has a weaker store the user may opt in to when
    /// the Data Protection Keychain refuses the process, and so whether to
    /// offer the settings below.
    public var offersLoginKeychainFallback: Bool { fallback != nil }

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
        guard let fallback else { return }
        for account in try fallback.accounts() {
            try fallback.delete(account: account)
        }
    }

    /// Accounts Hummingbird keeps in the login keychain. Reads attributes
    /// only, so it never shows a keychain access prompt.
    public func loginKeychainItemAccounts() throws -> [String] {
        try fallback?.accounts() ?? []
    }

    /// Login-keychain items to offer for migration: present only once the
    /// Data Protection Keychain works and the fallback was in use.
    public func migrationCandidates() throws -> [String] {
        guard status == .dataProtection, consentStore.consent() == .accepted, let fallback else { return [] }
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
        guard let fallback else { return 0 }
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
}
