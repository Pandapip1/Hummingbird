import Foundation
import PlatformSupport
import os
import Synchronization

/// The synced data cache for one profile: plugin results kept so a refresh
/// on one device serves the others, without the data journal's guarantees.
///
/// - Lossy by design: writes are appended without fsync, a damaged frame is
///   dropped alone, and a store that went missing simply refills, from
///   peers first, then plugins. It lives in a `KeptDirectory`, never Caches.
/// - Normalised: an entity is stored once per fetch context, lists hold
///   references, and large fields are content-addressed blobs (keyed IDs).
/// - Confidential: every frame is sealed with the current key epoch, shared
///   only by the profile's trusted devices; leaving the trusted set rotates
///   the epoch, and records are re-keyed in place (`migrate`).
/// - Divergence-aware: entries carry their fetch context; a device only uses
///   what its own context allows, and a peer's entry never replaces its own
///   fetch.
public final class CacheJournal: Sendable {
    public struct Configuration: Sendable {
        /// Bytes the cache may hold before least-recently-used records go.
        public var budget: Int
        /// How long an entity serves before it is due for a refetch.
        public var entityLifetime: TimeInterval
        /// How long a list serves before it is due for a refetch.
        public var listLifetime: TimeInterval
        /// How long an epoch lasts before it turns over anyway.
        public var epochLifetime: TimeInterval

        public init(budget: Int = 256 * 1_024 * 1_024, entityLifetime: TimeInterval = 30 * 86_400,
                    listLifetime: TimeInterval = 7 * 86_400, epochLifetime: TimeInterval = 30 * 86_400) {
            self.budget = budget
            self.entityLifetime = entityLifetime
            self.listLifetime = listLifetime
            self.epochLifetime = epochLifetime
        }
    }

    public struct Usage: Sendable, Equatable {
        public var bytes: Int
        public var entities: Int
        public var lists: Int
        public var blobs: Int
    }

    public enum CacheError: Error, Equatable {
        /// Sent under another key epoch: refused.
        case epochMismatch
        /// There are no keys yet (the credential store couldn't be read).
        case unavailable
    }

    let profileID: UUID
    private let directory: URL
    private let instance: AppSyncPeerID
    private let epochs: CacheEpochStore
    private let availability: any ProtectedDataAvailability
    private let state: Mutex<State>
    static let log = Logger(subsystem: AppSyncDiagnostics.subsystem, category: "appsync.cache")

    struct State: Sendable {
        var configuration: Configuration
        /// Current epoch first, then older ones still being re-keyed.
        var partitions: [CachePartition] = []
        var members: Set<AppSyncPeerID> = []
    }

    /// Opens the profile's cache in `directory`, with
    /// keys from `credentialStore`. `instance` is this device. Nothing here
    /// throws: a missing store starts empty, damaged frames are
    /// skipped.
    /// `directory` is a `KeptDirectory`: inside the app's data, excluded from
    /// backups, never Caches (which the system empties when storage runs low;
    /// losing the cache is expensive). The type keeps a Caches URL out.
    public init(directory kept: KeptDirectory, profileID: UUID, instance: AppSyncPeerID,
                credentialStore: any AppSyncCredentialStore,
                availability: any ProtectedDataAvailability, configuration: Configuration = .init()) {
        let directory = kept.url
        self.directory = directory
        self.profileID = profileID
        self.instance = instance
        self.availability = availability
        epochs = CacheEpochStore(credentialStore: credentialStore, profileID: profileID)
        var state = State(configuration: configuration, members: [instance])
        do {
            let loaded = try epochs.load()
            let current: CacheEpoch
            if let existing = loaded.current {
                current = existing
            } else {
                current = CacheEpoch.generate(number: 1, members: [instance], now: Date())
                try epochs.save(current: current, retired: [])
            }
            state.members = current.members
            state.partitions = ([current] + loaded.retired).map { Self.load($0, directory: directory, profileID: profileID) }
            Self.removeFiles(in: directory, except: Set(state.partitions.map { Self.fileName($0.epoch.id) }))
        } catch {
            // No keys this session (the credential store is locked or
            // failing): the cache stays empty and writes are dropped.
            Self.log.error("cache_keys_unavailable error=\(String(describing: error), privacy: .public)")
        }
        self.state = Mutex(state)
    }

    // MARK: reading

