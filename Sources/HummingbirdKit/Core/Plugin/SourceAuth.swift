import Foundation
#if canImport(Security)
import Security
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
public protocol CredentialStore: Sendable {
    func load(account: String) -> Data?
    /// `nil` deletes the entry.
    func save(_ data: Data?, account: String)
}

/// Facade used by the rest of the app. Apple platforms use the Keychain; other platforms use a private file.
public enum AuthKeychain {
    nonisolated(unsafe) public static var store: CredentialStore = {
        #if canImport(Security)
        return KeychainCredentialStore()
        #else
        return FileCredentialStore()
        #endif
    }()

    public static func load(pluginID: String, kind: String) -> SourceAuth? {
        guard let data = store.load(account: "\(pluginID).\(kind)") else { return nil }
        return try? JSONDecoder().decode(SourceAuth.self, from: data)
    }

    public static func save(_ auth: SourceAuth?, pluginID: String, kind: String) {
        store.save(auth.flatMap { try? JSONEncoder().encode($0) }, account: "\(pluginID).\(kind)")
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
    private let service = "app.jaybird.plugin-auth"
    public init() {}

    public func load(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public func save(_ data: Data?, account: String) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(base as CFDictionary)
        guard let data else { return }
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
#endif
