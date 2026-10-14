import ATProtoKit
import Crypto
import Foundation

enum HummingbirdProfileSchema {
    static let spaceType = NSID(rawValue: "com.eightybps.hummingbird.profile")!
    static let spaceKey = RecordKey(rawValue: "self")!
    static let subscription = NSID(rawValue: "com.eightybps.hummingbird.subscription")!
    static let playlist = NSID(rawValue: "com.eightybps.hummingbird.playlist")!
    static let watchLater = NSID(rawValue: "com.eightybps.hummingbird.watchLater")!
    static let history = NSID(rawValue: "com.eightybps.hummingbird.history")!
    static let plugin = NSID(rawValue: "com.eightybps.hummingbird.plugin")!
    static let journal = NSID(rawValue: "com.eightybps.hummingbird.journal")!

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

/// A watch-later item plus its user-visible list position. Reordering journals
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

    var collection: NSID {
        switch self {
        case .subscription: HummingbirdProfileSchema.subscription
        case .playlist: HummingbirdProfileSchema.playlist
        case .watchLater: HummingbirdProfileSchema.watchLater
        case .history: HummingbirdProfileSchema.history
        case .plugin: HummingbirdProfileSchema.plugin
        }
    }

    var recordKey: RecordKey {
        switch self {
        case .subscription(let value): HummingbirdProfileSchema.key(for: value.channelURL)
        case .playlist(let value): RecordKey(rawValue: value.id.uuidString.lowercased())!
        case .watchLater(let value): HummingbirdProfileSchema.key(for: value.id)
        case .history(let value): HummingbirdProfileSchema.key(for: value.id)
        case .plugin(let value): HummingbirdProfileSchema.key(for: value.pluginID)
        }
    }

    func json() throws -> JSONValue {
        switch self {
        case .subscription(let value): return try .encoding(value)
        case .playlist(let value): return try .encoding(value)
        case .watchLater(let value): return try .encoding(value)
        case .history(let value): return try .encoding(value)
        case .plugin(let value): return try .encoding(value)
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
        }
        return nil
    }
}

/// Synchronous mutation boundary used by local stores. Returning from a user
/// edit means its outbox entry is already durable; connectivity is irrelevant.
final class ProfileMutationJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let storageDirectory: URL?
    private var active: OfflineMutationJournal?
    private var activeAccount: DID?
    private var storedError: (any Error)?
    private var mutationHandler: (@Sendable () -> Void)?

    /// Creates the account-switching journal used by the app. No events are
    /// recorded before an account is selected; sign-in bootstraps current state.
    init(storageDirectory: URL) {
        self.storageDirectory = storageDirectory
    }

    /// Creates an already-active journal, primarily for isolated tests.
    init(journal: OfflineMutationJournal) {
        storageDirectory = nil
        active = journal
    }

    var lastError: (any Error)? { lock.withLock { storedError } }
    var journal: OfflineMutationJournal? { lock.withLock { active } }

    func activate(account: DID) throws -> OfflineMutationJournal {
        if let journal = lock.withLock({ activeAccount == account ? active : nil }) { return journal }
        guard let storageDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        let digest = SHA256.hash(data: Data(account.rawValue.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let created = try OfflineMutationJournal(
            fileURL: storageDirectory.appendingPathComponent("\(digest).json")
        )
        lock.withLock {
            active = created
            activeAccount = account
            storedError = nil
        }
        return created
    }

    func deactivate() {
        lock.withLock {
            active = nil
            activeAccount = nil
        }
    }

    func setMutationHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { mutationHandler = handler }
    }

    func put(_ entity: ProfileEntity) {
        do {
            guard let journal else { return }
            try journal.appendPut(collection: entity.collection, key: entity.recordKey, value: entity.json())
            lock.withLock { mutationHandler }?()
        } catch {
            lock.withLock { storedError = error }
        }
    }

    func delete(collection: NSID, key: RecordKey) {
        do {
            guard let journal else { return }
            try journal.appendDelete(collection: collection, key: key)
            lock.withLock { mutationHandler }?()
        } catch {
            lock.withLock { storedError = error }
        }
    }
}
