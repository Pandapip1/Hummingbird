import Foundation

/// A timestamp that remains monotonic when the wall clock moves backwards and
/// can be deterministically ordered across devices.
public struct HybridLogicalTimestamp: Codable, Hashable, Comparable, Sendable {
    public let milliseconds: UInt64
    public let counter: UInt32
    public let deviceID: UUID

    public init(milliseconds: UInt64, counter: UInt32, deviceID: UUID) {
        self.milliseconds = milliseconds
        self.counter = counter
        self.deviceID = deviceID
    }

    enum CodingKeys: String, CodingKey {
        case milliseconds, counter
        case deviceID = "device"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds < rhs.milliseconds }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.deviceID.uuidString < rhs.deviceID.uuidString
    }
}

public struct HybridLogicalClock: Codable, Sendable {
    public let deviceID: UUID
    private var lastMilliseconds: UInt64
    private var counter: UInt32

    public init(deviceID: UUID = UUID(), lastMilliseconds: UInt64 = 0, counter: UInt32 = 0) {
        self.deviceID = deviceID
        self.lastMilliseconds = lastMilliseconds
        self.counter = counter
    }

    public mutating func tick(now: Date = Date()) -> HybridLogicalTimestamp {
        let wall = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
        if wall > lastMilliseconds {
            lastMilliseconds = wall
            counter = 0
        } else {
            counter &+= 1
        }
        return .init(milliseconds: lastMilliseconds, counter: counter, deviceID: deviceID)
    }

    public mutating func observe(_ remote: HybridLogicalTimestamp, now: Date = Date()) {
        let wall = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
        let maximum = max(wall, lastMilliseconds, remote.milliseconds)
        if maximum == lastMilliseconds && maximum == remote.milliseconds {
            counter = max(counter, remote.counter) &+ 1
        } else if maximum == lastMilliseconds {
            counter &+= 1
        } else if maximum == remote.milliseconds {
            counter = remote.counter &+ 1
        } else {
            counter = 0
        }
        lastMilliseconds = maximum
    }
}

/// Globally unique, totally ordered identity for a replicated journal event.
/// The timestamp carries causal/wall-clock order; the UUID is an explicit final
/// tie-breaker for independently-created events with identical timestamps.
public struct JournalEventVersion: Codable, Hashable, Comparable, Sendable {
    public let timestamp: HybridLogicalTimestamp
    public let eventID: UUID

    public init(timestamp: HybridLogicalTimestamp, eventID: UUID) {
        self.timestamp = timestamp
        self.eventID = eventID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.eventID.uuidString < rhs.eventID.uuidString
    }
}

public struct JournalMutation: Codable, Hashable, Sendable, Identifiable {
    public enum Operation: String, Codable, Sendable { case put, delete }

    public let id: UUID
    public let collection: NSID
    public let recordKey: RecordKey
    public let operation: Operation
    public let value: JSONValue?
    public let timestamp: HybridLogicalTimestamp

    public var version: JournalEventVersion { .init(timestamp: timestamp, eventID: id) }

    public init(id: UUID = UUID(), collection: NSID, recordKey: RecordKey,
                operation: Operation, value: JSONValue?, timestamp: HybridLogicalTimestamp) {
        self.id = id
        self.collection = collection
        self.recordKey = recordKey
        self.operation = operation
        self.value = value
        self.timestamp = timestamp
    }
}

public struct JournalSnapshot: Codable, Sendable {
    public var clock: HybridLogicalClock
    public var events: [JournalMutation]
    public var pending: [JournalMutation]
    public var tombstones: [String: JournalEventVersion]
    public var versions: [String: JournalEventVersion]

    public init(clock: HybridLogicalClock, events: [JournalMutation] = [], pending: [JournalMutation] = [],
                tombstones: [String: JournalEventVersion] = [:],
                versions: [String: JournalEventVersion] = [:]) {
        self.clock = clock
        self.events = events
        self.pending = pending
        self.tombstones = tombstones
        self.versions = versions
    }

    enum CodingKeys: String, CodingKey { case clock, events, pending, tombstones, versions }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clock = try values.decode(HybridLogicalClock.self, forKey: .clock)
        pending = try values.decodeIfPresent([JournalMutation].self, forKey: .pending) ?? []
        events = try values.decodeIfPresent([JournalMutation].self, forKey: .events) ?? pending
        if let current = try? values.decode([String: JournalEventVersion].self, forKey: .tombstones) {
            tombstones = current
        } else {
            let legacy = try values.decodeIfPresent([String: HybridLogicalTimestamp].self, forKey: .tombstones) ?? [:]
            tombstones = legacy.mapValues { JournalEventVersion(timestamp: $0, eventID: Self.legacyEventID) }
        }
        if let current = try? values.decode([String: JournalEventVersion].self, forKey: .versions) {
            versions = current
        } else {
            let legacy = try values.decodeIfPresent([String: HybridLogicalTimestamp].self, forKey: .versions) ?? [:]
            versions = legacy.mapValues { JournalEventVersion(timestamp: $0, eventID: Self.legacyEventID) }
            if versions.isEmpty { versions = tombstones }
        }
    }

    private static let legacyEventID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// Durable, thread-safe outbox. Mutations are written atomically before the
