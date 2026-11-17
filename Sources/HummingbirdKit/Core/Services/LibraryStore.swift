import Foundation
import Observation
import ATAppSync
import ATProtoKit

@MainActor
@Observable
final class LibraryStore {
    // Every change to a synced collection counts as an edit, so a sync
    // result computed from older state is not committed over it.
    private(set) var subscriptions: [Subscription] = [] { didSet { revisions.subscriptions &+= 1 } }
    private(set) var playlists: [Playlist] = [] { didSet { revisions.playlists &+= 1 } }
    private(set) var watchLater: [SavedVideo] = [] { didSet { revisions.watchLater &+= 1 } }
    private(set) var history: [HistoryEntry] = [] { didSet { revisions.history &+= 1 } }
    /// Most recent first-page results per channel URL, used when a channel is rate-limited or fails.
    private(set) var feedCache: [String: [SavedVideo]] = [:]
    private(set) var homeCache: [SavedVideo] = []
    @ObservationIgnored private let profileChanges: ProfileChangeStore?
    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private let storagePrefix: String
    @ObservationIgnored private var watchLaterPositions: [String: Int] = [:]
    @ObservationIgnored private var revisions = LibraryRevisions()
    /// Progress recorded since the history was last written to the journal.
    @ObservationIgnored private var unsyncedHistory: [String: HistoryEntry] = [:]
    @ObservationIgnored private var lastHistorySync = Date.distantPast

    nonisolated static let historyLimit = 2000
    /// The longest progress waits before it is written to the synced
    /// profile while a video keeps playing.
    nonisolated static let historySyncInterval: TimeInterval = 60

    init(snapshot: LibraryPersistenceSnapshot = .empty, profileChanges: ProfileChangeStore? = nil,
         storage: Storage, storagePrefix: String = "") {
        self.profileChanges = profileChanges
        self.storage = storage
        self.storagePrefix = storagePrefix
        subscriptions = snapshot.subscriptions
        playlists = snapshot.playlists
        watchLater = snapshot.watchLater
        watchLaterPositions = Dictionary(uniqueKeysWithValues: snapshot.watchLater.enumerated().map { ($0.element.id, $0.offset) })
        history = snapshot.history
        feedCache = snapshot.feedCache
        homeCache = snapshot.homeCache
    }

    private func save<T: Encodable & Sendable>(_ value: T, name: String) {
        storage.save(value, name: storagePrefix + name)
    }

    // MARK: subscriptions

    func isSubscribed(_ channelURL: String) -> Bool { subscriptions.contains { $0.channelURL == channelURL } }

    func subscribe(channel: ChannelInfo, pluginId: String) {
        guard !isSubscribed(channel.url) else { return }
        let subscription = Subscription(channelURL: channel.url, pluginId: pluginId, name: channel.name,
                                        thumbnail: channel.thumbnail, subscribers: channel.subscribers)
        subscriptions.append(subscription)
        save(subscriptions, name: "subscriptions")
        profileChanges?.put(.subscription(subscription))
    }

    func subscribe(url: String, pluginId: String, name: String, thumbnail: String?) {
        guard !isSubscribed(url) else { return }
        let subscription = Subscription(channelURL: url, pluginId: pluginId, name: name, thumbnail: thumbnail)
        subscriptions.append(subscription)
        save(subscriptions, name: "subscriptions")
        profileChanges?.put(.subscription(subscription))
    }

    func unsubscribe(_ channelURL: String) {
        let key = HummingbirdProfileSchema.key(for: channelURL)
        subscriptions.removeAll { $0.channelURL == channelURL }
        feedCache[channelURL] = nil
        save(subscriptions, name: "subscriptions")
        save(feedCache, name: "feed_cache")
        profileChanges?.delete(collection: HummingbirdProfileSchema.subscription, key: key)
    }