    /// The best value of `key` for `viewer`: one fetched in exactly the
    /// viewer's context, else a placeholder from a compatible one. Nil when
    /// none is visible here (another account, a setting this profile isn't
    /// allowed) or it has expired.
    public func entity(_ key: CacheEntityKey, for viewer: CacheViewer, now: Date = Date()) -> CachedEntity? {
        state.withLock { state in
            guard let found = Self.best(key, viewer: viewer, state: state, now: now) else { return nil }
            state.partitions[found.index].entities[found.slot]?.lastUsed = now
            return Self.read(found.slot, in: state.partitions[found.index], fit: found.fit)
        }
    }

    /// A list for `viewer`, its entities resolved in the list's own context
    /// where possible. `isPartial` when some are gone or not visible here.
    public func list(_ key: CacheListKey, for viewer: CacheViewer, now: Date = Date()) -> CachedList? {
        state.withLock { state in
            var best: (index: Int, slot: CacheListSlot, fit: CacheFit, record: CacheListRecord)?
            for (index, partition) in state.partitions.enumerated() {
                for (slot, record) in partition.lists where slot.key == key {
                    guard now.timeIntervalSince(record.fetchedAt) < state.configuration.listLifetime,
                          let fit = viewer.match(record.stored(in: partition.epoch), source: key.source,
                                                 epoch: partition.epoch) else { continue }
                    if let current = best, !Self.prefer(record, fit: fit, over: current.record, fit: current.fit) { continue }
                    best = (index, slot, fit, record)
                }
            }
            guard let best else { return nil }
            state.partitions[best.index].lists[best.slot]?.lastUsed = now
            var entities: [CachedEntity] = []
            var missing = false
            for reference in best.record.references {
                let own = CacheSlot(key: reference, context: best.slot.context)
                if let entity = Self.read(own, in: state.partitions[best.index], fit: best.fit) {
                    entities.append(entity)
                } else if let found = Self.best(reference, viewer: viewer, state: state, now: now),
                          let entity = Self.read(found.slot, in: state.partitions[found.index], fit: min(found.fit, best.fit)) {
                    entities.append(entity)
                } else {
                    missing = true
                }
            }
            return CachedList(key: key, entities: entities, isPartial: missing,
                              fetchedAt: best.record.fetchedAt, fit: best.fit)
        }
    }

    private static func best(_ key: CacheEntityKey, viewer: CacheViewer, state: State,
                             now: Date) -> (index: Int, slot: CacheSlot, fit: CacheFit)? {
        var best: (index: Int, slot: CacheSlot, fit: CacheFit, record: CacheEntityRecord)?
        for (index, partition) in state.partitions.enumerated() {
            for (slot, record) in partition.entities where slot.key == key {
                guard now.timeIntervalSince(record.fetchedAt) < state.configuration.entityLifetime,
                      let fit = viewer.match(record.stored(in: partition.epoch), source: key.source,
                                             epoch: partition.epoch) else { continue }
                if let current = best, !prefer(record, fit: fit, over: current.record, fit: current.fit) { continue }
                best = (index, slot, fit, record)
            }
        }
        return best.map { ($0.index, $0.slot, $0.fit) }
    }

    /// Exact context first; then this device's own fetch; then the value
    /// taken in first, so a later variant never makes what's shown flap.
    private static func prefer(_ candidate: some CacheRecordOrdering, fit: CacheFit,
                               over current: some CacheRecordOrdering, fit currentFit: CacheFit) -> Bool {
        if fit != currentFit { return fit > currentFit }
        if candidate.origin != current.origin { return candidate.origin == .local }
        if candidate.origin == .local { return candidate.fetchedAt > current.fetchedAt }
        return candidate.storedAt < current.storedAt
    }

    private static func read(_ slot: CacheSlot, in partition: CachePartition, fit: CacheFit) -> CachedEntity? {
        guard let record = partition.entities[slot] else { return nil }
        var fields: [String: Data] = [:]
        for (name, id) in record.fields {
            guard let content = partition.blobs[id] else { return nil }
            fields[name] = content
        }
        return CachedEntity(key: record.key, payload: record.payload, fields: fields,
                            fetchedAt: record.fetchedAt, fit: fit)
    }

    // MARK: writing

