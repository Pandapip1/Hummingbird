import Crypto
import Foundation
import ATProtoKit

/// Semantic application-facing names for durable replicated mutations.
/// Signed journal batches remain an ATAppSync wire/storage detail.
public typealias AppSyncMutation = JournalMutation
public typealias AppSyncMutationLog = OfflineMutationJournal
public typealias AppSyncMutationSigner = JournalEventSigner

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

public struct JournalEventSigner: Sendable {
    public let instanceID: UUID
    public let publicKey: Data
    private let privateKey: P256.Signing.PrivateKey

    public init(instanceID: UUID, privateKeyRepresentation: Data) throws {
        self.instanceID = instanceID
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation)
        publicKey = privateKey.publicKey.rawRepresentation
    }

    func signature(for input: Data) throws -> Data {
        try privateKey.signature(for: input).derRepresentation
    }

    public func sign(domain: String, payload: Data) throws -> Data {
        var transcript = Data(domain.utf8)
        transcript.append(0)
        transcript.append(payload)
        return try privateKey.signature(for: transcript).derRepresentation
    }
}

public enum JournalSignatureError: Error, Equatable {
    case incompleteSignature, invalidSignature, unresolvedEvent, duplicateReference
    case nonFiniteNumber, duplicateNormalizedKey
}

public struct JournalEventReference: Codable, Hashable, Sendable {
    public let eventID: UUID
    public let index: Int

    public init(eventID: UUID, index: Int) {
        self.eventID = eventID
        self.index = index
    }
}

public struct JournalEventBucket: Codable, Hashable, Sendable {
    public let eventID: UUID
    public let values: [JournalMutation]

    public init(eventID: UUID, values: [JournalMutation]) {
        self.eventID = eventID
        self.values = values
    }
}

/// A submission signs the ordered, resolved mutation data rather than the
/// transport's event-ID-to-data map. Collision indices keep UUID collisions
/// lossless, while the signature prevents the map from being substituted.
public struct ReplicatedJournalBatch: Codable, Hashable, Sendable {
    public let type: String
    public let batchID: UUID
    public let eventData: [JournalEventBucket]
    public let events: [JournalEventReference]
    public let originInstanceID: UUID
    public let originSigningKey: Data
    public let signature: Data

    public init(type: String, batchID: UUID, eventData: [JournalEventBucket],
                events: [JournalEventReference], originInstanceID: UUID,
                originSigningKey: Data, signature: Data) {
        self.type = type
        self.batchID = batchID
        self.eventData = eventData
        self.events = events
        self.originInstanceID = originInstanceID
        self.originSigningKey = originSigningKey
        self.signature = signature
    }

    public init(type: NSID, batchID: UUID = UUID(), mutations: [JournalMutation],
                signer: JournalEventSigner) throws {
        var indices: [UUID: Int] = [:]
        var buckets: [UUID: [JournalMutation]] = [:]
        var references: [JournalEventReference] = []
        for mutation in mutations {
            let index = indices[mutation.id, default: 0]
            indices[mutation.id] = index + 1
            buckets[mutation.id, default: []].append(mutation)
            references.append(.init(eventID: mutation.id, index: index))
        }
        self.type = type.rawValue
        self.batchID = batchID
        eventData = buckets.map { .init(eventID: $0.key, values: $0.value) }
            .sorted { $0.eventID.uuidString < $1.eventID.uuidString }
        events = references
        originInstanceID = signer.instanceID
        originSigningKey = signer.publicKey
        signature = try signer.signature(for: Self.signatureInput(
            batchID: batchID, instanceID: signer.instanceID, signingKey: signer.publicKey,
            mutations: mutations
        ))
    }

