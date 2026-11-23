import ATProtoKit
import ATAppSync
import Crypto
import Foundation

enum HummingbirdProfileSchema {
    static let appID = AppSyncAppID(rawValue: "com.eightybps.hummingbird")!
    static let spaceType = NSID(rawValue: "com.eightybps.hummingbird.profile")!
    static let spaceKey = RecordKey(rawValue: "self")!
    static let subscription = NSID(rawValue: "com.eightybps.hummingbird.subscription")!
    static let playlist = NSID(rawValue: "com.eightybps.hummingbird.playlist")!
    static let watchLater = NSID(rawValue: "com.eightybps.hummingbird.watchLater")!
    static let history = NSID(rawValue: "com.eightybps.hummingbird.history")!
    static let plugin = NSID(rawValue: "com.eightybps.hummingbird.plugin")!
    /// Playback history only grows. Every device keeps the same most recently
    /// watched records of it in the journal, as many as the library shows,
    /// ranked by when they were watched; `LibraryStore` keeps its copy the
    /// same way (see `historyRank`).
    static let retention: [NSID: JournalRetention] = [
        history: JournalRetention(limit: LibraryStore.historyLimit) { historyRank($0.value) },
    ]

    /// A history record's rank: its `date`, as `HistoryEntry` encodes it
    /// (seconds since the reference date). Read without decoding the entry,
    /// since retention ranks every record of the collection.
    static func historyRank(_ value: JSONValue?) -> Double? {
        guard case .object(let fields)? = value else { return nil }
        switch fields["date"] {
        case .double(let seconds)?: return seconds
        case .integer(let seconds)?: return Double(seconds)
        default: return nil
        }
    }

    /// The same rank for an entry this device holds.
    static func historyRank(_ entry: HistoryEntry) -> RetentionFloor {
        RetentionFloor(rank: entry.date.timeIntervalSinceReferenceDate,
                       path: history.rawValue + "/" + key(for: entry.id).rawValue)
    }
    static let parentalApproval = NSID(rawValue: "com.eightybps.hummingbird.parentalApproval")!
    static let ageRange = NSID(rawValue: "com.eightybps.hummingbird.ageRange")!
    /// Single-record collections (one per profile) use this key.
    static let singletonKey = RecordKey(rawValue: "self")!

    static func key(for stableIdentity: String) -> RecordKey {
        let digest = SHA256.hash(data: Data(stableIdentity.utf8))
        return RecordKey(rawValue: digest.map { String(format: "%02x", $0) }.joined())!
    }
}

/// The only plugin representation that can cross the synchronization boundary.
/// Executable code is re-fetched and re-verified from sourceURL. SourceAuth,
/// captcha cookies, headers, and tokens cannot be represented here.
struct SyncedPlugin: Codable, Hashable, Sendable {
    let pluginID: String
    let sourceURL: String
    let enabled: Bool
    let settings: [String: String]

    init?(_ plugin: InstalledPlugin) {
        guard let sourceURL = plugin.config.sourceUrl, !sourceURL.isEmpty else { return nil }
        pluginID = plugin.id
        self.sourceURL = sourceURL
        enabled = plugin.enabled
        settings = plugin.settings
    }
}

/// A watch-later item plus its user-visible list position. Reordering records
/// every affected register, so peers converge on both membership and order.
struct SyncedWatchLater: Codable, Hashable, Sendable {
    let video: SavedVideo
    let position: Int

    var id: String { video.id }
}

struct ProfileRecordEnvelope<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    let payload: Value
    let modified: HybridLogicalTimestamp
}

enum ProfileEntity: Hashable, Sendable {
    case subscription(Subscription)
    case playlist(Playlist)
    case watchLater(SyncedWatchLater)
    case history(HistoryEntry)
    case plugin(SyncedPlugin)
    case parentalApproval(SyncedParentalApproval)
    case ageRange(SyncedAgeRange)

    /// The collections `LibraryStore` holds.
    static let libraryCollections: Set<NSID> = [
        HummingbirdProfileSchema.subscription, HummingbirdProfileSchema.playlist,
        HummingbirdProfileSchema.watchLater, HummingbirdProfileSchema.history,
    ]

    var collection: NSID {
        switch self {
        case .subscription: HummingbirdProfileSchema.subscription
        case .playlist: HummingbirdProfileSchema.playlist
        case .watchLater: HummingbirdProfileSchema.watchLater
        case .history: HummingbirdProfileSchema.history
        case .plugin: HummingbirdProfileSchema.plugin
        case .parentalApproval: HummingbirdProfileSchema.parentalApproval
        case .ageRange: HummingbirdProfileSchema.ageRange
        }
    }

    var recordKey: RecordKey {
        switch self {
        case .subscription(let value): HummingbirdProfileSchema.key(for: value.channelURL)
        case .playlist(let value): RecordKey(rawValue: value.id.uuidString.lowercased())!
        case .watchLater(let value): HummingbirdProfileSchema.key(for: value.id)
        case .history(let value): HummingbirdProfileSchema.key(for: value.id)
        case .plugin(let value): HummingbirdProfileSchema.key(for: value.pluginID)
        case .parentalApproval(let value): HummingbirdProfileSchema.key(for: value.pluginID)
        case .ageRange: HummingbirdProfileSchema.singletonKey
        }
    }