    func updateSubscription(_ channelURL: String, fetched: Date, newest: Int?, cache: [SavedVideo]?) {
        guard let i = subscriptions.firstIndex(where: { $0.channelURL == channelURL }) else { return }
        subscriptions[i].lastFetched = fetched
        if let newest { subscriptions[i].lastItemDate = max(newest, subscriptions[i].lastItemDate ?? 0) }
        if let cache { feedCache[channelURL] = cache }
    }

    func persistSubscriptionState() {
        save(subscriptions, name: "subscriptions")
        save(feedCache, name: "feed_cache")
    }

    func updateHomeCache(_ items: [ContentItem]) {
        homeCache = Array(items.prefix(250).map(SavedVideo.init))
        save(homeCache, name: "home_cache")
    }

    // MARK: watch later

    func isInWatchLater(_ v: SavedVideo) -> Bool { watchLater.contains { $0.id == v.id } }

    func toggleWatchLater(_ v: SavedVideo) {
        if let i = watchLater.firstIndex(where: { $0.id == v.id }) {
            watchLater.remove(at: i)
            watchLaterPositions[v.id] = nil
            profileChanges?.delete(collection: HummingbirdProfileSchema.watchLater,
                                   key: HummingbirdProfileSchema.key(for: v.id))
        } else {
            watchLater.append(v)
            watchLaterPositions[v.id] = watchLater.count - 1
            profileChanges?.put(.watchLater(.init(video: v, position: watchLater.count - 1)))
        }
        save(watchLater, name: "watch_later")
    }

    func moveWatchLater(from: IndexSet, to: Int) {
        watchLater.move(fromOffsets: from, toOffset: to)
        save(watchLater, name: "watch_later")
        recordWatchLaterOrder()
    }

    func removeWatchLater(at offsets: IndexSet) {
        let removed = offsets.map { watchLater[$0] }
        watchLater.remove(atOffsets: offsets)
        for video in removed { watchLaterPositions[video.id] = nil }
        save(watchLater, name: "watch_later")
        for video in removed {
            profileChanges?.delete(collection: HummingbirdProfileSchema.watchLater,
                                   key: HummingbirdProfileSchema.key(for: video.id))
        }
    }

    // MARK: playlists

    @discardableResult
    func createPlaylist(name: String, videos: [SavedVideo] = []) -> Playlist {
        let p = Playlist(name: name, videos: videos)
        playlists.append(p)
        save(playlists, name: "playlists")
        profileChanges?.put(.playlist(p))
        return p
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[i].name = name; playlists[i].updated = Date()
        save(playlists, name: "playlists")
        profileChanges?.put(.playlist(playlists[i]))
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save(playlists, name: "playlists")
        profileChanges?.delete(collection: HummingbirdProfileSchema.playlist,
                               key: RecordKey(rawValue: id.uuidString.lowercased())!)
    }

    func add(_ v: SavedVideo, to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[i].videos.contains(where: { $0.id == v.id }) else { return }
        playlists[i].videos.append(v); playlists[i].updated = Date()
        save(playlists, name: "playlists")
        profileChanges?.put(.playlist(playlists[i]))
    }