    public func verifiedMutations() throws -> [JournalMutation] {
        guard Set(eventData.map(\.eventID)).count == eventData.count else {
            throw JournalSignatureError.unresolvedEvent
        }
        let lookup = Dictionary(uniqueKeysWithValues: eventData.map { ($0.eventID, $0.values) })
        var seen = Set<JournalEventReference>()
        let resolved = try events.map { reference -> JournalMutation in
            guard seen.insert(reference).inserted else { throw JournalSignatureError.duplicateReference }
            guard reference.index >= 0, let values = lookup[reference.eventID],
                  values.indices.contains(reference.index) else {
                throw JournalSignatureError.unresolvedEvent
            }
            let mutation = values[reference.index]
            guard mutation.id == reference.eventID else { throw JournalSignatureError.unresolvedEvent }
            return mutation
        }
        let key = try P256.Signing.PublicKey(rawRepresentation: originSigningKey)
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        let input = try Self.signatureInput(
            batchID: batchID, instanceID: originInstanceID,
            signingKey: originSigningKey, mutations: resolved
        )
        guard key.isValidSignature(parsed, for: input) else {
            throw JournalSignatureError.invalidSignature
        }
        return resolved
    }

    func verifiedEntries() throws -> [JournalEventReference: JournalMutation] {
        let resolved = try verifiedMutations()
        return Dictionary(uniqueKeysWithValues: zip(events, resolved))
    }

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case batchID, eventData, events, originInstanceID, originSigningKey, signature
    }

    private static func signatureInput(batchID: UUID, instanceID: UUID, signingKey: Data,
                                       mutations: [JournalMutation]) throws -> Data {
        var transcript = CanonicalJournalTranscript()
        transcript.bytes(Data("com.eightybps.appsync.journal-batch-signature".utf8))
        transcript.u8(1)
        transcript.uuid(batchID)
        transcript.uuid(instanceID)
        transcript.bytes(signingKey)
        transcript.u64(UInt64(mutations.count))
        for mutation in mutations { transcript.mutation(mutation) }
        return try transcript.finish()
    }
}

/// Where a reader of a journal got up to: the journal's identity and the
/// last local arrival it has seen. Arrivals are local to one journal file.
public struct JournalCursor: Codable, Hashable, Sendable {
    public let epoch: UUID
    public let arrival: UInt64

    public init(epoch: UUID, arrival: UInt64) {
        self.epoch = epoch
        self.arrival = arrival
    }
}

public struct JournalSnapshot: Codable, Sendable {
    public var clock: HybridLogicalClock
    /// The winning event of every record (puts and deletes). Superseded
    /// events carry no state, so they are dropped as soon as they lose.
    public var events: [JournalMutation]
    public var pending: [JournalMutation]
    public var tombstones: [String: JournalEventVersion]
    public var versions: [String: JournalEventVersion]
    /// The version of each record the application has made its state match.
    /// Local edits are applied when they are made; merged events are applied
    /// only when the application says so, so a failed apply is retried.
    /// Journals written before this was tracked decode with none applied,
    /// which makes the application reconcile every record once.
    public var applied: [String: JournalEventVersion]
    /// The local arrival number of each event in `events`, keyed by event ID.
    public var arrivals: [String: UInt64]
    public var lastArrival: UInt64
    /// Identifies this journal's arrival numbering to incremental readers.
    public var epoch: UUID
    /// Per collection with a retention limit: the newest version dropped to
    /// keep within it. Anything at or below it is ignored when merged, so a
    /// peer that still holds a dropped record can't bring it back.
    public var floors: [String: JournalEventVersion]

    public init(clock: HybridLogicalClock, events: [JournalMutation] = [], pending: [JournalMutation] = [],
                tombstones: [String: JournalEventVersion] = [:],
                versions: [String: JournalEventVersion] = [:]) {
        self.clock = clock
        self.events = events
        self.pending = pending
        self.tombstones = tombstones
        self.versions = versions
        applied = [:]
        arrivals = [:]
        lastArrival = 0
        epoch = UUID()
        floors = [:]
        numberUnnumberedEvents()
    }

