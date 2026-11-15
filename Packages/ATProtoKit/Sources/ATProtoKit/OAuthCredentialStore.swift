import CredentialStorage
import Foundation

/// Codable AT Protocol sessions stored through the application's platform
/// credential vault. ATProtoKit owns the encoding, never the platform UI or
/// credential-service policy.
public struct OAuthCredentialStore: Sendable {
    public let service: String
    private let vault: any CredentialDataVault

    public init(service: String, vault: any CredentialDataVault) {
        self.service = service
        self.vault = vault
    }

    public func save(_ credential: ATProtoOAuthCredential) throws {
        let secret = try SecureBytes(jsonEncoding: credential)
        let account = vaultAccount(credential.session.account.rawValue)
        vault.save(secret, account: account)
        guard vault.load(account: account) == secret else { throw CredentialStoreError.writeFailed }
    }

    public func load(account: DID) throws -> ATProtoOAuthCredential? {
        guard let secret = vault.load(account: vaultAccount(account.rawValue)) else { return nil }
        // Tokens and the DPoP key decode back into SecureBytes fields.
        return try secret.decodeJSON(ATProtoOAuthCredential.self)
    }

    public func remove(account: DID) throws {
        vault.save(nil, account: vaultAccount(account.rawValue))
    }

    private func vaultAccount(_ identity: String) -> String {
        "\(service).oauth.\(identity)"
    }
}

public enum CredentialStoreError: LocalizedError, Sendable {
    case writeFailed

    public var errorDescription: String? {
        "The credential vault did not persist the AT Protocol session."
    }
}
