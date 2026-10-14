import Foundation
import SwiftOpenUI
import Observation
import ATProtoKit
import ATAppSync
#if DEBUG && os(iOS)
import UIKit
#endif

/// Owns the long-lived services and wires them together.
@MainActor
@Observable
final class AppModel {
    private static let localProfileIDKey = "appsync.localProfileID"
    let plugins: PluginManager
    let library: LibraryStore
    let platform: PlatformService
    let subscriptionFeed: SubscriptionFeed
    let homeFeed: FeedModel
    let playbackQueue: PlaybackQueue
    let searchHistory: SearchHistory
    let profileChanges: ProfileChangeStore
    let profileAccount: ProfileAccountService
    let peerService: AppSyncPeerService?
    var incomingCredentialPairing: CredentialPairingRequest?

    /// Ordinary browser tabs, including app sections opened from the menu.
    /// Order is tab-strip/switcher order.
    var contentTabs: [BrowserTab] = []
    var activeTabID: BrowserTab.ID

    @ObservationIgnored private var tabPlayers: [BrowserTab.ID: PlayerModel] = [:]

    var activeTab: BrowserTab {
        contentTabs.first { $0.id == activeTabID } ?? contentTabs[0]
    }

    /// Opens `route` in a new content tab and switches to it. The `openRoute`
    /// environment action resolves to this from anywhere in the pinned tab.
    func openInNewTab(_ route: Route, title: String? = nil) {
        let tab = BrowserTab.hummingbirdTab()
        tab.push(route, title: title)
        contentTabs.append(tab)
        activeTabID = tab.id
    }

    /// Opens a blank start-page tab, matching the new-tab action in a browser
    /// tab overview. Its first route replaces the start page in this tab.
    func openNewTab() {
        let tab = BrowserTab.hummingbirdTab()
        contentTabs.append(tab)
        activeTabID = tab.id
    }

    /// Opens one of the app's top-level sections as an ordinary browser tab.
    func openSection(_ route: Route, title: String) {
        openInNewTab(route, title: title)
    }

    func closeTab(_ id: BrowserTab.ID) {
        guard let index = contentTabs.firstIndex(where: { $0.id == id }) else { return }
        tabPlayers.removeValue(forKey: id)?.teardown()
        contentTabs.remove(at: index)
        guard activeTabID == id else { return }
        if let neighbor = contentTabs[safe: index] ?? contentTabs[safe: index - 1] {
            activeTabID = neighbor.id
        } else {
            openNewTab()
        }
    }

    /// Playback belongs to the browser tab, not to its currently mounted view.
    /// SwiftUI replaces that view when another tab is selected, but the media
    /// session should continue until this tab navigates elsewhere or is closed.
    func player(forTab id: BrowserTab.ID) -> PlayerModel {
        if let player = tabPlayers[id] { return player }
        let player = PlayerModel()
        tabPlayers[id] = player
        return player
    }

    var activePlayerForDebug: PlayerModel? { tabPlayers[activeTabID] }

    @ObservationIgnored private var homeFeedPluginIDs: [String] = []

    init(persistence: AppPersistenceSnapshot = .empty,
         credentialStore: any CredentialStore = AuthKeychain.store,
         profileStorageDirectory: URL = Storage.directory.appendingPathComponent(
            "profile-sync", isDirectory: true
         ),
         localProfileID suppliedLocalProfileID: UUID? = nil) {
        let peerService = try? AppSyncPeerService(
            credentialStore: credentialStore, storageDirectory: Storage.directory
        )
        let profileChanges = ProfileChangeStore(
            storageDirectory: profileStorageDirectory,
            signer: try? peerService?.peer.mutationSigner()
        )
        let localProfileID: UUID
        if let suppliedLocalProfileID {
            localProfileID = suppliedLocalProfileID
        } else if let stored = UserDefaults.standard.string(forKey: Self.localProfileIDKey),
           let restored = UUID(uuidString: stored) {
            localProfileID = restored
        } else {
            localProfileID = UUID()
            UserDefaults.standard.set(localProfileID.uuidString, forKey: Self.localProfileIDKey)
        }
        do {
            _ = try profileChanges.activate(localProfileID: localProfileID)
        } catch {
            assertionFailure("Could not create the local profile: \(error)")
        }
        let plugins = PluginManager(installed: persistence.plugins, profileChanges: profileChanges)
        let library = LibraryStore(snapshot: persistence.library, profileChanges: profileChanges)
        let platform = PlatformService(plugins: plugins)
        self.plugins = plugins
        self.library = library
        self.platform = platform
        self.playbackQueue = PlaybackQueue(restored: persistence.playbackQueue)
        self.searchHistory = SearchHistory(load: { persistence.searchHistory })
        self.profileChanges = profileChanges
        self.peerService = peerService
        self.profileAccount = ProfileAccountService(
            changes: profileChanges, library: library, plugins: plugins,
            peerService: peerService
        )
        let initialTab = BrowserTab.hummingbirdTab()
        initialTab.push(.home, title: "Home")
        self.contentTabs = [initialTab]
        self.activeTabID = initialTab.id
        self.subscriptionFeed = SubscriptionFeed(library: library, plugins: plugins, platform: platform)
        self.homeFeed = FeedModel(
            initialItems: library.homeCache.map(ContentItem.init(saved:)),
            report: { [platform] error, runtime in
                platform.surface(error, pluginID: runtime.id)
            },
            didUpdate: { [weak library] items in library?.updateHomeCache(items) }
        )
        #if DEBUG && os(iOS)
        RenderStallMonitor.shared.start { [weak self] in
            guard let self else { return [:] }
            let player = self.activePlayerForDebug
            return [
                "activeTab": self.activeTabID.uuidString,
                "route": String(describing: self.activeTab.current),
                "tabCount": String(self.contentTabs.count),
                "playerPreparing": String(player?.isPreparing ?? false),
                "playerPlaying": String(player?.isPlaying ?? false),
                "playerFullscreen": String(player?.isFullscreen ?? false),
            ]
        }
        #endif
    }

