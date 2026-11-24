import CZlib
import CredentialStorage
import Crypto
import Foundation

/// Identifies a cache key epoch. Epochs are ordered by number, then by ID,
/// so two devices that rotate at once agree on which epoch wins.
public struct CacheEpochID: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let number: UInt64
    public let id: UUID

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.number, lhs.id.uuidString) < (rhs.number, rhs.id.uuidString)
    }

    public var description: String { "epoch \(number)" }
}

/// One epoch of a profile's cache keys, shared by the trusted devices it was
/// made for (`members`) and no others. A device that leaves the trusted set
/// keeps the epochs it had, so the remaining devices move to a new one: it
/// can't compute the new blob IDs or account hashes, or read anything
/// written under the new keys. Epochs also turn over periodically, so a key
/// that leaked is worth little for long.
struct CacheEpoch: Sendable {
    let id: CacheEpochID
    let createdAt: Date
    var members: Set<AppSyncPeerID>
    /// Seals records at rest.
    let encryption: SymmetricKey
    /// Keys content-addressed blob IDs, so an ID says nothing about the
    /// content to anyone without the key.
    let blobs: SymmetricKey
    /// Keys the hashes of signed-in accounts in fetch contexts.
    let accounts: SymmetricKey

    static func generate(number: UInt64, members: Set<AppSyncPeerID>, now: Date) -> CacheEpoch {
        CacheEpoch(id: CacheEpochID(number: number, id: UUID()), createdAt: now, members: members,
                   encryption: SymmetricKey(size: .bits256), blobs: SymmetricKey(size: .bits256),
                   accounts: SymmetricKey(size: .bits256))
    }

    func blobID(for content: Data) -> CacheBlobID {
        CacheBlobID(raw: Self.hex(HMAC<SHA256>.authenticationCode(for: content, using: blobs), bytes: 16))
    }

    func accountHash(_ account: String) -> String {
        Self.hex(HMAC<SHA256>.authenticationCode(for: Data(account.utf8), using: accounts), bytes: 16)
    }

    private static func hex(_ mac: HMAC<SHA256>.MAC, bytes: Int) -> String {
        Data(mac).prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }

    var offer: CacheEpochOffer {
        CacheEpochOffer(id: id, createdAt: createdAt, members: members,
                        encryption: encryption.withUnsafeBytes { Data($0) },
                        blobs: blobs.withUnsafeBytes { Data($0) },
                        accounts: accounts.withUnsafeBytes { Data($0) })
    }

    init(id: CacheEpochID, createdAt: Date, members: Set<AppSyncPeerID>,
         encryption: SymmetricKey, blobs: SymmetricKey, accounts: SymmetricKey) {
        self.id = id
        self.createdAt = createdAt
        self.members = members
        self.encryption = encryption
        self.blobs = blobs
        self.accounts = accounts
    }

    init(_ offer: CacheEpochOffer) {
        self.init(id: offer.id, createdAt: offer.createdAt, members: offer.members,
                  encryption: SymmetricKey(data: offer.encryption), blobs: SymmetricKey(data: offer.blobs),
                  accounts: SymmetricKey(data: offer.accounts))
    }
}

/// An epoch's keys as they travel to another member: only ever inside an
/// envelope sealed to that member's instance key, and as stored in the
/// credential store.
public struct CacheEpochOffer: Codable, Sendable {
    public let id: CacheEpochID
    let createdAt: Date
    let members: Set<AppSyncPeerID>
    let encryption: Data
    let blobs: Data
    let accounts: Data
}

/// A blob's keyed content address.
public struct CacheBlobID: Hashable, Codable, Sendable, CustomStringConvertible {
    let raw: String
    public var description: String { "CacheBlobID(<redacted>)" }
}

/// Keeps a profile's cache epochs in the credential store (the keychain on
/// Apple platforms), next to the instance identity: the current one, and any
/// older ones whose records haven't been re-keyed yet. Removing an epoch
/// from here is what erases it.
struct CacheEpochStore: Sendable {
    let credentialStore: any AppSyncCredentialStore
    let account: String

    struct Stored: Codable {
        var current: CacheEpochOffer?
        var retired: [CacheEpochOffer] = []
    }

    init(credentialStore: any AppSyncCredentialStore, profileID: UUID) {
        self.credentialStore = credentialStore
        account = "com.eightybps.appsync.profile.\(profileID.uuidString.lowercased()).cache-epochs.v1"
    }

    func load() throws -> (current: CacheEpoch?, retired: [CacheEpoch]) {
        guard let secret = try credentialStore.load(account: account),
              let stored = try? secret.decodeJSON(Stored.self) else { return (nil, []) }
        return (stored.current.map(CacheEpoch.init), stored.retired.map(CacheEpoch.init))
    }

    func save(current: CacheEpoch?, retired: [CacheEpoch]) throws {
        let stored = Stored(current: current?.offer, retired: retired.map(\.offer))
        try credentialStore.save(try SecureBytes(jsonEncoding: stored), account: account)
    }

    /// Erases every epoch: nothing sealed under them can be read again.
    func erase() throws { try credentialStore.delete(account: account) }
}

/// zlib deflate with the uncompressed length in front.
enum Zlib {
    struct Failure: Error {}

    static func compress(_ data: Data) throws -> Data {
        var length = uLongf(compressBound(uLong(data.count)))
        var output = Data(count: Int(length))
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compress2(out.bindMemory(to: Bytef.self).baseAddress, &length,
                          input.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_BEST_SPEED)
            }
        }
        guard status == Z_OK else { throw Failure() }
        var framed = withUnsafeBytes(of: UInt64(data.count).bigEndian) { Data($0) }
        framed.append(output.prefix(Int(length)))
        return framed
    }

    static func decompress(_ data: Data) throws -> Data {
        guard data.count >= 8 else { throw Failure() }
        let expected = data.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        // No record is this large; refuse rather than allocate it.
        guard expected <= 1 << 28 else { throw Failure() }
        if expected == 0 { return Data() }
        var length = uLongf(expected)
        var output = Data(count: Int(expected))
        let body = Data(data.dropFirst(8))
        let status = output.withUnsafeMutableBytes { out in
            body.withUnsafeBytes { input in
                uncompress(out.bindMemory(to: Bytef.self).baseAddress, &length,
                           input.bindMemory(to: Bytef.self).baseAddress, uLong(body.count))
            }
        }
        guard status == Z_OK, UInt64(length) == expected else { throw Failure() }
        return output
    }
}