    enum CodingKeys: String, CodingKey {
        case clock, events, pending, tombstones, versions, applied, arrivals, lastArrival, epoch, floors
    }

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
        applied = try values.decodeIfPresent([String: JournalEventVersion].self, forKey: .applied) ?? [:]
        arrivals = try values.decodeIfPresent([String: UInt64].self, forKey: .arrivals) ?? [:]
        lastArrival = try values.decodeIfPresent(UInt64.self, forKey: .lastArrival) ?? 0
        epoch = try values.decodeIfPresent(UUID.self, forKey: .epoch) ?? UUID()
        floors = try values.decodeIfPresent([String: JournalEventVersion].self, forKey: .floors) ?? [:]
        compact()
        adoptLegacyVersions()
        numberUnnumberedEvents()
    }

    static func path(_ collection: NSID, _ key: RecordKey) -> String {
        collection.rawValue + "/" + key.rawValue
    }

    /// Keeps only each record's newest event. Journals written before
    /// superseded events were dropped can hold thousands of them (a progress
    /// update every few seconds), all copied into every snapshot.
    mutating func compact() {
        var newest: [String: JournalEventVersion] = [:]
        for event in events {
            let path = Self.path(event.collection, event.recordKey)
            if newest[path].map({ $0 < event.version }) ?? true { newest[path] = event.version }
        }
        let superseded = Set(events.filter {
            newest[Self.path($0.collection, $0.recordKey)] != $0.version
        }.map(\.id))
        guard !superseded.isEmpty else { return }
        events.removeAll { superseded.contains($0.id) }
        pending.removeAll { superseded.contains($0.id) }
        for id in superseded { arrivals[id.uuidString] = nil }
    }

    /// Journals from before event IDs recorded versions as bare timestamps.
    /// Where the record's event is still here, its full version replaces
    /// the bare one, so the record can be matched (and applied) again.
    private mutating func adoptLegacyVersions() {
        for event in events {
            let path = Self.path(event.collection, event.recordKey)
            guard let version = versions[path], version.eventID == Self.legacyEventID,
                  version.timestamp == event.timestamp else { continue }
            versions[path] = event.version
            if tombstones[path] != nil { tombstones[path] = event.version }
        }
    }

    /// Drops the oldest records of each collection over its limit, without
    /// tombstones, raising that collection's floor. Returns the dropped
    /// event IDs. Every device applies the same rule to the same versions.
    mutating func enforce(_ retention: [NSID: Int]) -> Set<UUID> {
        var dropped = Set<UUID>()
        for (collection, limit) in retention {
            let records = events.filter { $0.collection == collection }
            guard records.count > limit else { continue }
            let oldest = records.sorted { $0.version > $1.version }.dropFirst(limit)
            for event in oldest {
                let path = Self.path(event.collection, event.recordKey)
                versions[path] = nil
                tombstones[path] = nil
                applied[path] = nil
                arrivals[event.id.uuidString] = nil
                dropped.insert(event.id)
            }
            if let newestDropped = oldest.first?.version {
                floors[collection.rawValue] = max(floors[collection.rawValue] ?? newestDropped, newestDropped)
            }
        }
        guard !dropped.isEmpty else { return [] }
        events.removeAll { dropped.contains($0.id) }
        pending.removeAll { dropped.contains($0.id) }
        return dropped
    }

    private mutating func numberUnnumberedEvents() {
        for event in events where arrivals[event.id.uuidString] == nil {
            lastArrival += 1
            arrivals[event.id.uuidString] = lastArrival
        }
    }

    /// Records `mutation` as its record's winner: it replaces the previous
    /// winner's event and gets the next arrival number. Returns the ID of the
    /// event it superseded, if any.
    mutating func insertWinner(_ mutation: JournalMutation, pending isPending: Bool) -> UUID? {
        let path = Self.path(mutation.collection, mutation.recordKey)
        let previous = versions[path]
        events.append(mutation)
        if isPending { pending.append(mutation) }
        versions[path] = mutation.version
        tombstones[path] = mutation.operation == .delete ? mutation.version : nil
        lastArrival += 1
        arrivals[mutation.id.uuidString] = lastArrival
        guard let previous, previous.eventID != mutation.id else { return nil }
        arrivals[previous.eventID.uuidString] = nil
        return previous.eventID
    }

    private static let legacyEventID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// A record to append, for appending many in one durable write.