    func removeVideos(at offsets: IndexSet, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].videos.remove(atOffsets: offsets); playlists[i].updated = Date()
        save(playlists, name: "playlists")
        profileChanges?.put(.playlist(playlists[i]))
    }

    func moveVideos(from: IndexSet, to: Int, in playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].videos.move(fromOffsets: from, toOffset: to); playlists[i].updated = Date()
        save(playlists, name: "playlists")
        profileChanges?.put(.playlist(playlists[i]))
    }

    // MARK: history

    func position(for v: SavedVideo) -> Double? { history.first { $0.id == v.id }?.position }

    /// Records playback progress. The library updates at once; the synced
    /// record is written at most every `historySyncInterval` (and whenever
    /// `flushHistory()` or `syncHistory()` runs: pause, stop, finish, going
    /// to the background), not on every progress tick, so the journal and
    /// every peer snapshot stay small.
    func recordProgress(_ v: SavedVideo, seconds: Double, now: Date = Date()) {
        let entry = HistoryEntry(video: v, position: seconds, date: now)
        if let i = history.firstIndex(where: { $0.id == v.id }) { history.remove(at: i) }
        history.insert(entry, at: 0)
        // The limit only bounds what this device keeps. Trimming is not a
        // deletion: every device trims the same merged history the same
        // way, and a delete here would remove the entry everywhere.
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        unsyncedHistory[entry.id] = entry
        if now.timeIntervalSince(lastHistorySync) >= Self.historySyncInterval { syncHistory(now: now) }
    }

    /// Writes progress recorded since the last write to the synced profile.
    func syncHistory(now: Date = Date()) {
        lastHistorySync = now
        guard !unsyncedHistory.isEmpty else { return }
        let entries = unsyncedHistory.values.sorted { $0.date < $1.date }
        unsyncedHistory = [:]
        for entry in entries { profileChanges?.put(.history(entry)) }
    }

    func flushHistory() {
        save(history, name: "history")
        syncHistory()
    }

    func removeHistory(at offsets: IndexSet) {
        let removed = offsets.map { history[$0] }
        history.remove(atOffsets: offsets)
        for entry in removed { unsyncedHistory[entry.id] = nil }
        flushHistory()
        for entry in removed {
            profileChanges?.delete(collection: HummingbirdProfileSchema.history,
                                   key: HummingbirdProfileSchema.key(for: entry.id))
        }
    }

    func clearHistory() {
        let removed = history
        history = []
        unsyncedHistory = [:]
        flushHistory()
        for entry in removed {
            profileChanges?.delete(collection: HummingbirdProfileSchema.history,
                                   key: HummingbirdProfileSchema.key(for: entry.id))
        }
    }

    // MARK: sync

    /// The library as sync reads it. Copying arrays is constant time, so
    /// taking this on the main actor costs nothing; the work happens on it
    /// elsewhere.
    func syncBase() -> LibrarySyncBase {
        LibrarySyncBase(
            subscriptions: subscriptions, playlists: playlists, watchLater: watchLater,
            watchLaterPositions: watchLaterPositions, history: history, revisions: revisions
        )
    }

    /// Adopts collections computed from synced records: one assignment and
    /// one save per collection that changed. A collection edited locally
    /// since its base was taken is left alone (its records are not reported
    /// as committed, so they are applied again from fresh state). Returns
    /// the collections committed.
    ///
    /// This is the only way sync changes the library. There is no way to
    /// apply a single remote record: a `LibrarySyncBatch` can only be made by
    /// `LibrarySyncBatch.compute`, away from the main actor.
    @discardableResult
    func commit(_ batch: LibrarySyncBatch) -> Set<NSID> {
        var committed = Set<NSID>()
        if let value = batch.subscriptions {
            if revisions.subscriptions == batch.base.subscriptions {
                if value != subscriptions {
                    subscriptions = value
                    let channels = Set(value.map(\.channelURL))
                    let cache = feedCache.filter { channels.contains($0.key) }
                    if cache.count != feedCache.count { feedCache = cache; save(feedCache, name: "feed_cache") }
                    save(subscriptions, name: "subscriptions")
                }
                committed.insert(HummingbirdProfileSchema.subscription)
            }
        }
        if let value = batch.playlists, revisions.playlists == batch.base.playlists {
            if value != playlists { playlists = value; save(playlists, name: "playlists") }
            committed.insert(HummingbirdProfileSchema.playlist)
        }
        if let value = batch.watchLater, revisions.watchLater == batch.base.watchLater {
            watchLaterPositions = value.positions
            if value.videos != watchLater { watchLater = value.videos; save(watchLater, name: "watch_later") }
            committed.insert(HummingbirdProfileSchema.watchLater)
        }
        if let value = batch.history, revisions.history == batch.base.history {
            if value != history { history = value; save(history, name: "history") }
            committed.insert(HummingbirdProfileSchema.history)
        }
        return committed
    }

    // MARK: backup

    func makeBackup(pluginSources: [String: String]) -> LibraryBackup {
        LibraryBackup(subscriptions: subscriptions, playlists: playlists, watchLater: watchLater, history: history, pluginSources: pluginSources)
    }

    /// Merges a backup into the library without removing anything already there.
    func merge(_ b: LibraryBackup) {
        for s in b.subscriptions where !isSubscribed(s.channelURL) { subscriptions.append(s) }
        for p in b.playlists where !playlists.contains(where: { $0.id == p.id }) { playlists.append(p) }
        for v in b.watchLater where !watchLater.contains(where: { $0.id == v.id }) { watchLater.append(v) }
        for h in b.history where !history.contains(where: { $0.id == h.id }) { history.append(h) }
        history.sort { $0.date > $1.date }
        save(subscriptions, name: "subscriptions")
        save(playlists, name: "playlists")
        save(watchLater, name: "watch_later")
        flushHistory()
        for subscription in b.subscriptions { profileChanges?.put(.subscription(subscription)) }
        for playlist in b.playlists { profileChanges?.put(.playlist(playlist)) }
        for (position, video) in watchLater.enumerated() {
            profileChanges?.put(.watchLater(.init(video: video, position: position)))
        }
        for entry in b.history { profileChanges?.put(.history(entry)) }
    }

    private func recordWatchLaterOrder() {
        for (position, video) in watchLater.enumerated() {
            watchLaterPositions[video.id] = position
            profileChanges?.put(.watchLater(.init(video: video, position: position)))
        }
    }
}