    func json() throws -> JSONValue {
        switch self {
        case .subscription(let value): return try .encoding(value)
        case .playlist(let value): return try .encoding(value)
        case .watchLater(let value): return try .encoding(value)
        case .history(let value): return try .encoding(value)
        case .plugin(let value): return try .encoding(value)
        case .parentalApproval(let value): return try .encoding(value)
        case .ageRange(let value): return try .encoding(value)
        }
    }

    static func decode(collection: NSID, payload: JSONValue) throws -> Self? {
        if collection == HummingbirdProfileSchema.subscription {
            return .subscription(try payload.decode(Subscription.self))
        } else if collection == HummingbirdProfileSchema.playlist {
            return .playlist(try payload.decode(Playlist.self))
        } else if collection == HummingbirdProfileSchema.watchLater {
            return .watchLater(try payload.decode(SyncedWatchLater.self))
        } else if collection == HummingbirdProfileSchema.history {
            return .history(try payload.decode(HistoryEntry.self))
        } else if collection == HummingbirdProfileSchema.plugin {
            return .plugin(try payload.decode(SyncedPlugin.self))
        } else if collection == HummingbirdProfileSchema.parentalApproval {
            return .parentalApproval(try payload.decode(SyncedParentalApproval.self))
        } else if collection == HummingbirdProfileSchema.ageRange {
            return .ageRange(try payload.decode(SyncedAgeRange.self))
        }
        return nil
    }
}

/// Mutation boundary used by local stores. Each edit is appended to the
/// journal in submission order on a background queue, because every append
/// rewrites the journal file: an edit made on the main actor never waits for
/// that. Connectivity is irrelevant; `flush()` waits for queued appends.
final class ProfileChangeStore: @unchecked Sendable {
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "com.eightybps.hummingbird.profile-changes", qos: .utility)
    private let storageDirectory: URL?
    private var active: AppSyncMutationLog?
    private var activeProfileID: UUID?
    private var storedError: (any Error)?
    private var mutationHandler: (@Sendable () -> Void)?
    private let signer: AppSyncMutationSigner?

    /// Creates the local profile change store. A profile is activated during app
    /// startup and remains active whether or not it has any synchronization target.
    init(storageDirectory: URL, signer: AppSyncMutationSigner? = nil) {
        self.storageDirectory = storageDirectory
        self.signer = signer
    }

    /// Creates an already-active change store, primarily for isolated tests.
    init(mutationLog: AppSyncMutationLog) {
        storageDirectory = nil
        signer = nil
        active = mutationLog
    }

    var lastError: (any Error)? { lock.withLock { storedError } }
    var mutationLog: AppSyncMutationLog? { lock.withLock { active } }

    func activate(localProfileID: UUID) throws -> AppSyncMutationLog {
        if let mutationLog = lock.withLock({ activeProfileID == localProfileID ? active : nil }) {
            return mutationLog
        }
        guard let storageDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        let created = try AppSyncMutationLog(
            fileURL: storageDirectory.appendingPathComponent(
                "\(localProfileID.uuidString.lowercased()).json"
            ), signer: signer, retention: HummingbirdProfileSchema.retention
        )
        lock.withLock {
            active = created
            activeProfileID = localProfileID
            storedError = nil
        }
        return created
    }

    func deactivate() {
        lock.withLock {
            active = nil
            activeProfileID = nil
        }
    }

    func setMutationHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { mutationHandler = handler }
    }

    func put(_ entity: ProfileEntity) {
        writer.async { [self] in
            record { mutationLog in
                try mutationLog.appendPut(collection: entity.collection, key: entity.recordKey, value: entity.json())
            }
        }
    }

    func delete(collection: NSID, key: RecordKey) {
        writer.async { [self] in
            record { mutationLog in try mutationLog.appendDelete(collection: collection, key: key) }
        }
    }

    /// Introduces existing local state to the journal: every entity the
    /// journal has no version for (put or delete) is appended, in one
    /// durable write. Entities created before sync was active, or while the
    /// journal already held other devices' records, are therefore never left
    /// out; anything the journal already knows is left to the journal. The
    /// check runs in order with queued edits, so it sees every edit
    /// submitted before it.
    func bootstrap(_ entities: [ProfileEntity]) {
        writer.async { [self] in
            guard let mutationLog, !entities.isEmpty else { return }
            do {
                let puts = try entities.map {
                    JournalPut(collection: $0.collection, key: $0.recordKey, value: try $0.json())
                }
                let appended = try mutationLog.appendPuts(puts, onlyUnknownRecords: true)
                if !appended.isEmpty { lock.withLock { mutationHandler }?() }
            } catch {
                lock.withLock { storedError = error }
            }
        }
    }

    /// Waits until every edit submitted so far is in the journal, but never
    /// past `deadline`: only for the moment the application exits. True if
    /// everything was written.
    @discardableResult
    func flushBeforeTermination(until deadline: ExitDeadline) -> Bool { deadline.drain(writer) }

    /// Waits until every edit submitted so far is in the journal.
    func flush() async {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume() }
        }
    }

    private func record(_ append: (AppSyncMutationLog) throws -> Void) {
        do {
            guard let mutationLog else { return }
            try append(mutationLog)
            lock.withLock { mutationHandler }?()
        } catch {
            lock.withLock { storedError = error }
        }
    }
}