public struct JournalPut: Sendable {
    public let collection: NSID
    public let key: RecordKey
    public let value: JSONValue

    public init(collection: NSID, key: RecordKey, value: JSONValue) {
        self.collection = collection
        self.key = key
        self.value = value
    }
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
    private let signer: JournalEventSigner?
    private let retention: [NSID: Int]

    /// `retention` caps how many records a collection keeps: beyond it the
    /// oldest (by version) are dropped without tombstones, the same on
    /// every device, so a journal of an ever-growing collection (playback
    /// history) stays bounded.
    public init(fileURL: URL, deviceID: UUID = UUID(), signer: JournalEventSigner? = nil,
                retention: [NSID: Int] = [:]) throws {
        self.fileURL = fileURL
        self.signer = signer
        self.retention = retention
        if let data = try? Data(contentsOf: fileURL) {
            snapshot = try decoder.decode(JournalSnapshot.self, from: data)
        } else {
            snapshot = JournalSnapshot(clock: HybridLogicalClock(deviceID: deviceID))
        }
        _ = snapshot.enforce(retention)
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
        try appendLocal { updated in
            let timestamp = updated.clock.tick(now: now)
            return JournalMutation(collection: collection, recordKey: key,
                                   operation: .put, value: try value(timestamp), timestamp: timestamp)
        }
    }

    @discardableResult
    public func appendDelete(collection: NSID, key: RecordKey,
                             now: Date = Date()) throws -> JournalMutation {
        try appendLocal { updated in
            let timestamp = updated.clock.tick(now: now)
            return JournalMutation(collection: collection, recordKey: key,
                                   operation: .delete, value: nil, timestamp: timestamp)
        }
    }

    /// Appends local puts in one durable write. With `onlyUnknownRecords`,
    /// a record the journal already has a version for (including a delete)
    /// is skipped, which is how existing local state is introduced to a
    /// journal without overriding anything it already knows. Returns the
    /// appended mutations.
    @discardableResult
    public func appendPuts(_ puts: [JournalPut], onlyUnknownRecords: Bool,
                           now: Date = Date()) throws -> [JournalMutation] {
        lock.lock()
        defer { lock.unlock() }
        var updated = snapshot
        var appended: [JournalMutation] = []
        var superseded = Set<UUID>()
        for put in puts {
            let path = JournalSnapshot.path(put.collection, put.key)
            if onlyUnknownRecords, updated.versions[path] != nil { continue }
            let timestamp = updated.clock.tick(now: now)
            let mutation = JournalMutation(collection: put.collection, recordKey: put.key,
                                           operation: .put, value: put.value, timestamp: timestamp)
            if let old = updated.insertWinner(mutation, pending: true) { superseded.insert(old) }
            updated.applied[path] = mutation.version
            appended.append(mutation)
        }
        guard !appended.isEmpty else { return [] }
        updated.events.removeAll { superseded.contains($0.id) }
        updated.pending.removeAll { superseded.contains($0.id) }
        let dropped = updated.enforce(retention)
        try persist(updated)
        snapshot = updated
        knownEventIDs.subtract(superseded.union(dropped))
        knownEventIDs.formUnion(appended.map(\.id))
        return appended
    }

    /// A local edit is applied by definition: the application made it.
    private func appendLocal(_ make: (inout JournalSnapshot) throws -> JournalMutation) throws -> JournalMutation {
        lock.lock()
        defer { lock.unlock() }
        var updated = snapshot
        let mutation = try make(&updated)
        let superseded = updated.insertWinner(mutation, pending: true)
        if let superseded {
            updated.events.removeAll { $0.id == superseded }
            updated.pending.removeAll { $0.id == superseded }
        }
        updated.applied[JournalSnapshot.path(mutation.collection, mutation.recordKey)] = mutation.version
        let dropped = updated.enforce(retention)
        try persist(updated)
        snapshot = updated
        if let superseded { knownEventIDs.remove(superseded) }
        knownEventIDs.subtract(dropped)
        knownEventIDs.insert(mutation.id)
        return mutation
    }