/// Counts local edits per collection, so a sync result computed from older
/// state is never committed over a newer local edit.
struct LibraryRevisions: Equatable, Sendable {
    var subscriptions = 0
    var playlists = 0
    var watchLater = 0
    var history = 0
}

/// The library collections sync starts from.
struct LibrarySyncBase: Sendable {
    let subscriptions: [Subscription]
    let playlists: [Playlist]
    let watchLater: [SavedVideo]
    let watchLaterPositions: [String: Int]
    let history: [HistoryEntry]
    let revisions: LibraryRevisions
}

/// One synced record for the library: the journal event, and for a put its
/// decoded entity. A delete names only its record key.
struct LibrarySyncChange: Sendable {
    let mutation: JournalMutation
    let entity: ProfileEntity?
}

/// Whole replacement collections, each computed from a `LibrarySyncBase`
/// and every synced change to that collection. Collections without changes
/// are nil. Its initializer is private to this file: the only way to make
/// one is `compute`, which runs away from the main actor, so the library
/// can't be changed from sync record by record on the main actor.
struct LibrarySyncBatch: Sendable {
    struct WatchLater: Equatable, Sendable {
        let videos: [SavedVideo]
        let positions: [String: Int]
    }

    let base: LibraryRevisions
    fileprivate(set) var subscriptions: [Subscription]?
    fileprivate(set) var playlists: [Playlist]?
    fileprivate(set) var watchLater: WatchLater?
    fileprivate(set) var history: [HistoryEntry]?

    fileprivate init(base: LibraryRevisions) { self.base = base }

    /// Computes every changed collection concurrently.
    @concurrent
    static func compute(from base: LibrarySyncBase, changes: [LibrarySyncChange]) async -> LibrarySyncBatch {
        let grouped = Dictionary(grouping: changes) { $0.mutation.collection }
        async let subscriptions = grouped[HummingbirdProfileSchema.subscription].map {
            mergeSubscriptions(base.subscriptions, $0)
        }
        async let playlists = grouped[HummingbirdProfileSchema.playlist].map { mergePlaylists(base.playlists, $0) }
        async let watchLater = grouped[HummingbirdProfileSchema.watchLater].map {
            mergeWatchLater(base.watchLater, positions: base.watchLaterPositions, $0)
        }
        async let history = grouped[HummingbirdProfileSchema.history].map { mergeHistory(base.history, $0) }
        var batch = LibrarySyncBatch(base: base.revisions)
        batch.subscriptions = await subscriptions
        batch.playlists = await playlists
        batch.watchLater = await watchLater
        batch.history = await history
        return batch
    }

