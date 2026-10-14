import Foundation
import ATAppSync
#if canImport(Security)
import Security
import LocalAuthentication
#endif

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
public protocol CredentialStore: AppSyncCredentialStore {
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
    func requiresExplicitUnlock() -> Bool { false }
    func requestUnlock() throws {}
}

#if canImport(Security)
public struct KeychainUnlockError: LocalizedError, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        return "\(message) (\(status))"
    }
}
#endif

/// Facade used by the rest of the app. Apple platforms use the Keychain; other platforms use a private file.
public enum AuthKeychain {
    nonisolated(unsafe) public static var store: CredentialStore = {
        #if canImport(Security)
        return KeychainCredentialStore()
        #else
        return FileCredentialStore()
        #endif
    }()

    public static func load(pluginID: String, kind: String, namespace: String = "") -> SourceAuth? {
        guard let data = store.load(account: "\(namespace)\(pluginID).\(kind)") else { return nil }
        return try? JSONDecoder().decode(SourceAuth.self, from: data)
    }

    public static func save(_ auth: SourceAuth?, pluginID: String, kind: String, namespace: String = "") {
        store.save(auth.flatMap { try? JSONEncoder().encode($0) }, account: "\(namespace)\(pluginID).\(kind)")
    }
}

/// One file per account in a `credentials` folder (mode 0700) beside the app data, each file mode 0600.
/// This protects against other users of the machine, not against code running as the same user; platforms with a
/// keyring (libsecret, Android Keystore) should provide their own `CredentialStore`.
public struct FileCredentialStore: CredentialStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Storage.directory.appendingPathComponent("credentials", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private func url(_ account: String) -> URL {
        let safe = account.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(safe)
    }

    public func load(account: String) -> Data? { try? Data(contentsOf: url(account)) }

    public func save(_ data: Data?, account: String) {
        let u = url(account)
        try? FileManager.default.removeItem(at: u)
        guard let data else { return }
        FileManager.default.createFile(atPath: u.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

#if canImport(Security)
/// Keychain items are only readable while the device is unlocked, never leave the device, and are removed with the plugin.
public struct KeychainCredentialStore: CredentialStore {
    private let appSyncService: String
    private let pluginService: String

    public init(serviceNamespace: String? = nil) {
        let suffix = serviceNamespace.map { ".\($0)" } ?? ""
        appSyncService = "app.hummingbird\(suffix).plugin-auth"
        pluginService = "app.hummingbird\(suffix).plugin-credentials.v2"
    }

    public func requiresExplicitUnlock() -> Bool {
        #if os(macOS)
        // macOS authorization is attached to individual legacy Keychain items;
        // there is no honest application-wide unlock ceremony. In particular,
        // probing or enumerating those items can summon SecurityAgent once per
        // item. Normal reads remain non-interactive and an explicit repair UI
        // can migrate a legacy item if the user asks it to.
        return false
        #else
        // On iOS-family platforms this is a device-data-protection check. Read
        // one representative item with UI forbidden, never enumerate the
        // store. A locked device reports interaction-not-allowed.
        guard let account = activeInstanceAccount else { return false }
        let context = LAContext()
        context.interactionNotAllowed = true
        let status = SecItemCopyMatching(query(
            service: appSyncService, account: account, context: context
        ) as CFDictionary, nil)
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable:
            return true
        default:
            return false
        }
        #endif
    }

    public func requestUnlock() throws {
        guard let account = activeInstanceAccount else { return }
        let context = LAContext()
        context.interactionNotAllowed = false
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(
            service: appSyncService, account: account, context: context
        ) as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainUnlockError(status: status)
        }
    }

    public func load(account: String) -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(
            service: service(for: account), account: account, context: context
        ) as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    public func save(_ data: Data?, account: String) {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service(for: account),
            kSecAttrAccount: account,
        ]
        // CredentialStore has no interactive save operation. This is
        // especially important during identity bootstrap: an inaccessible
        // legacy item must not turn an apparent cache miss into an unsolicited
        // SecurityAgent prompt while attempting to replace it.
        var nonInteractiveBase = base
        let context = LAContext()
        context.interactionNotAllowed = true
        nonInteractiveBase[kSecUseAuthenticationContext] = context
        SecItemDelete(nonInteractiveBase as CFDictionary)
        guard let data else { return }
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private var activeInstanceAccount: String? {
        guard let raw = UserDefaults.standard.string(forKey: "appsync.localProfileID"),
              let id = UUID(uuidString: raw) else { return nil }
        return "com.eightybps.appsync.profile.\(id.uuidString.lowercased()).instance-identity.v1"
    }

    private func service(for account: String) -> String {
        account.hasPrefix("profile.") ? pluginService : appSyncService
    }

    private func query(service: String, account: String, context: LAContext) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
        ]
    }
}
#endif