    public func pending() -> [JournalMutation] {
        lock.withLock { snapshot.pending }
    }
    public func events() -> [JournalMutation] {
        lock.withLock { snapshot.events }
    }

    /// The events that arrived after `cursor`, and the cursor to ask from
    /// next time. A cursor from another journal (or none) gets every event.
    public func events(after cursor: JournalCursor?) -> (events: [JournalMutation], cursor: JournalCursor) {
        lock.withLock {
            let next = JournalCursor(epoch: snapshot.epoch, arrival: snapshot.lastArrival)
            guard let cursor, cursor.epoch == snapshot.epoch, cursor.arrival <= snapshot.lastArrival else {
                return (snapshot.events, next)
            }
            let arrivals = snapshot.arrivals
            return (snapshot.events.filter { (arrivals[$0.id.uuidString] ?? .max) > cursor.arrival }, next)
        }
    }

    public var isEmpty: Bool { lock.withLock { snapshot.events.isEmpty } }
    public func tombstone(collection: NSID, key: RecordKey) -> JournalEventVersion? {
        lock.withLock { snapshot.tombstones[JournalSnapshot.path(collection, key)] }
    }

    public func version(collection: NSID, key: RecordKey) -> JournalEventVersion? {
        lock.withLock { snapshot.versions[JournalSnapshot.path(collection, key)] }
    }

    /// Every record whose winning event the application has not applied
    /// yet, as that event. A record stays here until `markApplied` names
    /// its current winner, so an apply that fails is offered again.
    public func unappliedWinners() -> [JournalMutation] {
        lock.withLock {
            snapshot.events.filter { event in
                let path = JournalSnapshot.path(event.collection, event.recordKey)
                return snapshot.versions[path] == event.version && snapshot.applied[path] != event.version
            }
        }
    }

    /// Records that the application's state now matches these events. An
    /// event that has since lost to a newer one is ignored: the newer one
    /// still needs applying.
    public func markApplied(_ mutations: [JournalMutation]) throws {
        lock.lock()
        defer { lock.unlock() }
        var updated = snapshot
        var changed = false
        for mutation in mutations {
            let path = JournalSnapshot.path(mutation.collection, mutation.recordKey)
            guard updated.versions[path] == mutation.version, updated.applied[path] != mutation.version else { continue }
            updated.applied[path] = mutation.version
            changed = true
        }
        guard changed else { return }
        try persist(updated)
        snapshot = updated
    }

    /// Unions an immutable event into the journal. Peer-originated events are
    /// queued for ATProto upload; events pulled from ATProto are already there.
    /// Returns true only when the event changes the materialized winner.
    @discardableResult
    public func merge(_ mutation: JournalMutation, needsUpload: Bool) throws -> Bool {
        try merge([mutation], needsUpload: needsUpload).contains { $0.id == mutation.id }
    }

