import Crypto
import Foundation

/// An entity's place in the cache: one per entity and fetch context.
struct CacheSlot: Hashable, Codable, Sendable {
    let key: CacheEntityKey
    let context: CacheContextClass
}

/// A list's place in the cache: one per list and fetch context.
struct CacheListSlot: Hashable, Codable, Sendable {
    let key: CacheListKey
    let context: CacheContextClass
}

/// How an entity is kept. Large fields are blob references, so content
/// shared by many entities is stored once.
struct CacheEntityRecord: Codable, Sendable {
    var key: CacheEntityKey
    /// As fetched. The account, when there is one, is only known for this
    /// device's own fetches (and peers' fetches for an account this device
    /// also has); it never leaves the device except as a keyed hash.
    var context: CacheFetchContext
    /// For a peer's signed-in fetch whose account this device doesn't
    /// know: the hash it arrived with, in the epoch it is stored under.
    var accountHash: String?
    var payload: Data
    var fields: [String: CacheBlobID]
    var fetchedAt: Date
    var origin: CacheOrigin
    /// When this device took it in: placeholders are chosen by it, so
    /// a later variant from another context never displaces one in use.
    var storedAt: Date
    var lastUsed: Date

    init(key: CacheEntityKey, context: CacheFetchContext, accountHash: String?, payload: Data,
         fields: [String: CacheBlobID], fetchedAt: Date, origin: CacheOrigin, storedAt: Date) {
        self.key = key
        self.context = context
        self.accountHash = accountHash
        self.payload = payload
        self.fields = fields
        self.fetchedAt = fetchedAt
        self.origin = origin
        self.storedAt = storedAt
        lastUsed = storedAt
    }

    // Format 1 records had no origin, storedAt or lastUsed; they read as a
    // peer's fetch stored when it was fetched.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(CacheEntityKey.self, forKey: .key)
        context = try c.decode(CacheFetchContext.self, forKey: .context)
        accountHash = try c.decodeIfPresent(String.self, forKey: .accountHash)
        payload = try c.decode(Data.self, forKey: .payload)
        fields = try c.decodeIfPresent([String: CacheBlobID].self, forKey: .fields) ?? [:]
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        origin = try c.decodeIfPresent(CacheOrigin.self, forKey: .origin) ?? .remote
        storedAt = try c.decodeIfPresent(Date.self, forKey: .storedAt) ?? fetchedAt
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed) ?? storedAt
    }

    func stored(in epoch: CacheEpoch) -> StoredContext {
        var stored = context.stored(in: epoch)
        if stored.accountHash == nil, let accountHash { stored.accountHash = accountHash }
        return stored
    }

    var size: Int { payload.count + 160 }
}

/// How a list is kept: references to entities, in order.
struct CacheListRecord: Codable, Sendable {
    var key: CacheListKey
    var context: CacheFetchContext
    var accountHash: String?
    var references: [CacheEntityKey]
    var fetchedAt: Date
    var origin: CacheOrigin
    var storedAt: Date
    var lastUsed: Date

    init(key: CacheListKey, context: CacheFetchContext, accountHash: String?, references: [CacheEntityKey],
         fetchedAt: Date, origin: CacheOrigin, storedAt: Date) {
        self.key = key
        self.context = context
        self.accountHash = accountHash
        self.references = references
        self.fetchedAt = fetchedAt
        self.origin = origin
        self.storedAt = storedAt
        lastUsed = storedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(CacheListKey.self, forKey: .key)
        context = try c.decode(CacheFetchContext.self, forKey: .context)
        accountHash = try c.decodeIfPresent(String.self, forKey: .accountHash)
        references = try c.decode([CacheEntityKey].self, forKey: .references)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        origin = try c.decodeIfPresent(CacheOrigin.self, forKey: .origin) ?? .remote
        storedAt = try c.decodeIfPresent(Date.self, forKey: .storedAt) ?? fetchedAt
        lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed) ?? storedAt
    }

    func stored(in epoch: CacheEpoch) -> StoredContext {
        var stored = context.stored(in: epoch)
        if stored.accountHash == nil, let accountHash { stored.accountHash = accountHash }
        return stored
    }

    var size: Int { references.count * 48 + 160 }
}

