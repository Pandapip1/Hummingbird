import Foundation
import Security

public struct OAuthCredentialStore: Sendable {
    public let service: String
    public let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(_ credential: ATProtoOAuthCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let identity = credential.session.account.rawValue
        let query = baseQuery(account: identity)
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError(status: addStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError(status: status)
        }
    }

    public func load(account: DID) throws -> ATProtoOAuthCredential? {
        var query = baseQuery(account: account.rawValue)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError(status: status)
        }
        return try JSONDecoder().decode(ATProtoOAuthCredential.self, from: data)
    }

    public func remove(account: DID) throws {
        let status = SecItemDelete(baseQuery(account: account.rawValue) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

public struct CredentialStoreError: LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? { "Credential storage failed with OSStatus \(status)." }
}