    /// Unions several immutable events with a single durable write, which a
    /// pull of many events needs: the journal is rewritten whole on every
    /// write. Returns, in order, the events that changed their record's
    /// materialized winner at the moment they were merged. An event that
    /// loses to what the journal has carries no state and is not kept. The
    /// result is the same whatever order events arrive in.
    @discardableResult
    public func merge(_ mutations: [JournalMutation], needsUpload: Bool) throws -> [JournalMutation] {
        lock.lock()
        defer { lock.unlock() }
        var updated = snapshot
        var known = knownEventIDs
        var winners: [JournalMutation] = []
        var superseded = Set<UUID>()
        for mutation in mutations where !known.contains(mutation.id) {
            let path = JournalSnapshot.path(mutation.collection, mutation.recordKey)
            // A losing event is older than a winner the clock has already
            // observed, so only winners move the clock.
            guard updated.versions[path].map({ $0 < mutation.version }) ?? true else { continue }
            // Older than what retention already dropped: gone for good.
            if let floor = updated.floors[mutation.collection.rawValue], mutation.version <= floor { continue }
            updated.clock.observe(mutation.timestamp)
            if let old = updated.insertWinner(mutation, pending: needsUpload) {
                superseded.insert(old)
                known.remove(old)
            }
            winners.append(mutation)
            known.insert(mutation.id)
        }
        guard !winners.isEmpty else { return [] }
        updated.events.removeAll { superseded.contains($0.id) }
        updated.pending.removeAll { superseded.contains($0.id) }
        let dropped = updated.enforce(retention)
        try persist(updated)
        snapshot = updated
        knownEventIDs = known.subtracting(dropped)
        return winners.filter { !dropped.contains($0.id) }
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

    public func signedBatch(type: NSID, mutations: [JournalMutation]) throws -> ReplicatedJournalBatch {
        guard let signer else { throw JournalSignatureError.incompleteSignature }
        return try ReplicatedJournalBatch(type: type, mutations: mutations, signer: signer)
    }
}

private struct CanonicalJournalTranscript {
    private var data = Data()
    private var error: JournalSignatureError?

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u32(_ value: UInt32) { fixed(value.bigEndian) }
    mutating func u64(_ value: UInt64) { fixed(value.bigEndian) }
    mutating func i64(_ value: Int64) { fixed(UInt64(bitPattern: value).bigEndian) }
    mutating func bytes(_ value: Data) { u64(UInt64(value.count)); data.append(value) }
    mutating func string(_ value: String) {
        bytes(Data(value.precomposedStringWithCanonicalMapping.utf8))
    }
    mutating func uuid(_ value: UUID) {
        var raw = value.uuid
        withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
    }
    mutating func optionalUUID(_ value: UUID?) {
        guard let value else { u8(0); return }
        u8(1); uuid(value)
    }
    mutating func optionalBytes(_ value: Data?) {
        guard let value else { u8(0); return }
        u8(1); bytes(value)
    }
    mutating func optionalJSON(_ value: JSONValue?) {
        guard let value else { u8(0); return }
        u8(1); json(value)
    }
    mutating func mutation(_ value: JournalMutation) {
        uuid(value.id)
        string(value.collection.rawValue)
        string(value.recordKey.rawValue)
        u8(value.operation == .put ? 1 : 2)
        optionalJSON(value.value)
        u64(value.timestamp.milliseconds)
        u32(value.timestamp.counter)
        uuid(value.timestamp.deviceID)
    }
    mutating func json(_ value: JSONValue) {
        switch value {
        case .null: u8(0)
        case .bool(let value): u8(value ? 2 : 1)
        case .integer(let value): u8(3); i64(Int64(value))
        case .double(let value):
            guard value.isFinite else { error = .nonFiniteNumber; return }
            u8(4)
            let normalized = value == 0 ? 0.0 : value
            u64(normalized.bitPattern)
        case .string(let value): u8(5); string(value)
        case .array(let values):
            u8(6); u64(UInt64(values.count))
            for value in values { json(value) }
        case .object(let object):
            u8(7)
            let normalized = object.map { ($0.key.precomposedStringWithCanonicalMapping, $0.value) }
                .sorted { Data($0.0.utf8).lexicographicallyPrecedes(Data($1.0.utf8)) }
            guard Set(normalized.map(\.0)).count == normalized.count else {
                error = .duplicateNormalizedKey; return
            }
            u64(UInt64(normalized.count))
            for (key, value) in normalized { string(key); json(value) }
        }
    }
    mutating func finish() throws -> Data {
        if let error { throw error }
        return data
    }
    private mutating func fixed<T>(_ value: T) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
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