    private static func mergeSubscriptions(_ base: [Subscription], _ changes: [LibrarySyncChange]) -> [Subscription] {
        var result = base
        let deleted = Set(changes.filter { $0.mutation.operation == .delete }.map(\.mutation.recordKey))
        if !deleted.isEmpty { result.removeAll { deleted.contains(HummingbirdProfileSchema.key(for: $0.channelURL)) } }
        var index = Dictionary(result.enumerated().map { ($1.channelURL, $0) }) { first, _ in first }
        for case .subscription(var value)? in changes.map(\.entity) {
            if let i = index[value.channelURL] {
                // Refresh bookkeeping is this device's own; keep the newest.
                let local = result[i]
                value.lastFetched = [local.lastFetched, value.lastFetched].compactMap { $0 }.max()
                value.lastItemDate = [local.lastItemDate, value.lastItemDate].compactMap { $0 }.max()
                result[i] = value
            } else {
                index[value.channelURL] = result.count
                result.append(value)
            }
        }
        return result
    }

    private static func mergePlaylists(_ base: [Playlist], _ changes: [LibrarySyncChange]) -> [Playlist] {
        var result = base
        let deleted = Set(changes.filter { $0.mutation.operation == .delete }.map(\.mutation.recordKey.rawValue))
        if !deleted.isEmpty { result.removeAll { deleted.contains($0.id.uuidString.lowercased()) } }
        var index = Dictionary(result.enumerated().map { ($1.id, $0) }) { first, _ in first }
        for case .playlist(let value)? in changes.map(\.entity) {
            if let i = index[value.id] { result[i] = value } else {
                index[value.id] = result.count
                result.append(value)
            }
        }
        return result
    }

    private static func mergeWatchLater(_ base: [SavedVideo], positions basePositions: [String: Int],
                                        _ changes: [LibrarySyncChange]) -> WatchLater {
        var videos = base
        var positions = basePositions
        let deleted = Set(changes.filter { $0.mutation.operation == .delete }.map(\.mutation.recordKey))
        if !deleted.isEmpty {
            videos.removeAll { video in
                let gone = deleted.contains(HummingbirdProfileSchema.key(for: video.id))
                if gone { positions[video.id] = nil }
                return gone
            }
        }
        var index = Dictionary(videos.enumerated().map { ($1.id, $0) }) { first, _ in first }
        for case .watchLater(let value)? in changes.map(\.entity) {
            positions[value.id] = value.position
            if let i = index[value.id] { videos[i] = value.video } else {
                index[value.id] = videos.count
                videos.append(value.video)
            }
        }
        videos.sort {
            let lhs = positions[$0.id] ?? .max
            let rhs = positions[$1.id] ?? .max
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
        return WatchLater(videos: videos, positions: positions)
    }

    private static func mergeHistory(_ base: [HistoryEntry], _ changes: [LibrarySyncChange]) -> [HistoryEntry] {
        var byID = Dictionary(base.map { ($0.id, $0) }) { first, _ in first }
        var deletedAt: [RecordKey: Date] = [:]
        for change in changes where change.mutation.operation == .delete {
            deletedAt[change.mutation.recordKey] = Date(
                timeIntervalSince1970: Double(change.mutation.timestamp.milliseconds) / 1_000
            )
        }
        if !deletedAt.isEmpty {
            // A removal never takes away a watch that happened after it.
            byID = byID.filter { id, entry in
                guard let removed = deletedAt[HummingbirdProfileSchema.key(for: id)] else { return true }
                return entry.date > removed
            }
        }
        for case .history(let value)? in changes.map(\.entity) {
            // Progress recorded here but not yet written to the journal can be
            // newer than the synced winner; the later watch wins.
            if let local = byID[value.id], local.date > value.date { continue }
            byID[value.id] = value
        }
        let sorted = byID.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        return Array(sorted.prefix(LibraryStore.historyLimit))
    }
}
