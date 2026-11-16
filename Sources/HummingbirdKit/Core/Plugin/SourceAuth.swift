import Foundation
import ATAppSync
import CredentialStorage

/// Credentials captured by the login (or captcha) web view: cookies and headers keyed by domain.
public struct SourceAuth: Codable, Equatable, Sendable {
    /// domain (usually with a leading ".") -> cookie name -> value
    public var cookieMap: [String: [String: String]] = [:]
    /// domain -> header name (lowercased) -> value
    public var headers: [String: [String: String]] = [:]
    public var userAgent: String?

    public var isEmpty: Bool { cookieMap.isEmpty && headers.isEmpty }
    public init(cookieMap: [String: [String: String]] = [:], headers: [String: [String: String]] = [:], userAgent: String? = nil) {
        self.cookieMap = cookieMap; self.headers = headers; self.userAgent = userAgent
    }
}

/// Where per-plugin credentials are kept.
public protocol CredentialStore: AppSyncCredentialStore, UnlockableCredentialVault {
    /// Returns `nil` only when no item exists; a store that cannot be used throws.
    func load(account: String) throws -> SecureBytes?
    func save(_ secret: SecureBytes, account: String) throws
    func delete(account: String) throws
    /// Whether protected credentials exist but this process cannot currently
    /// read them without involving the user.
    func requiresExplicitUnlock() -> Bool
    /// Requests credential access as the result of an explicit user action.
    func requestUnlock() throws
}

public extension CredentialStore {
    var credentialVaultID: String { "default" }
    func requiresExplicitUnlock() -> Bool { false }
    func requestUnlock() throws {}
}

/// Facade used by the rest of the app. Platform storage is supplied by
/// SwiftOpenUI (Data Protection Keychain or Secret Service) through
/// `KeychainCredentialStore`, which owns the login-keychain fallback policy.
public enum AuthKeychain {
    nonisolated(unsafe) public static var store: CredentialStore = KeychainCredentialStore.shared()

    /// The platform store, when `store` is one, for storage-mode decisions.
    public static var keychain: KeychainCredentialStore? { store as? KeychainCredentialStore }

    public static func registerVault() {
        CredentialVaultManager.shared.register(store)
    }

    public static func load(pluginID: String, kind: String, namespace: String = "") throws -> SourceAuth? {
        guard let secret = try store.load(account: "\(namespace)\(pluginID).\(kind)") else { return nil }
        // Protection ends here: plugins consume cookies and headers as plain
        // strings, so the decoded SourceAuth lives in ordinary memory.
        return try secret.decodeJSON(SourceAuth.self)
    }

    /// `nil` deletes the stored value.
    public static func save(_ auth: SourceAuth?, pluginID: String, kind: String, namespace: String = "") throws {
        let account = "\(namespace)\(pluginID).\(kind)"
        if let auth {
            try store.save(SecureBytes(jsonEncoding: auth), account: account)
        } else {
            try store.delete(account: account)
        }
    }
}