    /// An entity this device fetched. Replaces only this device's earlier
    /// value in the same context, or a peer's.
    public func put(_ key: CacheEntityKey, context: CacheFetchContext, payload: Data,
                    fields: [String: Data] = [:], fetchedAt: Date = Date()) {
        state.withLock { state in
            guard !state.partitions.isEmpty else { return }
            Self.putEntity(key, context: context, payload: payload, fields: fields, fetchedAt: fetchedAt,
                           state: &state)
            Self.evictUnlocked(toBytes: state.configuration.budget, limit: .max, state: &state)
        }
    }

    /// A list this device fetched, with its entities: each entity is stored
    /// once, the list holds references to them.
    public func put(_ key: CacheListKey, context: CacheFetchContext,
                    entities: [(key: CacheEntityKey, payload: Data, fields: [String: Data])],
                    fetchedAt: Date = Date()) {
        state.withLock { state in
            guard !state.partitions.isEmpty else { return }
            for entity in entities {
                Self.putEntity(entity.key, context: context, payload: entity.payload, fields: entity.fields,
                               fetchedAt: fetchedAt, state: &state)
            }
            let record = CacheListRecord(key: key, context: context, accountHash: nil,
                                         references: entities.map(\.key), fetchedAt: fetchedAt,
                                         origin: .local, storedAt: Date())
            // The same list kept from an older epoch is superseded.
            for index in state.partitions.indices.dropFirst() {
                let stale = state.partitions[index].lists.filter {
                    $0.key.key == key && $0.value.origin == .local && $0.value.context == context
                }
                for slot in stale.keys { state.partitions[index].removeList(slot) }
            }
            state.partitions[0].insert(record)
            Self.evictUnlocked(toBytes: state.configuration.budget, limit: .max, state: &state)
        }
    }

    private static func putEntity(_ key: CacheEntityKey, context: CacheFetchContext, payload: Data,
                                  fields: [String: Data], fetchedAt: Date, state: inout State) {
        var ids: [String: CacheBlobID] = [:]
        for (name, content) in fields { ids[name] = state.partitions[0].addBlob(content) }
        let record = CacheEntityRecord(key: key, context: context, accountHash: nil, payload: payload,
                                       fields: ids, fetchedAt: fetchedAt, origin: .local, storedAt: Date())
        // This device's own value from an older epoch is superseded.
        for index in state.partitions.indices.dropFirst() {
            let stale = state.partitions[index].entities.filter {
                $0.key.key == key && $0.value.origin == .local && $0.value.context == context
            }
            for slot in stale.keys { state.partitions[index].removeEntity(slot) }
        }
        state.partitions[0].insert(record)
    }

    // MARK: size

    public var usage: Usage {
        state.withLock { state in
            Usage(bytes: state.partitions.reduce(0) { $0 + $1.bytes },
                  entities: state.partitions.reduce(0) { $0 + $1.entities.count },
                  lists: state.partitions.reduce(0) { $0 + $1.lists.count },
                  blobs: state.partitions.reduce(0) { $0 + $1.blobs.count })
        }
    }

    /// Changes the budget; anything over it goes, least recently used first.
    public func setBudget(_ bytes: Int) {
        state.withLock { state in
            state.configuration.budget = bytes
            Self.evictUnlocked(toBytes: bytes, limit: .max, state: &state)
        }
    }

    /// Removes at most `limit` least-recently-used records while the cache
    /// is over `bytes`: incremental, for low disk space. A list whose
    /// entities went reads as partial; blobs go with their last entity.
    @discardableResult
    public func evict(toBytes bytes: Int, limit: Int) -> Int {
        state.withLock { Self.evictUnlocked(toBytes: bytes, limit: limit, state: &$0) }
    }

    @discardableResult
    private static func evictUnlocked(toBytes target: Int, limit: Int, state: inout State) -> Int {
        var total = state.partitions.reduce(0) { $0 + $1.bytes }
        guard total > target, limit > 0 else { return 0 }
        enum Victim { case entity(Int, CacheSlot), list(Int, CacheListSlot) }
        var candidates: [(Date, Victim)] = []
        for (index, partition) in state.partitions.enumerated() {
            candidates += partition.entities.map { ($0.value.lastUsed, .entity(index, $0.key)) }
            candidates += partition.lists.map { ($0.value.lastUsed, .list(index, $0.key)) }
        }
        candidates.sort { $0.0 < $1.0 }
        var removed = 0
        for (_, victim) in candidates where total > target && removed < limit {
            let before: Int
            switch victim {
            case .entity(let index, let slot):
                before = state.partitions[index].bytes
                state.partitions[index].removeEntity(slot)
                total -= before - state.partitions[index].bytes
            case .list(let index, let slot):
                before = state.partitions[index].bytes
                state.partitions[index].removeList(slot)
                total -= before - state.partitions[index].bytes
            }
            removed += 1
        }
        return removed
    }

