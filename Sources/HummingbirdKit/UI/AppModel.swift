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
    enum LocalNetworkSyncState: Equatable {
        case disabled
        case starting
        case available
        case failed(String)
    }

    fileprivate static let localProfileIDKey = "appsync.localProfileID"
    private static let localNetworkSyncEnabledKey = "appsync.localNetworkSyncEnabled"
    let plugins: PluginManager
    let localProfileID: UUID
    let library: LibraryStore
    let platform: PlatformService
    let subscriptionFeed: SubscriptionFeed
    let homeFeed: FeedModel
    let playbackQueue: PlaybackQueue
    let searchHistory: SearchHistory
    let profileChanges: ProfileChangeStore
    let profileAccount: ProfileAccountService
    let profileRegistry: AppSyncProfileRegistry?
    let peerService: AppSyncPeerService?
    private(set) var localNetworkSyncEnabled: Bool
    private(set) var localNetworkSyncState: LocalNetworkSyncState
    var incomingCredentialPairing: CredentialPairingRequest?

    /// Ordinary browser tabs, including app sections opened from the menu.
    /// Order is tab-strip/switcher order.
    var contentTabs: [BrowserTab] = []
    var activeTabID: BrowserTab.ID { didSet { persistBrowserSession() } }

    @ObservationIgnored private var tabPlayers: [BrowserTab.ID: PlayerModel] = [:]

    var activeTab: BrowserTab {
        contentTabs.first { $0.id == activeTabID } ?? contentTabs[0]
    }

    /// Opens `route` in a new content tab and switches to it. The `openRoute`
    /// environment action resolves to this from anywhere in the pinned tab.
    func openInNewTab(_ route: Route, title: String? = nil) {
        let tab = makeBrowserTab()
        tab.push(route, title: title)
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
        persistBrowserSession()
        guard activeTabID == id else { return }
        if let neighbor = contentTabs[safe: index] ?? contentTabs[safe: index - 1] {
            activeTabID = neighbor.id
        } else {
            openInNewTab(.home, title: "Home")
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

    private func makeBrowserTab() -> BrowserTab {
        BrowserTab.hummingbirdTab(didChange: { [weak self] in self?.persistBrowserSession() })
    }

    private func persistBrowserSession() {
        guard !contentTabs.isEmpty else { return }
        Storage.save(
            PersistedBrowserSession(
                tabs: contentTabs.map {
                    .init(id: $0.id, title: $0.title,
                          history: $0.history.map(PersistedRoute.init),
                          historyIndex: $0.historyIndex)
                }, activeTabID: activeTabID
            ),
            name: "profile.\(localProfileID.uuidString.lowercased()).browser-session"
        )
    }

    @ObservationIgnored private var homeFeedPluginIDs: [String] = []

    init(persistence: AppPersistenceSnapshot = .empty,
         credentialStore: any CredentialStore = AuthKeychain.store,
         profileStorageDirectory: URL = Storage.directory.appendingPathComponent(
            "profile-sync", isDirectory: true
         ),
         localProfileID suppliedLocalProfileID: UUID? = nil,
         localNetworkSyncEnabled suppliedLocalNetworkSyncEnabled: Bool? = nil) {
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
        let profileRegistry = try? AppSyncProfileRegistry(
            credentialStore: credentialStore, storageDirectory: Storage.directory
        )
        let activeProfile = try? profileRegistry?.ensureProfile(
            id: localProfileID, migrateLegacyIdentity: true
        )
        let peerService = activeProfile?.peerService
        let localNetworkSyncEnabled = suppliedLocalNetworkSyncEnabled
            ?? UserDefaults.standard.bool(forKey: Self.localNetworkSyncEnabledKey)
        let storagePrefix = "profile.\(localProfileID.uuidString.lowercased())."
        let profileChanges = ProfileChangeStore(
            storageDirectory: profileStorageDirectory,
            signer: try? peerService?.peer.mutationSigner()
        )
        do {
            _ = try profileChanges.activate(localProfileID: localProfileID)
        } catch {
            assertionFailure("Could not create the local profile: \(error)")
        }
        let plugins = PluginManager(
            installed: persistence.plugins, profileChanges: profileChanges,
            storageName: storagePrefix + "plugins", credentialNamespace: storagePrefix
        )
        let library = LibraryStore(
            snapshot: persistence.library, profileChanges: profileChanges,
            storagePrefix: storagePrefix
        )
        let platform = PlatformService(
            plugins: plugins, detailsCacheStorageName: storagePrefix + "details_cache"
        )
        self.plugins = plugins
        self.localProfileID = localProfileID
        self.library = library
        self.platform = platform
        self.playbackQueue = PlaybackQueue(
            storageName: storagePrefix + "playback_queue", restored: persistence.playbackQueue
        )
        self.searchHistory = SearchHistory(
            load: { persistence.searchHistory },
            save: { Storage.save($0, name: storagePrefix + "search_history") }
        )
        self.profileChanges = profileChanges
        self.profileRegistry = profileRegistry
        self.peerService = peerService
        self.localNetworkSyncEnabled = localNetworkSyncEnabled
        self.localNetworkSyncState = localNetworkSyncEnabled ? .starting : .disabled
        self.profileAccount = ProfileAccountService(
            localProfileID: localProfileID, changes: profileChanges, library: library, plugins: plugins,
            peerService: peerService, localNetworkEnabled: localNetworkSyncEnabled
        )
        if let session = persistence.browserSession {
            // Older builds could persist destination-less "New Tab" pages.
            // They have no useful operation in Hummingbird and are discarded
            // during restoration rather than preserving a dead tab forever.
            let tabs: [BrowserTab] = session.tabs.compactMap {
                guard !$0.history.isEmpty else { return nil }
                return BrowserTab.hummingbirdTab(
                    id: $0.id, title: $0.title, history: $0.history.map(\.route),
                    historyIndex: $0.historyIndex
                )
            }
            if !tabs.isEmpty {
                self.contentTabs = tabs
                self.activeTabID = tabs.contains { $0.id == session.activeTabID }
                    ? session.activeTabID : tabs[0].id
            } else {
                let initialTab = BrowserTab.hummingbirdTab()
                initialTab.push(.home, title: "Home")
                self.contentTabs = [initialTab]
                self.activeTabID = initialTab.id
            }
        } else {
            let initialTab = BrowserTab.hummingbirdTab()
            initialTab.push(.home, title: "Home")
            self.contentTabs = [initialTab]
            self.activeTabID = initialTab.id
        }
        self.subscriptionFeed = SubscriptionFeed(library: library, plugins: plugins, platform: platform)
        self.homeFeed = FeedModel(
            initialItems: library.homeCache.map(ContentItem.init(saved:)),
            report: { [platform] error, runtime in
                platform.surface(error, pluginID: runtime.id)
            },
            didUpdate: { [weak library] items in library?.updateHomeCache(items) }
        )
        for tab in contentTabs { tab.onChange { [weak self] in self?.persistBrowserSession() } }
        if localNetworkSyncEnabled { startLocalNetworkSync() }
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

    var localProfiles: [AppSyncLocalProfile] {
        (try? profileRegistry?.profiles()) ?? []
    }

    func createLocalProfile() -> UUID? {
        guard let profile = try? profileRegistry?.createProfile() else { return nil }
        if localNetworkSyncEnabled {
            Task { try? await profile.peerService.startLANServer(
                appIDs: [HummingbirdProfileSchema.appID]
            ) }
        }
        return profile.id
    }

    func saveBrowserSession() { persistBrowserSession() }

    func setLocalNetworkSyncEnabled(_ enabled: Bool) {
        guard enabled != localNetworkSyncEnabled else { return }
        localNetworkSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.localNetworkSyncEnabledKey)
        profileAccount.setLocalNetworkEnabled(enabled)
        if enabled {
            startLocalNetworkSync()
        } else {
            profileRegistry?.concealAll()
            localNetworkSyncState = .disabled
        }
    }

    private func startLocalNetworkSync() {
        guard let profileRegistry else {
            localNetworkSyncState = .failed("Local profiles are unavailable.")
            return
        }
        localNetworkSyncState = .starting
        Task {
            do {
                try await profileRegistry.exposeAll(appIDs: [HummingbirdProfileSchema.appID])
                guard localNetworkSyncEnabled else {
                    profileRegistry.concealAll()
                    return
                }
                localNetworkSyncState = .available
                await profileAccount.sync()
            } catch {
                profileRegistry.concealAll()
                if localNetworkSyncEnabled {
                    localNetworkSyncState = .failed(error.localizedDescription)
                }
            }
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
    var browserSession: PersistedBrowserSession?

    static let empty = Self(
        plugins: [], library: .empty, playbackQueue: nil,
        searchHistory: [], browserSession: nil
    )

    static func load(profileID: UUID? = nil) async -> Self {
        await Task.detached(priority: .userInitiated) {
            let resolvedProfileID = profileID ?? UserDefaults.standard.string(
                forKey: "appsync.localProfileID"
            ).flatMap(UUID.init(uuidString:))
            let prefix = resolvedProfileID.map {
                "profile.\($0.uuidString.lowercased())."
            } ?? ""
            let legacyOwnerKey = "appsync.legacyStorageProfileID"
            let defaults = UserDefaults.standard
            if defaults.string(forKey: legacyOwnerKey) == nil, let resolvedProfileID {
                defaults.set(resolvedProfileID.uuidString, forKey: legacyOwnerKey)
            }
            let mayLoadLegacy = resolvedProfileID?.uuidString
                == defaults.string(forKey: legacyOwnerKey)
            func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
                Storage.load(type, name: prefix + name)
                    ?? (mayLoadLegacy ? Storage.load(type, name: name) : nil)
            }
            return Self(
                plugins: load([InstalledPlugin].self, "plugins") ?? [],
                library: LibraryPersistenceSnapshot(
                    subscriptions: load([Subscription].self, "subscriptions") ?? [],
                    playlists: load([Playlist].self, "playlists") ?? [],
                    watchLater: load([SavedVideo].self, "watch_later") ?? [],
                    history: load([HistoryEntry].self, "history") ?? [],
                    feedCache: load([String: [SavedVideo]].self, "feed_cache") ?? [:],
                    homeCache: load([SavedVideo].self, "home_cache") ?? []
                ),
                playbackQueue: load(PersistedPlaybackQueue.self, "playback_queue"),
                searchHistory: load([String].self, "search_history") ?? [],
                browserSession: resolvedProfileID.flatMap {
                    Storage.load(
                        PersistedBrowserSession.self,
                        name: "profile.\($0.uuidString.lowercased()).browser-session"
                    )
                }
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