/// One frame of a partition file. Every frame is sealed on its own, so a
/// damaged one costs only what it held.
enum CacheFrame: Codable, Sendable {
    case entity(CacheEntityRecord)
    case list(CacheListRecord)
    case blob(CacheBlobID, Data)
    case removeEntity(CacheSlot)
    case removeList(CacheListSlot)
    case removeBlob(CacheBlobID)
}

/// One epoch's records: the current epoch's, or an older one's still being
/// re-keyed.
struct CachePartition: Sendable {
    var epoch: CacheEpoch
    var entities: [CacheSlot: CacheEntityRecord] = [:]
    var lists: [CacheListSlot: CacheListRecord] = [:]
    var blobs: [CacheBlobID: Data] = [:]
    var blobReferences: [CacheBlobID: Int] = [:]
    /// Frames waiting to be appended to the file.
    var pending: [CacheFrame] = []
    /// Frames in the file that later frames replaced or removed.
    var garbage = 0

    init(epoch: CacheEpoch) { self.epoch = epoch }

    func slot(_ record: CacheEntityRecord) -> CacheSlot {
        CacheSlot(key: record.key, context: record.stored(in: epoch).contextClass)
    }

    func slot(_ record: CacheListRecord) -> CacheListSlot {
        CacheListSlot(key: record.key, context: record.stored(in: epoch).contextClass)
    }

    var bytes: Int {
        entities.values.reduce(0) { $0 + $1.size } + lists.values.reduce(0) { $0 + $1.size }
            + blobs.values.reduce(0) { $0 + $1.count }
    }

    /// Stores `content` once, however many entities refer to it.
    mutating func addBlob(_ content: Data) -> CacheBlobID {
        let id = epoch.blobID(for: content)
        if blobs[id] == nil {
            blobs[id] = content
            pending.append(.blob(id, content))
        }
        return id
    }

    mutating func insert(_ record: CacheEntityRecord) {
        let slot = slot(record)
        if let old = entities[slot] { release(old); garbage += 1 }
        for id in record.fields.values { blobReferences[id, default: 0] += 1 }
        entities[slot] = record
        pending.append(.entity(record))
    }

    mutating func insert(_ record: CacheListRecord) {
        let slot = slot(record)
        if lists[slot] != nil { garbage += 1 }
        lists[slot] = record
        pending.append(.list(record))
    }

    @discardableResult
    mutating func removeEntity(_ slot: CacheSlot) -> CacheEntityRecord? {
        guard let record = entities.removeValue(forKey: slot) else { return nil }
        release(record)
        pending.append(.removeEntity(slot))
        garbage += 2
        return record
    }

    @discardableResult
    mutating func removeList(_ slot: CacheListSlot) -> CacheListRecord? {
        guard let record = lists.removeValue(forKey: slot) else { return nil }
        pending.append(.removeList(slot))
        garbage += 2
        return record
    }

    /// Drops blobs nothing refers to any more.
    private mutating func release(_ record: CacheEntityRecord) {
        for id in record.fields.values {
            let count = (blobReferences[id] ?? 1) - 1
            if count <= 0 {
                blobReferences[id] = nil
                if blobs.removeValue(forKey: id) != nil {
                    pending.append(.removeBlob(id))
                    garbage += 2
                }
            } else {
                blobReferences[id] = count
            }
        }
    }

    /// Replays a file's frames. A frame for a record that isn't known any
    /// more (it was damaged) is simply skipped.
    mutating func replay(_ frame: CacheFrame) {
        switch frame {
        case .entity(let record):
            let slot = slot(record)
            if entities[slot] != nil { garbage += 1 }
            entities[slot] = record
        case .list(let record):
            let slot = slot(record)
            if lists[slot] != nil { garbage += 1 }
            lists[slot] = record
        case .blob(let id, let content):
            if blobs[id] != nil { garbage += 1 }
            blobs[id] = content
        case .removeEntity(let slot):
            entities[slot] = nil
            garbage += 2
        case .removeList(let slot):
            lists[slot] = nil
            garbage += 2
        case .removeBlob(let id):
            blobs[id] = nil
            garbage += 2
        }
    }

