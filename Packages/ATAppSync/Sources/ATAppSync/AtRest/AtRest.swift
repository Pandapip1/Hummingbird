import CredentialStorage
import Crypto
import Foundation
import os
import PlatformSupport
import Synchronization

/// Seals data at rest with a device key (AES-GCM), bound to what it is: a
/// sealed value opened as anything else fails. Data that needs to be read
/// while the device is locked (background sync, the journal, the library)
/// is protected this way rather than by a file class that would lock it
/// away: the key lives in the credential store, readable after the first
/// unlock since boot, this device only, never backed up or synced.
public struct AtRestSealer: Sendable {
    static let magic = Data("HBS1".utf8)

    enum KeySource: Sendable {
        case key(SymmetricKey)
        /// Read from the keyring when first needed: a sealer can be made
        /// before the credential store can be read (before the first unlock,
        /// before the user chooses a store).
        case keyring(AtRestKeyring, account: String)
    }

    private let source: KeySource
    private let purpose: String

    init(key: SymmetricKey, purpose: String) {
        source = .key(key)
        self.purpose = purpose
    }

    init(keyring: AtRestKeyring, account: String, purpose: String) {
        source = .keyring(keyring, account: account)
        self.purpose = purpose
    }

    private func key() throws -> SymmetricKey {
        switch source {
        case .key(let key): key
        case .keyring(let keyring, let account): try keyring.key(account)
        }
    }

    /// A sealer with a fresh key that is never stored (tests, scratch data).
    public static func ephemeral(purpose: String = "ephemeral") -> AtRestSealer {
        AtRestSealer(key: SymmetricKey(size: .bits256), purpose: purpose)
    }

    public func seal(_ plaintext: Data, context: String) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: try key(),
                                              authenticating: associatedData(context)).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Self.magic + combined
    }

    /// What `data` holds: a value this sealer sealed for `context`, data
    /// written before sealing existed (to be sealed when next written), or
    /// something that doesn't open (another key, damage): never discarded
    /// by the caller, but quarantined. `unavailable` when the key can't be
    /// read now: leave the data alone and try again later.
    public func open(_ data: Data, context: String) -> AtRestContent {
        guard data.starts(with: Self.magic) else { return .legacyPlaintext(data) }
        guard let resolved = try? key() else { return .unavailable }
        guard let box = try? AES.GCM.SealedBox(combined: data.dropFirst(Self.magic.count)),
              let opened = try? AES.GCM.open(box, using: resolved, authenticating: associatedData(context)) else {
            return .damaged
        }
        return .opened(opened)
    }

    public static func isSealed(_ data: Data) -> Bool { data.starts(with: magic) }

    private func associatedData(_ context: String) -> Data {
        Data("com.eightybps.atrest.v1|\(purpose)|\(context)".utf8)
    }
}

public enum AtRestContent: Sendable, Equatable {
    case opened(Data)
    /// Written before sealing: readable as is, sealed on the next write.
    case legacyPlaintext(Data)
    /// Doesn't open: quarantine it, don't delete it.
    case damaged
    /// The key can't be read now (credential store locked or undecided):
    /// neither damage nor absence; read again later.
    case unavailable
}

/// Each profile's at-rest keys (and the device's, for data no profile
/// owns), kept in a credential vault the application opens with
/// after-first-unlock, this-device-only accessibility. Keys are created on
/// first use and cached for the process.
public final class AtRestKeyring: Sendable {
    public enum Failure: Error, Equatable {
        /// The vault refused the new key, or didn't keep it.
        case keyNotPersisted
    }

    private let vault: any CredentialDataVault
    private let keys = Mutex<[String: SymmetricKey]>([:])

    public init(vault: any CredentialDataVault) {
        self.vault = vault
    }

    /// A keyring whose keys live in memory only (tests, debug data roots).
    public static func ephemeral() -> AtRestKeyring {
        AtRestKeyring(vault: EphemeralAtRestVault())
    }

    /// The sealer for a profile's data (`profile` nil: the device's own).
    /// Its key is read (or created) when first used.
    public func sealer(profile: UUID?, purpose: String) -> AtRestSealer {
        AtRestSealer(keyring: self, account: account(for: profile), purpose: purpose)
    }

    private func account(for profile: UUID?) -> String {
        "com.eightybps.appsync.at-rest.\(profile?.uuidString.lowercased() ?? "device").v1"
    }

    func key(_ account: String) throws -> SymmetricKey {
        try keys.withLock { keys in
            if let key = keys[account] { return key }
            let key: SymmetricKey
            if let stored = try vault.load(account: account), stored.count == 32 {
                key = SymmetricKey(data: stored)
            } else {
                let fresh = SecureBytes(count: 32) { buffer in
                    for index in buffer.indices { buffer[index] = UInt8.random(in: .min ... .max) }
                }
                try vault.save(fresh, account: account)
                guard let reloaded = try vault.load(account: account), reloaded == fresh else {
                    throw Failure.keyNotPersisted
                }
                key = SymmetricKey(data: fresh)
            }
            keys[account] = key
            return key
        }
    }
}

private final class EphemeralAtRestVault: CredentialDataVault {
    private let items = Mutex<[String: SecureBytes]>([:])
    func load(account: String) throws -> SecureBytes? { items.withLock { $0[account] } }
    func save(_ secret: SecureBytes, account: String) throws { items.withLock { $0[account] = secret } }
    func delete(account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
}

/// Keeps what didn't open, so nothing is lost to a key or disk problem: a
/// copy in `quarantine/` next to where it was found, for later recovery.
public enum AtRestQuarantine {
    static let log = Logger(subsystem: AppSyncDiagnostics.subsystem, category: "appsync.at-rest")

    /// Throws when the copy couldn't be made (a full disk): the caller then
    /// leaves the data where it is rather than lose it.
    public static func keep(_ data: Data, label: String, near file: URL) throws {
        let directory = file.deletingLastPathComponent().appendingPathComponent("quarantine", isDirectory: true)
        let name = "\(file.lastPathComponent).\(label).\(UUID().uuidString.lowercased()).bin"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try AtomicFile.write(data, to: directory.appendingPathComponent(name))
            log.error("at_rest_quarantined label=\(label, privacy: .public) bytes=\(data.count)")
        } catch {
            log.error("at_rest_quarantine_failed error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