    // MARK: persistence

    /// Appends what changed to the partition files; compacts a file that is
    /// mostly superseded frames. Every write is atomic (AtomicFile,
    /// AppendLog): a failure, a full disk included, costs only what was being
    /// written, never what was persisted before; it stays pending and is
    /// tried again. Skipped while protected data is unavailable.
    public func persist() {
        guard availability.isProtectedDataAvailable else { return }
        state.withLock { state in
            for index in state.partitions.indices {
                Self.write(&state.partitions[index], directory: directory, profileID: profileID,
                             availability: availability)
            }
        }
    }

    private static func write(_ partition: inout CachePartition, directory: URL, profileID: UUID,
                                availability: any ProtectedDataAvailability) {
        let url = directory.appendingPathComponent(fileName(partition.epoch.id))
        let live = partition.entities.count + partition.lists.count + partition.blobs.count
        let compact = !partition.unreadable && partition.garbage > 256 && partition.garbage > live
        guard compact || !partition.pending.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A missing file (removed meanwhile) is written whole.
            let rewrite = compact || (!partition.unreadable && !FileManager.default.fileExists(atPath: url.path))
            let frames = rewrite ? partition.snapshotFrames : partition.pending
            var data = Data()
            for frame in frames {
                data.append(try CacheFrameFile.encode(frame, epoch: partition.epoch, profileID: profileID))
            }
            if rewrite {
                try AtomicFile.write(data, to: url, protection: .completeUntilFirstUserAuthentication)
                // Background windows read and refill it while the device is locked;
                // every frame is sealed, which is what keeps it private.
                try availability.setProtection(.completeUntilFirstUserAuthentication, for: url)
                partition.garbage = 0
            } else {
                // Lands whole or is cut back off: a full disk never leaves
                // half a frame for the next append to follow.
                try AppendLog(url: url).append(data)
            }
            partition.pending = []
        } catch {
            log.error("cache_persist_failed error=\(String(describing: error), privacy: .public)")
        }
    }

    private static func load(_ epoch: CacheEpoch, directory: URL, profileID: UUID) -> CachePartition {
        var partition = CachePartition(epoch: epoch)
        let url = directory.appendingPathComponent(fileName(epoch.id))
        // Missing (never written, or removed): start empty. There but
        // unreadable: start empty too, but never write over it.
        let data: Data
        do {
            guard let contents = try AtomicFile.contents(of: url) else { return partition }
            data = contents
        } catch {
            log.error("cache_partition_unreadable error=\(String(describing: error), privacy: .public)")
            partition.unreadable = true
            return partition
        }
        let (frames, damaged) = CacheFrameFile.decode(data, epoch: epoch, profileID: profileID)
        for frame in frames { partition.replay(frame) }
        let dropped = partition.restoreIntegrity()
        if damaged > 0 || dropped > 0 {
            log.notice("cache_salvaged damaged_frames=\(damaged) dropped_entities=\(dropped)")
            // Rewrite without the damage next time it is persisted.
            partition.garbage = 1 << 30
        }
        return partition
    }

    static func fileName(_ epoch: CacheEpochID) -> String {
        "cache-\(epoch.number)-\(epoch.id.uuidString.lowercased()).frames"
    }

    private static func removeFiles(in directory: URL, except kept: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("cache-") && !kept.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: clearing

    /// Clears this device's cache, and only this device's (nothing is sent
    /// to peers): erases every key epoch (crypto-erase: no copy of the old
    /// files can be read again), deletes the files, and starts a new epoch.
    public func clear() throws {
        try state.withLock { state in
            try epochs.erase()
            for partition in state.partitions {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(Self.fileName(partition.epoch.id))
                )
            }
            let number = (state.partitions.map(\.epoch.id.number).max() ?? 0) + 1
            let epoch = CacheEpoch.generate(number: number, members: state.members, now: Date())
            try epochs.save(current: epoch, retired: [])
            state.partitions = [CachePartition(epoch: epoch)]
        }
    }

    // MARK: epochs

    /// The current epoch.
    public var epoch: CacheEpochID? { state.withLock { $0.partitions.first?.epoch.id } }

    /// Follows the trusted set. A device that left it (revoked, removed)
    /// makes this device move to a new epoch, as does age; a device that
    /// joined is added to the current one (it gets the keys at its next
    /// sync). Records move to a new epoch by `migrate`, never by refetching.
    public func follow(trusted: Set<AppSyncPeerID>, now: Date = Date()) throws {
        try state.withLock { state in
            guard let current = state.partitions.first?.epoch else { throw CacheError.unavailable }
            let members = trusted.union([instance])
            let left = !current.members.isSubset(of: members)
            let old = now.timeIntervalSince(current.createdAt) >= state.configuration.epochLifetime
            if left || old {
                let next = CacheEpoch.generate(number: current.id.number + 1, members: members, now: now)
                try adopt(next, state: &state)
                Self.log.notice("cache_epoch_rotated reason=\(left ? "membership" : "age", privacy: .public)")
            } else if members != current.members {
                var extended = current
                extended.members = members
                state.partitions[0].epoch = extended
                try epochs.save(current: extended, retired: state.partitions.dropFirst().map(\.epoch))
            }
            state.members = members
        }
    }

    /// The current epoch's keys, for a member that lacks them. Only ever
    /// sent sealed to that member.
    func offer(to peer: AppSyncPeerID) -> CacheEpochOffer? {
        state.withLock { state in
            guard let epoch = state.partitions.first?.epoch, epoch.members.contains(peer) else { return nil }
            return epoch.offer
        }
    }

    /// Takes a peer's epoch if it wins (higher number, then ID), was made
    /// for this device, and names no device this one doesn't trust. True
    /// when adopted; the old epoch's records are re-keyed by `migrate`.
    func consider(_ offer: CacheEpochOffer, trusted: Set<AppSyncPeerID>) throws -> Bool {
        try state.withLock { state in
            guard let current = state.partitions.first?.epoch, offer.id > current.id,
                  offer.members.contains(instance),
                  offer.members.isSubset(of: trusted.union([instance])) else { return false }
            try adopt(CacheEpoch(offer), state: &state)
            Self.log.notice("cache_epoch_adopted")
            return true
        }
    }

    private func adopt(_ epoch: CacheEpoch, state: inout State) throws {
        let retired = state.partitions.map(\.epoch)
        try epochs.save(current: epoch, retired: retired)
        state.partitions.insert(CachePartition(epoch: epoch), at: 0)
    }

    /// Whether records from an older epoch are still to be re-keyed.
    public var needsMigration: Bool { state.withLock { $0.partitions.count > 1 } }

    /// Re-keys up to `limit` records from older epochs into the current
    /// one: blob IDs recomputed with the new key, account hashes recomputed
    /// from `accounts` (the accounts this device knows), sealed with the
    /// new key. Nothing is refetched. When an old epoch's last record has
    /// moved, its file and keys are erased. Returns how many remain.
    /// A peer's signed-in record for an account this device doesn't know
    /// can't be re-hashed; it is invisible here anyway, and is dropped.
    @discardableResult
    public func migrate(limit: Int, accounts: [String]) -> Int {
        state.withLock { state in
            guard state.partitions.count > 1 else { return 0 }
            var moved = 0
            while moved < limit, state.partitions.count > 1 {
                let source = state.partitions.count - 1
                let old = state.partitions[source].epoch
                let raw = Dictionary(accounts.map { (old.accountHash($0), $0) }, uniquingKeysWith: { a, _ in a })
                if let (slot, record) = state.partitions[source].entities.first {
                    var copy = record
                    if let hash = record.accountHash { copy.context.account = raw[hash]; copy.accountHash = nil }
                    if record.accountHash == nil || copy.context.account != nil {
                        var ids: [String: CacheBlobID] = [:]
                        var complete = true
                        for (name, id) in record.fields {
                            guard let content = state.partitions[source].blobs[id] else { complete = false; break }
                            ids[name] = state.partitions[0].addBlob(content)
                        }
                        copy.fields = ids
                        let target = state.partitions[0].slot(copy)
                        let existing = state.partitions[0].entities[target]
                        // This device's own fetch beats a peer's either way.
                        if complete, existing == nil || (existing?.origin == .remote && copy.origin == .local) {
                            state.partitions[0].insert(copy)
                        }
                    }
                    state.partitions[source].removeEntity(slot)
                    moved += 1
                } else if let (slot, record) = state.partitions[source].lists.first {
                    var copy = record
                    if let hash = record.accountHash { copy.context.account = raw[hash]; copy.accountHash = nil }
                    if record.accountHash == nil || copy.context.account != nil {
                        let target = state.partitions[0].slot(copy)
                        let existing = state.partitions[0].lists[target]
                        if existing == nil || (existing?.origin == .remote && copy.origin == .local) {
                            state.partitions[0].insert(copy)
                        }
                    }
                    state.partitions[source].removeList(slot)
                    moved += 1
                } else {
                    // Emptied: erase the old epoch's file and keys.
                    let retired = state.partitions.remove(at: source)
                    try? FileManager.default.removeItem(
                        at: directory.appendingPathComponent(Self.fileName(retired.epoch.id))
                    )
                    do {
                        try epochs.save(current: state.partitions[0].epoch,
                                        retired: state.partitions.dropFirst().map(\.epoch))
                    } catch {
                        Self.log.error("cache_epoch_erase_failed error=\(String(describing: error), privacy: .public)")
                    }
                }
            }
            return state.partitions.dropFirst().reduce(0) { $0 + $1.entities.count + $1.lists.count }
        }
    }

    // MARK: sync

    /// What this device can share: the current epoch's records only.
    func manifest() -> CacheManifest? {
        state.withLock { state in
            guard let partition = state.partitions.first else { return nil }
            let epoch = partition.epoch
            return CacheManifest(
                epoch: epoch.id,
                entities: partition.entities.values.map {
                    .init(key: $0.key, context: $0.stored(in: epoch), fetchedAt: $0.fetchedAt)
                },
                lists: partition.lists.values.map {
                    .init(key: $0.key, context: $0.stored(in: epoch), fetchedAt: $0.fetchedAt)
                }
            )
        }
    }

    /// What this device lacks of a peer's manifest. Nothing this device
    /// fetched itself is asked for, nor a peer's value it already holds
    /// (unless expired): no flapping between variants.
    func want(from manifest: CacheManifest, now: Date = Date()) throws -> CacheWant {
        try state.withLock { state in
            guard let partition = state.partitions.first else { throw CacheError.unavailable }
            guard manifest.epoch == partition.epoch.id else { throw CacheError.epochMismatch }
            let lifetime = state.configuration
            var want = CacheWant(epoch: manifest.epoch, entities: [], lists: [])
            for entry in manifest.entities {
                let slot = CacheSlot(key: entry.key, context: entry.context.contextClass)
                if let existing = partition.entities[slot],
                   existing.origin == .local || now.timeIntervalSince(existing.fetchedAt) < lifetime.entityLifetime
                    || existing.fetchedAt >= entry.fetchedAt { continue }
                if Self.heldInOlderEpoch(entry.key, state: state) { continue }
                want.entities.append(slot)
            }
            for entry in manifest.lists {
                let slot = CacheListSlot(key: entry.key, context: entry.context.contextClass)
                if let existing = partition.lists[slot],
                   existing.origin == .local || now.timeIntervalSince(existing.fetchedAt) < lifetime.listLifetime
                    || existing.fetchedAt >= entry.fetchedAt { continue }
                want.lists.append(slot)
            }
            return want
        }
    }

    private static func heldInOlderEpoch(_ key: CacheEntityKey, state: State) -> Bool {
        state.partitions.dropFirst().contains { $0.entities.values.contains { $0.key == key && $0.origin == .local } }
    }

    /// The records a peer asked for, each blob once.
    func transfer(for want: CacheWant) throws -> CacheTransfer {
        try state.withLock { state in
            guard let partition = state.partitions.first else { throw CacheError.unavailable }
            guard want.epoch == partition.epoch.id else { throw CacheError.epochMismatch }
            var transfer = CacheTransfer(epoch: want.epoch, entities: [], lists: [], blobs: [])
            var blobIndex: [CacheBlobID: Int] = [:]
            for slot in want.entities {
                guard let record = partition.entities[slot] else { continue }
                var fields: [String: Int] = [:]
                for (name, id) in record.fields {
                    guard let content = partition.blobs[id] else { continue }
                    if let index = blobIndex[id] {
                        fields[name] = index
                    } else {
                        blobIndex[id] = transfer.blobs.count
                        fields[name] = transfer.blobs.count
                        transfer.blobs.append(content)
                    }
                }
                transfer.entities.append(.init(key: record.key, context: record.stored(in: partition.epoch),
                                               payload: record.payload, fields: fields, fetchedAt: record.fetchedAt))
            }
            for slot in want.lists {
                guard let record = partition.lists[slot] else { continue }
                transfer.lists.append(.init(key: record.key, context: record.stored(in: partition.epoch),
                                            references: record.references, fetchedAt: record.fetchedAt))
            }
            return transfer
        }
    }

    /// Takes in a peer's records. Refused unless in the current epoch. A
    /// record never replaces this device's own fetch, nor a peer's value it
    /// already holds that hasn't expired. Returns how many were taken.
    @discardableResult
    func apply(_ transfer: CacheTransfer, accounts: [String] = [], now: Date = Date()) throws -> Int {
        try state.withLock { state in
            guard let epoch = state.partitions.first?.epoch else { throw CacheError.unavailable }
            guard transfer.epoch == epoch.id else { throw CacheError.epochMismatch }
            let raw = Dictionary(accounts.map { (epoch.accountHash($0), $0) }, uniquingKeysWith: { a, _ in a })
            var taken = 0
            for entity in transfer.entities {
                let slot = CacheSlot(key: entity.key, context: entity.context.contextClass)
                if let existing = state.partitions[0].entities[slot],
                   existing.origin == .local
                    || now.timeIntervalSince(existing.fetchedAt) < state.configuration.entityLifetime { continue }
                var ids: [String: CacheBlobID] = [:]
                var complete = true
                for (name, index) in entity.fields {
                    guard transfer.blobs.indices.contains(index) else { complete = false; break }
                    ids[name] = state.partitions[0].addBlob(transfer.blobs[index])
                }
                guard complete else { continue }
                let (context, accountHash) = Self.context(entity.context, raw: raw)
                state.partitions[0].insert(CacheEntityRecord(
                    key: entity.key, context: context, accountHash: accountHash, payload: entity.payload,
                    fields: ids, fetchedAt: entity.fetchedAt, origin: .remote, storedAt: now
                ))
                taken += 1
            }
            for list in transfer.lists {
                let slot = CacheListSlot(key: list.key, context: list.context.contextClass)
                if let existing = state.partitions[0].lists[slot],
                   existing.origin == .local
                    || now.timeIntervalSince(existing.fetchedAt) < state.configuration.listLifetime { continue }
                let (context, accountHash) = Self.context(list.context, raw: raw)
                state.partitions[0].insert(CacheListRecord(
                    key: list.key, context: context, accountHash: accountHash, references: list.references,
                    fetchedAt: list.fetchedAt, origin: .remote, storedAt: now
                ))
                taken += 1
            }
            Self.evictUnlocked(toBytes: state.configuration.budget, limit: .max, state: &state)
            return taken
        }
    }

    private static func context(_ stored: StoredContext, raw: [String: String]) -> (CacheFetchContext, String?) {
        let account = stored.accountHash.flatMap { raw[$0] }
        let context = CacheFetchContext(sourceVersion: stored.sourceVersion, settings: stored.settings,
                                        account: account, locale: stored.locale, elevation: stored.elevation)
        return (context, account == nil ? stored.accountHash : nil)
    }

    // MARK: testing

    /// Blob IDs in the current epoch, for tests.
    var blobIDs: Set<CacheBlobID> { state.withLock { Set($0.partitions.flatMap { $0.blobs.keys }) } }

    /// Every blob ID referenced by an entity that the store doesn't hold,
    /// and every held blob nothing references: both empty when consistent.
    var integrityViolations: (dangling: Int, orphaned: Int) {
        state.withLock { state in
            var dangling = 0, orphaned = 0
            for partition in state.partitions {
                var used = Set<CacheBlobID>()
                for record in partition.entities.values {
                    for id in record.fields.values {
                        used.insert(id)
                        if partition.blobs[id] == nil { dangling += 1 }
                    }
                }
                orphaned += partition.blobs.keys.filter { !used.contains($0) }.count
            }
            return (dangling, orphaned)
        }
    }

    var currentEpochForTesting: CacheEpoch? { state.withLock { $0.partitions.first?.epoch } }
    var directoryForTesting: URL { directory }
    var epochStoreForTesting: CacheEpochStore { epochs }
}

/// What `prefer` compares.
protocol CacheRecordOrdering {
    var origin: CacheOrigin { get }
    var fetchedAt: Date { get }
    var storedAt: Date { get }
}

extension CacheEntityRecord: CacheRecordOrdering {}
extension CacheListRecord: CacheRecordOrdering {}
