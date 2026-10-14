import Foundation
import Observation
import ATProtoKit

@MainActor
@Observable
final class LibraryStore {
    private(set) var subscriptions: [Subscription] = []
    private(set) var playlists: [Playlist] = []
    private(set) var watchLater: [SavedVideo] = []
    private(set) var history: [HistoryEntry] = []
    /// Most recent first-page results per channel URL, used when a channel is rate-limited or fails.
    private(set) var feedCache: [String: [SavedVideo]] = [:]
    private(set) var homeCache: [SavedVideo] = []
    @ObservationIgnored private let profileChanges: ProfileChangeStore?
    @ObservationIgnored private var applyingRemoteChange = false
    @ObservationIgnored private var watchLaterPositions: [String: Int] = [:]

    static let historyLimit = 2000

    init(snapshot: LibraryPersistenceSnapshot = .empty, profileChanges: ProfileChangeStore? = nil) {
        self.profileChanges = profileChanges
        subscriptions = snapshot.subscriptions
        playlists = snapshot.playlists
        watchLater = snapshot.watchLater
        watchLaterPositions = Dictionary(uniqueKeysWithValues: snapshot.watchLater.enumerated().map { ($0.element.id, $0.offset) })
        history = snapshot.history
        feedCache = snapshot.feedCache
        homeCache = snapshot.homeCache
    }

    // MARK: subscriptions

    func isSubscribed(_ channelURL: String) -> Bool { subscriptions.contains { $0.channelURL == channelURL } }

    func subscribe(channel: ChannelInfo, pluginId: String) {
        guard !isSubscribed(channel.url) else { return }
        let subscription = Subscription(channelURL: channel.url, pluginId: pluginId, name: channel.name,
                                        thumbnail: channel.thumbnail, subscribers: channel.subscribers)
        subscriptions.append(subscription)
        Storage.save(subscriptions, name: "subscriptions")
        if !applyingRemoteChange { profileChanges?.put(.subscription(subscription)) }
    }

    func subscribe(url: String, pluginId: String, name: String, thumbnail: String?) {
        guard !isSubscribed(url) else { return }
        let subscription = Subscription(channelURL: url, pluginId: pluginId, name: name, thumbnail: thumbnail)
        subscriptions.append(subscription)
        Storage.save(subscriptions, name: "subscriptions")
        if !applyingRemoteChange { profileChanges?.put(.subscription(subscription)) }
    }

    func unsubscribe(_ channelURL: String) {
        let key = HummingbirdProfileSchema.key(for: channelURL)
        subscriptions.removeAll { $0.channelURL == channelURL }
        feedCache[channelURL] = nil
        Storage.save(subscriptions, name: "subscriptions")
        Storage.save(feedCache, name: "feed_cache")
        if !applyingRemoteChange { profileChanges?.delete(collection: HummingbirdProfileSchema.subscription, key: key) }
    }

    func updateSubscription(_ channelURL: String, fetched: Date, newest: Int?, cache: [SavedVideo]?) {
        guard let i = subscriptions.firstIndex(where: { $0.channelURL == channelURL }) else { return }
        subscriptions[i].lastFetched = fetched
        if let newest { subscriptions[i].lastItemDate = max(newest, subscriptions[i].lastItemDate ?? 0) }
        if let cache { feedCache[channelURL] = cache }
    }

    func persistSubscriptionState() {
        Storage.save(subscriptions, name: "subscriptions")
        Storage.save(feedCache, name: "feed_cache")
    }

    func updateHomeCache(_ items: [ContentItem]) {
        homeCache = Array(items.prefix(250).map(SavedVideo.init))
        Storage.save(homeCache, name: "home_cache")
    }

    // MARK: watch later

    func isInWatchLater(_ v: SavedVideo) -> Bool { watchLater.contains { $0.id == v.id } }

