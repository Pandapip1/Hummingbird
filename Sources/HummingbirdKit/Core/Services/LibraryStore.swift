import Foundation
import Observation

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

    static let historyLimit = 2000

    init() {
        subscriptions = Storage.load([Subscription].self, name: "subscriptions") ?? []
        playlists = Storage.load([Playlist].self, name: "playlists") ?? []
        watchLater = Storage.load([SavedVideo].self, name: "watch_later") ?? []
        history = Storage.load([HistoryEntry].self, name: "history") ?? []
        feedCache = Storage.load([String: [SavedVideo]].self, name: "feed_cache") ?? [:]
        homeCache = Storage.load([SavedVideo].self, name: "home_cache") ?? []
    }

    // MARK: subscriptions

    func isSubscribed(_ channelURL: String) -> Bool { subscriptions.contains { $0.channelURL == channelURL } }

    func subscribe(channel: ChannelInfo, pluginId: String) {
        guard !isSubscribed(channel.url) else { return }
        subscriptions.append(Subscription(channelURL: channel.url, pluginId: pluginId, name: channel.name,
                                          thumbnail: channel.thumbnail, subscribers: channel.subscribers))
        Storage.save(subscriptions, name: "subscriptions")
    }

    func subscribe(url: String, pluginId: String, name: String, thumbnail: String?) {
        guard !isSubscribed(url) else { return }
        subscriptions.append(Subscription(channelURL: url, pluginId: pluginId, name: name, thumbnail: thumbnail))
        Storage.save(subscriptions, name: "subscriptions")
    }

    func unsubscribe(_ channelURL: String) {
        subscriptions.removeAll { $0.channelURL == channelURL }
        feedCache[channelURL] = nil
        Storage.save(subscriptions, name: "subscriptions")
        Storage.save(feedCache, name: "feed_cache")
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
        if let i = watchLater.firstIndex(where: { $0.id == v.id }) { watchLater.remove(at: i) } else { watchLater.append(v) }
        Storage.save(watchLater, name: "watch_later")
    }

    func moveWatchLater(from: IndexSet, to: Int) {
        watchLater.move(fromOffsets: from, toOffset: to)
        Storage.save(watchLater, name: "watch_later")
    }

    func removeWatchLater(at offsets: IndexSet) {
        watchLater.remove(atOffsets: offsets)
        Storage.save(watchLater, name: "watch_later")
    }

    // MARK: playlists

    @discardableResult
    func createPlaylist(name: String, videos: [SavedVideo] = []) -> Playlist {
        let p = Playlist(name: name, videos: videos)
        playlists.append(p)
        Storage.save(playlists, name: "playlists")
        return p
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[i].name = name; playlists[i].updated = Date()
        Storage.save(playlists, name: "playlists")
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        Storage.save(playlists, name: "playlists")
    }

    func add(_ v: SavedVideo, to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[i].videos.contains(where: { $0.id == v.id }) else { return }
        playlists[i].videos.append(v); playlists[i].updated = Date()
        Storage.save(playlists, name: "playlists")
    }

    func removeVideos(at offsets: IndexSet, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].videos.remove(atOffsets: offsets); playlists[i].updated = Date()
        Storage.save(playlists, name: "playlists")
    }

    func moveVideos(from: IndexSet, to: Int, in playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].videos.move(fromOffsets: from, toOffset: to); playlists[i].updated = Date()
        Storage.save(playlists, name: "playlists")
    }

    // MARK: history

    func position(for v: SavedVideo) -> Double? { history.first { $0.id == v.id }?.position }

    func recordProgress(_ v: SavedVideo, seconds: Double) {
        let entry = HistoryEntry(video: v, position: seconds, date: Date())
        if let i = history.firstIndex(where: { $0.id == v.id }) { history.remove(at: i) }
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    func flushHistory() { Storage.save(history, name: "history") }

    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        flushHistory()
    }

    func clearHistory() { history = []; flushHistory() }

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
    }
}