    /// After a replay: entities whose blobs were lost go too (they'd be
    /// incomplete), blobs nothing uses go, and reference counts are rebuilt.
    /// Returns how many entities were dropped.
    mutating func restoreIntegrity() -> Int {
        var dropped = 0
        for (slot, record) in entities where record.fields.values.contains(where: { blobs[$0] == nil }) {
            entities[slot] = nil
            dropped += 1
        }
        var references: [CacheBlobID: Int] = [:]
        for record in entities.values {
            for id in record.fields.values { references[id, default: 0] += 1 }
        }
        for id in blobs.keys where references[id] == nil { blobs[id] = nil }
        blobReferences = references
        return dropped
    }

    /// Every frame needed to write this partition afresh.
    var snapshotFrames: [CacheFrame] {
        blobs.map { .blob($0.key, $0.value) } + entities.values.map { .entity($0) } + lists.values.map { .list($0) }
    }
}

/// Frames on disk: `magic`, a big-endian length, then the sealed frame.
/// The seal (AES-GCM) is each frame's checksum: one that doesn't open is
/// skipped, and reading resumes at the next magic.
enum CacheFrameFile {
    static let magic = Data("HBC\u{1}".utf8)
    /// The record format. Readers accept every earlier format and migrate
    /// it when the record is next written; a frame in a newer format (from
    /// a later version of the app) is skipped, not treated as damage.
    static let format: UInt8 = 2

    static func encode(_ frame: CacheFrame, epoch: CacheEpoch, profileID: UUID) throws -> Data {
        var body = Data([format])
        body.append(try Zlib.compress(try JSONEncoder().encode(frame)))
        return try encode(body: body, epoch: epoch, profileID: profileID)
    }

    /// `body` is the format byte followed by the compressed frame.
    static func encode(body: Data, epoch: CacheEpoch, profileID: UUID) throws -> Data {
        guard let sealed = try AES.GCM.seal(body, using: epoch.encryption,
                                            authenticating: associatedData(epoch: epoch, profileID: profileID)).combined
        else { throw CocoaError(.fileWriteUnknown) }
        var data = magic
        withUnsafeBytes(of: UInt32(sealed.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(sealed)
        return data
    }

    /// Every frame that opens, in order, and how many didn't.
    static func decode(_ data: Data, epoch: CacheEpoch, profileID: UUID) -> (frames: [CacheFrame], damaged: Int) {
        var frames: [CacheFrame] = []
        var damaged = 0
        var index = data.startIndex
        let associated = associatedData(epoch: epoch, profileID: profileID)
        while index < data.endIndex {
            guard let start = data.range(of: magic, in: index..<data.endIndex)?.lowerBound else { break }
            if start != index { damaged += 1 }
            let lengthStart = start + magic.count
            guard data.endIndex - lengthStart >= 4 else { damaged += 1; break }
            let length = data[lengthStart..<lengthStart + 4].reduce(0) { $0 << 8 | Int($1) }
            let bodyStart = lengthStart + 4
            guard length > 0, data.endIndex - bodyStart >= length,
                  let box = try? AES.GCM.SealedBox(combined: data[bodyStart..<bodyStart + length]),
                  let body = try? AES.GCM.open(box, using: epoch.encryption, authenticating: associated),
                  let version = body.first else {
                damaged += 1
                index = lengthStart
                continue
            }
            index = bodyStart + length
            guard version <= format else { continue }
            guard let json = try? Zlib.decompress(Data(body.dropFirst())),
                  let frame = try? JSONDecoder().decode(CacheFrame.self, from: json) else {
                damaged += 1
                continue
            }
            frames.append(frame)
        }
        return (frames, damaged)
    }

    private static func associatedData(epoch: CacheEpoch, profileID: UUID) -> Data {
        Data("com.eightybps.appsync.cache|\(profileID.uuidString.lowercased())|\(epoch.id.number)|\(epoch.id.id.uuidString.lowercased())".utf8)
    }
}
