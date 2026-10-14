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
    func load(account: String) -> Data?
    /// `nil` deletes the entry.
    func save(_ data: Data?, account: String)
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
/// SwiftOpenUI (Data Protection Keychain or Secret Service).
public enum AuthKeychain {
    nonisolated(unsafe) public static var store: CredentialStore = KeychainCredentialStore()

    public static func registerVault() {
        CredentialVaultManager.shared.register(store)
    }

    public static func load(pluginID: String, kind: String, namespace: String = "") -> SourceAuth? {
        guard let data = store.load(account: "\(namespace)\(pluginID).\(kind)") else { return nil }
        return try? JSONDecoder().decode(SourceAuth.self, from: data)
    }

    public static func save(_ auth: SourceAuth?, pluginID: String, kind: String, namespace: String = "") {
        store.save(auth.flatMap { try? JSONEncoder().encode($0) }, account: "\(namespace)\(pluginID).\(kind)")
    }
}

/// App-facing adapter around SwiftOpenUI's platform credential vault.
public struct KeychainCredentialStore: CredentialStore {
    private let vault: PlatformCredentialVault

    public init(serviceNamespace: String? = nil) {
        let suffix = serviceNamespace.map { ".\($0)" } ?? ""
        vault = PlatformCredentialVault(service: "app.hummingbird\(suffix).credentials.v3")
    }

    public var credentialVaultID: String { vault.service }

    public func requiresExplicitUnlock() -> Bool {
        guard let account = activeInstanceAccount else { return false }
        return vault.access(to: account) == .locked
    }

    public func requestUnlock() throws {
        guard let account = activeInstanceAccount else { return }
        try vault.requestAccess(to: account)
    }

    public func load(account: String) -> Data? { vault.load(account: account) }
    public func save(_ data: Data?, account: String) { vault.save(data, account: account) }

    private var activeInstanceAccount: String? {
        guard let raw = UserDefaults.standard.string(forKey: "appsync.localProfileID"),
              let id = UUID(uuidString: raw) else { return nil }
        return "com.eightybps.appsync.profile.\(id.uuidString.lowercased()).instance-identity.v1"
    }

}
