import Foundation
import Security

/// Credentials captured by the login (or captcha) web view: cookies and headers keyed by domain.
struct SourceAuth: Codable, Equatable {
    /// domain (usually with a leading ".") -> cookie name -> value
    var cookieMap: [String: [String: String]] = [:]
    /// domain -> header name (lowercased) -> value
    var headers: [String: [String: String]] = [:]
    var userAgent: String?

    var isEmpty: Bool { cookieMap.isEmpty && headers.isEmpty }
}

/// Keychain-backed storage for per-plugin credentials. Items are only readable while the device is unlocked,
/// never leave the device, and are removed when the plugin is removed.
enum AuthKeychain {
    private static let service = "app.jaybird.plugin-auth"

    static func load(pluginID: String, kind: String) -> SourceAuth? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "\(pluginID).\(kind)",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SourceAuth.self, from: data)
    }

    static func save(_ auth: SourceAuth?, pluginID: String, kind: String) {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "\(pluginID).\(kind)",
        ]
        SecItemDelete(base as CFDictionary)
        guard let auth, let data = try? JSONEncoder().encode(auth) else { return }
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