    /// Hands a feed model the error reporter it needs.
    func makeFeed() -> FeedModel {
        FeedModel { [platform] error, runtime in platform.surface(error, pluginID: runtime.id) }
    }

    /// Refreshes Home once for each enabled-source configuration. SwiftOpenUI may
    /// recreate the view hosting `.task(id:)`; keeping this gate in the long-lived
    /// app model prevents duplicate plugin and network work.
    func loadHome(force: Bool = false) async {
        let ids = plugins.enabledPlugins.map(\.id)
        guard !ids.isEmpty else {
            homeFeedPluginIDs = []
            return
        }
        guard !homeFeed.isLoading else { return }
        guard force || ids != homeFeedPluginIDs || !homeFeed.loadedOnce else { return }
        homeFeedPluginIDs = ids
        await homeFeed.reload(sources: await platform.homeSources())
        // A source can be enabled or disabled while the previous configuration
        // is still loading. The task for the new id will observe `isLoading` and
        // return; finish that requested transition here once the old load settles.
        if plugins.enabledPlugins.map(\.id) != homeFeedPluginIDs {
            await loadHome()
        }
    }

    func handleIncomingURL(_ url: URL) {
        if let request = CredentialPairingRequest(url: url) {
            incomingCredentialPairing = request
        }
    }
}

struct LibraryPersistenceSnapshot: Sendable {
    var subscriptions: [Subscription]
    var playlists: [Playlist]
    var watchLater: [SavedVideo]
    var history: [HistoryEntry]
    var feedCache: [String: [SavedVideo]]
    var homeCache: [SavedVideo]

    static let empty = Self(subscriptions: [], playlists: [], watchLater: [], history: [],
                            feedCache: [:], homeCache: [])
}

struct AppPersistenceSnapshot: Sendable {
    var plugins: [InstalledPlugin]
    var library: LibraryPersistenceSnapshot
    var playbackQueue: PersistedPlaybackQueue?
    var searchHistory: [String]

    static let empty = Self(plugins: [], library: .empty, playbackQueue: nil, searchHistory: [])

    static func load() async -> Self {
        await Task.detached(priority: .userInitiated) {
            Self(
                plugins: Storage.load([InstalledPlugin].self, name: "plugins") ?? [],
                library: LibraryPersistenceSnapshot(
                    subscriptions: Storage.load([Subscription].self, name: "subscriptions") ?? [],
                    playlists: Storage.load([Playlist].self, name: "playlists") ?? [],
                    watchLater: Storage.load([SavedVideo].self, name: "watch_later") ?? [],
                    history: Storage.load([HistoryEntry].self, name: "history") ?? [],
                    feedCache: Storage.load([String: [SavedVideo]].self, name: "feed_cache") ?? [:],
                    homeCache: Storage.load([SavedVideo].self, name: "home_cache") ?? []
                ),
                playbackQueue: Storage.load(PersistedPlaybackQueue.self, name: "playback_queue"),
                searchHistory: Storage.load([String].self, name: "search_history") ?? []
            )
        }.value
    }
}

#if DEBUG && os(iOS)
private actor RenderStallLogWriter {
    static let shared = RenderStallLogWriter()

    func append(_ data: Data) {
        do {
            let root = try RenderDiagnosticsStorage.root()
            let url = root.appendingPathComponent("render-stalls.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Diagnostics must never affect the application being measured.
        }
    }
}

@MainActor
private final class RenderStallMonitor: NSObject {
    static let shared = RenderStallMonitor()
    private let launchID = UUID().uuidString
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var context: (() -> [String: String])?

    func start(context: @escaping () -> [String: String]) {
        self.context = context
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        NotificationCenter.default.addObserver(
            self, selector: #selector(reset), name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reset), name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    @objc private func reset() { previousTimestamp = nil }

    @objc private func tick(_ link: CADisplayLink) {
        defer { previousTimestamp = link.timestamp }
        guard let previousTimestamp else { return }
        let gap = link.timestamp - previousTimestamp
        guard gap >= 0.25 else { return }
        var event: [String: Any] = context?() ?? [:]
        event["time"] = ISO8601DateFormatter().string(from: Date())
        event["launchID"] = launchID
        event["gapMilliseconds"] = Int((gap * 1_000).rounded())
        RollingMainThreadSampler.recordStall(
            gap: gap,
            context: event.reduce(into: [:]) { result, pair in result[pair.key] = String(describing: pair.value) }
        )
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        Task { await RenderStallLogWriter.shared.append(data) }
    }
}
#endif

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