    func toggleWatchLater(_ v: SavedVideo) {
        if let i = watchLater.firstIndex(where: { $0.id == v.id }) {
            watchLater.remove(at: i)
            watchLaterPositions[v.id] = nil
            if !applyingRemoteChange { profileChanges?.delete(collection: HummingbirdProfileSchema.watchLater,
                                   key: HummingbirdProfileSchema.key(for: v.id))
            }
        } else {
            watchLater.append(v)
            watchLaterPositions[v.id] = watchLater.count - 1
            if !applyingRemoteChange {
                profileChanges?.put(.watchLater(.init(video: v, position: watchLater.count - 1)))
            }
        }
        Storage.save(watchLater, name: "watch_later")
    }

    func moveWatchLater(from: IndexSet, to: Int) {
        watchLater.move(fromOffsets: from, toOffset: to)
        Storage.save(watchLater, name: "watch_later")
        recordWatchLaterOrder()
    }

    func removeWatchLater(at offsets: IndexSet) {
        let removed = offsets.map { watchLater[$0] }
        watchLater.remove(atOffsets: offsets)
        for video in removed { watchLaterPositions[video.id] = nil }
        Storage.save(watchLater, name: "watch_later")
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
        Storage.save(playlists, name: "playlists")
        if !applyingRemoteChange { profileChanges?.put(.playlist(p)) }
        return p
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[i].name = name; playlists[i].updated = Date()
        Storage.save(playlists, name: "playlists")
        if !applyingRemoteChange { profileChanges?.put(.playlist(playlists[i])) }
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        Storage.save(playlists, name: "playlists")
        if !applyingRemoteChange { profileChanges?.delete(collection: HummingbirdProfileSchema.playlist,
                               key: RecordKey(rawValue: id.uuidString.lowercased())!)
        }
    }

    func add(_ v: SavedVideo, to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[i].videos.contains(where: { $0.id == v.id }) else { return }
        playlists[i].videos.append(v); playlists[i].updated = Date()
        Storage.save(playlists, name: "playlists")
        if !applyingRemoteChange { profileChanges?.put(.playlist(playlists[i])) }
    }