/// caller is told they were accepted, so losing connectivity or terminating
/// the app cannot turn a local edit into an untracked edit.
public final class OfflineMutationJournal: @unchecked Sendable {
    private let fileURL: URL
    private var snapshot: JournalSnapshot
    private var knownEventIDs: Set<UUID>
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL, deviceID: UUID = UUID()) throws {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            snapshot = try decoder.decode(JournalSnapshot.self, from: data)
        } else {
            snapshot = JournalSnapshot(clock: HybridLogicalClock(deviceID: deviceID))
        }
        knownEventIDs = Set(snapshot.events.map(\.id))
    }

    @discardableResult
    public func appendPut(collection: NSID, key: RecordKey, value: JSONValue,
                          now: Date = Date()) throws -> JournalMutation {
        try appendPut(collection: collection, key: key, now: now) { _ in value }
    }

    /// Builds the stored value from the same logical timestamp assigned to the
    /// mutation. This prevents application envelopes and outbox metadata from
    /// diverging if the wall clock changes between two calls.
    @discardableResult
    public func appendPut(collection: NSID, key: RecordKey, now: Date = Date(),
                          value: (HybridLogicalTimestamp) throws -> JSONValue) throws -> JournalMutation {
        lock.lock()
        defer { lock.unlock() }
        var updated = snapshot
        let timestamp = updated.clock.tick(now: now)
        let encoded = try value(timestamp)
        let mutation = JournalMutation(collection: collection, recordKey: key,
                                       operation: .put, value: encoded, timestamp: timestamp)
        updated.pending.append(mutation)
        updated.events.append(mutation)
        updated.tombstones[Self.path(collection, key)] = nil
        updated.versions[Self.path(collection, key)] = mutation.version
        try persist(updated)
        snapshot = updated
        knownEventIDs.insert(mutation.id)
        return mutation
    }

    @discardableResult
    public func appendDelete(collection: NSID, key: RecordKey,
                             now: Date = Date()) throws -> JournalMutation {
        lock.lock()
        defer { lock.unlock() }
        var updated = snapshot
        let timestamp = updated.clock.tick(now: now)
        let mutation = JournalMutation(collection: collection, recordKey: key,
                                       operation: .delete, value: nil, timestamp: timestamp)
        updated.pending.append(mutation)
        updated.events.append(mutation)
        updated.tombstones[Self.path(collection, key)] = mutation.version
        updated.versions[Self.path(collection, key)] = mutation.version
        try persist(updated)
        snapshot = updated
        knownEventIDs.insert(mutation.id)
        return mutation
    }

    public func pending() -> [JournalMutation] {
        lock.withLock { snapshot.pending }
    }
    public func events() -> [JournalMutation] {
        lock.withLock { snapshot.events }
    }
    public var isEmpty: Bool { lock.withLock { snapshot.events.isEmpty } }
    public func tombstone(collection: NSID, key: RecordKey) -> JournalEventVersion? {
        lock.withLock { snapshot.tombstones[Self.path(collection, key)] }
    }

    public func version(collection: NSID, key: RecordKey) -> JournalEventVersion? {
        lock.withLock { snapshot.versions[Self.path(collection, key)] }
    }

    /// Unions an immutable event into the journal. Peer-originated events are
    /// queued for ATProto upload; events pulled from ATProto are already there.
    /// Returns true only when the event changes the materialized winner.
    @discardableResult
    public func merge(_ mutation: JournalMutation, needsUpload: Bool) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !knownEventIDs.contains(mutation.id) else { return false }
        var updated = snapshot
        updated.events.append(mutation)
        if needsUpload { updated.pending.append(mutation) }
        updated.clock.observe(mutation.timestamp)
        let path = Self.path(mutation.collection, mutation.recordKey)
        let wins = updated.versions[path].map({ $0 < mutation.version }) ?? true
        if wins {
            updated.versions[path] = mutation.version
            updated.tombstones[path] = mutation.operation == .delete ? mutation.version : nil
        }
        try persist(updated)
        snapshot = updated
        knownEventIDs.insert(mutation.id)
        return wins
    }

    public func acknowledge(_ ids: Set<UUID>) throws {
        lock.lock()
        defer { lock.unlock() }
        var updated = snapshot
        updated.pending.removeAll { ids.contains($0.id) }
        try persist(updated)
        snapshot = updated
    }

    public func observe(_ timestamp: HybridLogicalTimestamp) throws {
        lock.lock()
        defer { lock.unlock() }
        var updated = snapshot
        updated.clock.observe(timestamp)
        try persist(updated)
        snapshot = updated
    }

    private func persist(_ value: JournalSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(value).write(to: fileURL, options: [.atomic])
    }

    private static func path(_ collection: NSID, _ key: RecordKey) -> String {
        collection.rawValue + "/" + key.rawValue
    }
}

public struct VersionedRecord: Codable, Hashable, Sendable {
    public let value: JSONValue
    public let modified: HybridLogicalTimestamp

    public init(value: JSONValue, modified: HybridLogicalTimestamp) {
        self.value = value
        self.modified = modified
    }

    public static func winner(_ lhs: Self?, _ rhs: Self?) -> Self? {
        switch (lhs, rhs) {
        case (.none, _): rhs
        case (_, .none): lhs
        case (.some(let lhs), .some(let rhs)): lhs.modified < rhs.modified ? rhs : lhs
        }
    }
}