    func removeVideos(at offsets: IndexSet, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].videos.remove(atOffsets: offsets); playlists[i].updated = Date()
        Storage.save(playlists, name: "playlists")
        if !applyingRemoteChange { profileChanges?.put(.playlist(playlists[i])) }
    }

    func moveVideos(from: IndexSet, to: Int, in playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].videos.move(fromOffsets: from, toOffset: to); playlists[i].updated = Date()
        Storage.save(playlists, name: "playlists")
        if !applyingRemoteChange { profileChanges?.put(.playlist(playlists[i])) }
    }

    // MARK: history

    func position(for v: SavedVideo) -> Double? { history.first { $0.id == v.id }?.position }

    func recordProgress(_ v: SavedVideo, seconds: Double) {
        let entry = HistoryEntry(video: v, position: seconds, date: Date())
        if let i = history.firstIndex(where: { $0.id == v.id }) { history.remove(at: i) }
        history.insert(entry, at: 0)
        let evicted: [HistoryEntry]
        if history.count > Self.historyLimit {
            evicted = Array(history.suffix(history.count - Self.historyLimit))
            history.removeLast(evicted.count)
        } else {
            evicted = []
        }
        if !applyingRemoteChange { profileChanges?.put(.history(entry)) }
        if !applyingRemoteChange {
            for old in evicted {
                profileChanges?.delete(collection: HummingbirdProfileSchema.history,
                                       key: HummingbirdProfileSchema.key(for: old.id))
            }
        }
    }

    func flushHistory() { Storage.save(history, name: "history") }

    func removeHistory(at offsets: IndexSet) {
        let removed = offsets.map { history[$0] }
        history.remove(atOffsets: offsets)
        flushHistory()
        for entry in removed {
            profileChanges?.delete(collection: HummingbirdProfileSchema.history,
                                   key: HummingbirdProfileSchema.key(for: entry.id))
        }
    }

    func clearHistory() {
        let removed = history
        history = []
        flushHistory()
        for entry in removed {
            profileChanges?.delete(collection: HummingbirdProfileSchema.history,
                                   key: HummingbirdProfileSchema.key(for: entry.id))
        }
    }

    func applyRemote(_ entity: ProfileEntity, deleted: Bool) {
        applyingRemoteChange = true
        defer { applyingRemoteChange = false }
        switch entity {
        case .subscription(let value):
            if deleted { unsubscribe(value.channelURL) }
            else if let index = subscriptions.firstIndex(where: { $0.id == value.id }) {
                subscriptions[index] = value; Storage.save(subscriptions, name: "subscriptions")
            } else { subscriptions.append(value); Storage.save(subscriptions, name: "subscriptions") }
        case .playlist(let value):
            if deleted { deletePlaylist(value.id) }
            else if let index = playlists.firstIndex(where: { $0.id == value.id }) {
                playlists[index] = value; Storage.save(playlists, name: "playlists")
            } else { playlists.append(value); Storage.save(playlists, name: "playlists") }
        case .watchLater(let value):
            if deleted {
                watchLater.removeAll { $0.id == value.id }
                watchLaterPositions[value.id] = nil
            } else if let index = watchLater.firstIndex(where: { $0.id == value.id }) {
                watchLater[index] = value.video
                watchLaterPositions[value.id] = value.position
            } else {
                watchLater.append(value.video)
                watchLaterPositions[value.id] = value.position
            }
            watchLater.sort {
                let lhs = watchLaterPositions[$0.id] ?? .max
                let rhs = watchLaterPositions[$1.id] ?? .max
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }
            Storage.save(watchLater, name: "watch_later")
        case .history(let value):
            history.removeAll { $0.id == value.id }
            if !deleted { history.append(value); history.sort { $0.date > $1.date } }
            flushHistory()
        case .plugin:
            break
        }
    }

    func applyRemoteDelete(collection: NSID, key: RecordKey) {
        applyingRemoteChange = true
        defer { applyingRemoteChange = false }
        if collection == HummingbirdProfileSchema.subscription {
            for value in subscriptions where HummingbirdProfileSchema.key(for: value.id) == key { unsubscribe(value.id) }
        } else if collection == HummingbirdProfileSchema.playlist {
            for value in playlists where RecordKey(rawValue: value.id.uuidString.lowercased()) == key { deletePlaylist(value.id) }
        } else if collection == HummingbirdProfileSchema.watchLater {
            let removed = watchLater.filter { HummingbirdProfileSchema.key(for: $0.id) == key }
            watchLater.removeAll { HummingbirdProfileSchema.key(for: $0.id) == key }
            for value in removed { watchLaterPositions[value.id] = nil }
            Storage.save(watchLater, name: "watch_later")
        } else if collection == HummingbirdProfileSchema.history {
            history.removeAll { HummingbirdProfileSchema.key(for: $0.id) == key }
            flushHistory()
        }
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
        Storage.save(subscriptions, name: "subscriptions")
        Storage.save(playlists, name: "playlists")
        Storage.save(watchLater, name: "watch_later")
        flushHistory()
        for subscription in b.subscriptions { profileChanges?.put(.subscription(subscription)) }
        for playlist in b.playlists { profileChanges?.put(.playlist(playlist)) }
        for (position, video) in watchLater.enumerated() {
            profileChanges?.put(.watchLater(.init(video: video, position: position)))
        }
        for entry in b.history { profileChanges?.put(.history(entry)) }
    }

    private func recordWatchLaterOrder() {
        guard !applyingRemoteChange else { return }
        for (position, video) in watchLater.enumerated() {
            watchLaterPositions[video.id] = position
            profileChanges?.put(.watchLater(.init(video: video, position: position)))
        }
    }
}
