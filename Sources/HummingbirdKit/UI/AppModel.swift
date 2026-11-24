import Foundation
import SwiftOpenUI
import Observation
import os
import ATProtoKit
import ATAppSync

/// Owns the long-lived services and wires them together.
@MainActor
@Observable
final class AppModel {
    private static let localNetworkSyncEnabledKey = "appsync.localNetworkSyncEnabled"
    /// Where this window's state outlives the process.
    let stores: AppDataStores
    let plugins: PluginManager
    let localProfileID: UUID
    let library: LibraryStore
    let platform: PlatformService
    /// This window's view of every download in the media cache.
    let downloads: DownloadsModel
    let subscriptionFeed: SubscriptionFeed
    /// Checks subscribed channels for new videos in background windows.
    let subscriptionPoller: SubscriptionPoller
    /// The profile's synced data cache; nil without an instance identity.
    let syncedCache: CacheJournal?
    @ObservationIgnored private let backgroundSession: BackgroundSession
    let homeFeed: FeedModel
    let searchHistory: SearchHistory
    let profileChanges: ProfileChangeStore
    let profileAccount: ProfileAccountService
    let profileRegistry: AppSyncProfileRegistry?
    let peerService: AppSyncPeerService?
    /// Why `peerService` is absent, e.g. the credential store refused its keys.
    let peerServiceFailure: String?
    /// Gates every use of a resource the system guards with a permission prompt.
    let permissions: PermissionGate
    let localNetworkSync: LocalNetworkSyncController
    var incomingCredentialPairing: CredentialPairingRequest?

    /// Ordinary browser tabs, including app sections opened from the menu.
    /// Order is tab-strip/switcher order.
    var contentTabs: [BrowserTab] = []
    var activeTabID: BrowserTab.ID { didSet { persistBrowserSession() } }

    @ObservationIgnored private var tabPlayers: [BrowserTab.ID: PlayerModel] = [:]
    /// Each tab's playback queue (`queue(forTab:)`), saved with its tab.
    @ObservationIgnored private(set) var tabQueues: [BrowserTab.ID: PlaybackQueue] = [:]
    private struct WeakPlayer { weak var player: PlayerModel? }
    /// Every tab player alive in the process, by tab (see `player(forTab:)`).
    private static var livePlayers: [BrowserTab.ID: WeakPlayer] = [:]
    /// Makes each tab's player (tests supply players with fake backends).
    @ObservationIgnored var makePlayer: @MainActor (AppDataStores) -> PlayerModel = { PlayerModel(stores: $0) }

    /// atproto sign-ins in progress, each shown in its own browser tab.
    private(set) var oauthAuthorizations: [OAuthTabAuthorization.ID: OAuthTabAuthorization] = [:]
    @ObservationIgnored private var oauthReturnTabs: [OAuthTabAuthorization.ID: BrowserTab.ID] = [:]
    @ObservationIgnored private let oauthTabPresenter: OAuthTabPresenter?

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

    /// A closed tab, for Reopen Closed Tab.
    struct ClosedTab {
        let title: String
        let history: [Route]
        let historyIndex: Int
        /// Where it was among the content tabs.
        let index: Int
    }

    /// Tabs closed in this window during this launch, the last closed last.
    /// Tabs that can't outlive the moment, such as a pending sign-in, aren't
    /// kept, as with the saved session.
    private(set) var closedTabs: [ClosedTab] = []
    private static let closedTabLimit = 20

    /// Opens the tab closed last again where it was, with its history.
    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = BrowserTab.hummingbirdTab(
            title: closed.title, history: closed.history, historyIndex: closed.historyIndex,
            didChange: { [weak self] in self?.persistBrowserSession() }
        )
        contentTabs.insert(tab, at: min(closed.index, contentTabs.count))
        activeTabID = tab.id
    }

    func closeTab(_ id: BrowserTab.ID) {
        guard let index = contentTabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = contentTabs[index]
        if !closing.history.isEmpty, closing.history.allSatisfy({ PersistedRoute($0) != nil }) {
            closedTabs.append(ClosedTab(title: closing.title, history: closing.history,
                                        historyIndex: closing.historyIndex, index: index))
            closedTabs.removeFirst(max(0, closedTabs.count - Self.closedTabLimit))
        }
        // Closing a sign-in tab abandons that sign-in.
        for route in contentTabs[index].history {
            if case .oauthAuthorization(let authorizationID) = route {
                oauthAuthorizations[authorizationID]?.cancel()
            }
        }
        tabPlayers.removeValue(forKey: id)?.close()
        tabQueues[id] = nil
        Self.livePlayers[id] = nil
        contentTabs.remove(at: index)
        persistBrowserSession()
        guard activeTabID == id else { return }
        if let neighbor = contentTabs[safe: index] ?? contentTabs[safe: index - 1] {
            activeTabID = neighbor.id
        } else {
            openInNewTab(.home, title: "Home")
        }
    }

    /// Moves a tab to `index` among the content tabs (after its removal, as
    /// in the overview's drop position) and keeps the order across launches.
    func moveTab(_ id: BrowserTab.ID, to index: Int) {
        guard let from = contentTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = contentTabs.remove(at: from)
        contentTabs.insert(tab, at: min(max(0, index), contentTabs.count))
        persistBrowserSession()
    }

    /// Playback belongs to the browser tab, not to whichever view shows it.
    /// Pages stay mounted while other tabs are selected, but within a tab the
    /// view is replaced as it navigates, and the tab overview hosts the page
    /// in its card; the media session continues until this tab navigates
    /// elsewhere (`shouldKeepPlaybackWhenHidden`) or is closed.
    func player(forTab id: BrowserTab.ID) -> PlayerModel {
        if let player = tabPlayers[id] { return player }
        // One player per tab, in the whole process: a second one for the same
        // tab (a tab restored twice, two scenes restoring one session) would
        // play the same video twice.
        if let existing = Self.livePlayers[id]?.player, existing !== tabPlayers[id] {
            Logger.player.fault("second_player_for_tab")
            assertionFailure("A second PlayerModel was created for tab \(id)")
        }
        let player = makePlayer(stores)
        Self.livePlayers[id] = WeakPlayer(player: player)
        // At most one tab plays in a window (Picture in Picture aside).
        player.onStartedPlaying = { [weak self, weak player] in
            guard let self, let player else { return }
            for other in self.tabPlayers.values where other !== player { other.pauseForAnotherTab() }
        }
        // Returning from Picture in Picture brings this tab back.
        player.onRestoreRequested = { [weak self] in self?.activeTabID = id }
        tabPlayers[id] = player
        return player
    }

    /// The playback queue of tab `id`: every tab has its own, saved with it.
    /// Pages reach their tab's queue through the environment
    /// (`@Environment(PlaybackQueue.self)`, set by `BrowserTabContentView`).
    func queue(forTab id: BrowserTab.ID) -> PlaybackQueue {
        if let queue = tabQueues[id] { return queue }
        let queue = makeQueue(restored: nil)
        tabQueues[id] = queue
        return queue
    }

    /// The queue of the tab in front (menus and commands that act on it).
    var activeTabQueue: PlaybackQueue { queue(forTab: activeTabID) }

    private func makeQueue(restored: PersistedPlaybackQueue?) -> PlaybackQueue {
        PlaybackQueue(restored: restored, didChange: { [weak self] in self?.persistBrowserSession() })
    }

    var activePlayerForDebug: PlayerModel? { tabPlayers[activeTabID] }

    /// The window showing this model closed: every tab's player stops now
    /// (wired to the window/scene-end callback of SwiftOpenUI's lifecycle API)
    /// (no sound keeps playing from a closed window) and is released. Their
    /// downloads continue in the background (`MediaDownloads`). Other
    /// windows have their own models and are unaffected.
    func closeWindow() {
        downloads.stop()
        for id in tabPlayers.keys { Self.livePlayers[id] = nil }
        let players = tabPlayers.values
        tabPlayers.removeAll()
        for player in players { player.close() }
    }

    /// Before the app goes to the background: every player records where it is.
    func recordPlaybackProgress() {
        for player in tabPlayers.values { player.recordProgressNow() }
    }

    /// Players this window still owns (tests, debugging).
    var openPlayerCount: Int { tabPlayers.count }

    private func makeBrowserTab() -> BrowserTab {
        BrowserTab.hummingbirdTab(didChange: { [weak self] in self?.persistBrowserSession() })
    }

    private func persistBrowserSession() {
        // A tab holding a route that cannot outlive this launch, such as a
        // pending sign-in, is not restored.
        let tabs: [PersistedBrowserSession.Tab] = contentTabs.compactMap { tab in
            let history = tab.history.compactMap(PersistedRoute.init)
            guard history.count == tab.history.count else { return nil }
            return .init(id: tab.id, title: tab.title, history: history, historyIndex: tab.historyIndex,
                         queue: tabQueues[tab.id]?.persisted)
        }
        guard let firstTab = tabs.first else { return }
        let activeTabID = tabs.contains { $0.id == activeTabID } ? activeTabID : firstTab.id
        stores.storage.save(
            PersistedBrowserSession(tabs: tabs, activeTabID: activeTabID),
            name: "profile.\(localProfileID.uuidString.lowercased()).browser-session"
        )
    }

    @ObservationIgnored private var homeFeedPluginIDs: [String] = []

    /// Everything this window persists goes to `stores`. In particular the
    /// local-profile registry there lists every profile, each opened (and its
    /// identity keys read from the credential store) when local sync starts.
    init(persistence: AppPersistenceSnapshot = .empty,
         stores: AppDataStores,
         localProfileID suppliedLocalProfileID: UUID? = nil,
         localNetworkSyncEnabled suppliedLocalNetworkSyncEnabled: Bool? = nil,
         permissions suppliedPermissions: PermissionGate? = nil,
         openedProfile: OpenedLocalProfile? = nil,
         pluginCredentials: PreloadedPluginCredentials? = nil) {
        let defaults = stores.defaults
        let profile = openedProfile ?? OpenedLocalProfile.open(stores: stores, localProfileID: suppliedLocalProfileID)
        let localProfileID = profile.localProfileID
        let credentialStore = stores.credentialStore
        let storage = stores.storage
        let profileRegistry = profile.registry
        let peerService = profile.peerService
        let peerServiceFailure = profile.peerServiceFailure
        let localNetworkSyncEnabled = suppliedLocalNetworkSyncEnabled
            ?? defaults.bool(forKey: Self.localNetworkSyncEnabledKey)
        let storagePrefix = profile.storagePrefix
        let profileChanges = profile.changes
        // Parental controls and the age bound are profile data; one policy
        // per profile is shared by every window that opens it.
        let policy = SourceAccessPolicy.shared(
            stores: stores, profilePrefix: storagePrefix, profileChanges: profileChanges
        )
        let plugins = PluginManager(
            installed: persistence.plugins, profileChanges: profileChanges,
            storage: storage, credentialStore: credentialStore, policy: policy,
            storageName: storagePrefix + "plugins", credentialNamespace: storagePrefix,
            preloadedCredentials: pluginCredentials
        )
        let library = LibraryStore(
            snapshot: persistence.library, profileChanges: profileChanges,
            storage: storage, storagePrefix: storagePrefix,
            recovery: stores.storage.pendingWrites.map { ProgressRecovery(queue: $0, profile: localProfileID) }
        )
        let platform = PlatformService(
            plugins: plugins, storage: storage, detailsCacheStorageName: storagePrefix + "details_cache"
        )
        let downloadsModel = DownloadsModel(downloads: stores.mediaDownloads)
        downloadsModel.start()
        // The first video should not initialise the playback frameworks on the main thread.
        prewarmMediaBackend()
        // Downloads keep going while the app is suspended (iOS and friends).
        let mediaDownloads = stores.mediaDownloads
        Task { await mediaDownloads.useTransport(BackgroundTransport()) }
        // Optional transcoding uses the platform's hardware encoder.
        let transcoding = stores.transcoding
        let transcodeEnabled = stores.defaults.bool(forKey: PlaybackPreferenceKey.transcodeDownloads)
        Task {
            await transcoding.useEncoder(TranscodeEncoder.platform)
            await transcoding.setEnabled(transcodeEnabled)
        }
        // The platform's power conditions drive the shared background-work policy.
        stores.backgroundWork.followPlatformPowerState()
        self.downloads = downloadsModel
        self.stores = stores
        self.plugins = plugins
        self.localProfileID = localProfileID
        self.library = library
        self.platform = platform
        self.searchHistory = SearchHistory(
            load: { persistence.searchHistory },
            save: { storage.save($0, name: storagePrefix + "search_history") }
        )
        self.profileChanges = profileChanges
        self.profileRegistry = profileRegistry
        self.peerService = peerService
        self.peerServiceFailure = peerServiceFailure?.localizedDescription
        let permissions = suppliedPermissions ?? PermissionGate(
            system: PlatformPermissions(), ledger: FilePermissionLedger(directory: stores.permissionsDirectory)
        )
        self.permissions = permissions
        plugins.localNetworkAccess = PluginLocalNetworkAccess(gate: permissions)
        // Sign in inside a browser tab where this build can render one; the
        // tab presenter is pointed at this model once it is initialized.
        let oauthTabPresenter = OAuthTabPresenter.isSupported ? OAuthTabPresenter() : nil
        self.oauthTabPresenter = oauthTabPresenter
        let oauthPresenter: any ATProtoOAuthPresenter =
            if let oauthTabPresenter { oauthTabPresenter } else { WebAuthenticationSessionPresenter() }
        self.profileAccount = ProfileAccountService(
            localProfileID: localProfileID, stores: stores,
            changes: profileChanges, library: library, plugins: plugins,
            peerService: peerService, peerServiceFailure: peerServiceFailure,
            // Off until this instance may use the local network; the
            // controller below turns it on once the gate has passed.
            localNetworkEnabled: false,
            // Timer-driven local-network pulls wait while energy is being
            // saved (Low Power Mode, a power-saver profile, a hot device).
            defersBulkWork: { [backgroundWork = stores.backgroundWork] in backgroundWork.defersNonUrgentWork },
            oauthPresenter: oauthPresenter
        )
        let profileAccount = self.profileAccount
        self.localNetworkSync = LocalNetworkSyncController(
            isEnabled: localNetworkSyncEnabled, gate: permissions,
            transport: .init(
                expose: {
                    guard let profileRegistry else { throw LocalNetworkSyncUnavailable.noLocalProfiles }
                    try await profileRegistry.exposeAll(appIDs: [HummingbirdProfileSchema.appID])
                },
                conceal: { profileRegistry?.concealAll() },
                denials: { profileRegistry?.localNetworkDenials() ?? AsyncStream { $0.finish() } }
            ),
            persist: { [preferences = stores.preferences] in
                preferences.defaults.set($0, forKey: Self.localNetworkSyncEnabledKey)
            },
            activeChanged: { active in
                profileAccount.setLocalNetworkEnabled(active)
                if active { Task { await profileAccount.sync() } }
            }
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
        self.subscriptionFeed = SubscriptionFeed(
            library: library, plugins: plugins, platform: platform, preferences: stores.preferences
        )
        // The profile's synced data cache, and the channel checks that run in
        // background windows (first window of the profile only).
        let syncedCache = SyncedCache.shared(stores: stores, profileID: localProfileID, peerService: peerService)
        self.syncedCache = syncedCache
        let feed = self.subscriptionFeed
        let poller = SubscriptionPoller(
            library: library, storage: storage, storagePrefix: storagePrefix, notifier: SystemNewVideoNotifier(),
            // The profile's age policy, asked fresh for every check.
            approve: { [plugins] pluginID in
                guard let plugin = plugins.plugin(pluginID), plugin.enabled,
                      case .success(let approval) = await plugins.policy.approveLoad(plugin.config) else { return nil }
                return approval
            },
            fetch: { subscription in try await feed.fetchChannel(subscription) },
            cache: syncedCache,
            context: { [plugins] pluginID, approval in
                plugins.plugin(pluginID).flatMap {
                    SyncedCache.context(for: $0, approval: approval, signedIn: plugins.isLoggedIn(pluginID))
                }
            }
        )
        self.subscriptionPoller = poller
        let backgroundSession = BackgroundSession(stores: stores, profileAccount: profileAccount,
                                                  poller: poller, cache: syncedCache)
        self.backgroundSession = backgroundSession
        self.homeFeed = FeedModel(
            initialItems: library.homeCache.map(ContentItem.init(saved:)),
            report: { [platform] error, runtime in
                platform.surface(error, pluginID: runtime.id)
            },
            didUpdate: { [weak library] items in library?.updateHomeCache(items) }
        )
        for tab in contentTabs { tab.onChange { [weak self] in self?.persistBrowserSession() } }
        // Each tab's queue, as it was saved with the tab.
        for saved in persistence.browserSession?.tabs ?? [] where contentTabs.contains(where: { $0.id == saved.id }) {
            if let queue = saved.queue { tabQueues[saved.id] = makeQueue(restored: queue) }
        }
        // The profile's queue from before each tab had its own goes to the
        // active tab, once: saved there, then its old store is deleted.
        if let legacy = persistence.legacyPlaybackQueue {
            let active = queue(forTab: activeTabID)
            if active.items.isEmpty {
                tabQueues[activeTabID] = makeQueue(restored: legacy.queue)
            } else {
                for video in legacy.queue.items { active.enqueue(video) }
            }
            persistBrowserSession()
            stores.storage.remove(name: legacy.storeName)
        }
        oauthTabPresenter?.host = self
        // A restored or synced setting is applied without touching the
        // network here: the gate explains it before the system can prompt.
        let localNetworkSync = self.localNetworkSync
        Task { await localNetworkSync.applyStoredSetting() }
        // Progress a crash kept out of the history comes back now, once.
        Task { [library] in await library.recoverInterruptedProgress() }
        // Background windows work for the first window of a profile.
        backgroundSession.claim()
        HummingbirdDebug.register(self)
        #if DEBUG
        MainThreadWatchdog.shared.start(log: PerformanceReports.store(for: stores).stallLog) { [weak self] in
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

    /// A plugin offered by a grayjay://plugin/ link the app was opened with,
    /// for Add Source to show (never installed without the user's go-ahead).
    var incomingPluginInstall: IncomingPluginInstall?

    func handleIncomingURL(_ url: URL) {
        if let request = CredentialPairingRequest(url: url) {
            incomingCredentialPairing = request
        } else if let link = PluginInstallLink(url) {
            incomingPluginInstall = IncomingPluginInstall(configURL: link.configURL)
        }
    }

    var localProfiles: [AppSyncLocalProfile] {
        (try? profileRegistry?.profiles()) ?? []
    }

    func createLocalProfile() -> UUID? {
        guard let profile = try? profileRegistry?.createProfile() else { return nil }
        if localNetworkSync.isActive {
            Task { try? await profile.peerService.startLANServer(
                appIDs: [HummingbirdProfileSchema.appID]
            ) }
        }
        return profile.id
    }

    func saveBrowserSession() { persistBrowserSession() }
}

private enum LocalNetworkSyncUnavailable: LocalizedError {
    case noLocalProfiles
    var errorDescription: String? { "Local profiles are unavailable." }
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

struct LegacyPlaybackQueue: Sendable {
    var queue: PersistedPlaybackQueue
    var storeName: String
}

struct AppPersistenceSnapshot: Sendable {
    var plugins: [InstalledPlugin]
    var library: LibraryPersistenceSnapshot
    /// The queue the profile kept before each tab had its own, and its store:
    /// given to the active tab once (`AppModel.init`), then deleted.
    var legacyPlaybackQueue: LegacyPlaybackQueue?
    var searchHistory: [String]
    var browserSession: PersistedBrowserSession?

    static let empty = Self(
        plugins: [], library: .empty, legacyPlaybackQueue: nil,
        searchHistory: [], browserSession: nil
    )

    /// Without a `profileID`, loads the profile `stores` last selected.
    static func load(stores: AppDataStores, profileID: UUID? = nil) async -> Self {
        await Task.detached(priority: .userInitiated) {
            let resolvedProfileID = profileID ?? stores.selectedLocalProfileID
            let prefix = resolvedProfileID.map {
                "profile.\($0.uuidString.lowercased())."
            } ?? ""
            let legacyOwnerKey = "appsync.legacyStorageProfileID"
            let defaults = stores.defaults
            if defaults.string(forKey: legacyOwnerKey) == nil, let resolvedProfileID {
                defaults.set(resolvedProfileID.uuidString, forKey: legacyOwnerKey)
            }
            let mayLoadLegacy = resolvedProfileID?.uuidString
                == defaults.string(forKey: legacyOwnerKey)
            let storage = stores.storage
            func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
                storage.load(type, name: prefix + name)
                    ?? (mayLoadLegacy ? storage.load(type, name: name) : nil)
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
                legacyPlaybackQueue: storage.load(PersistedPlaybackQueue.self, name: prefix + "playback_queue")
                    .map { LegacyPlaybackQueue(queue: $0, storeName: prefix + "playback_queue") }
                    ?? (mayLoadLegacy ? storage.load(PersistedPlaybackQueue.self, name: "playback_queue")
                        .map { LegacyPlaybackQueue(queue: $0, storeName: "playback_queue") } : nil),
                searchHistory: load([String].self, "search_history") ?? [],
                browserSession: resolvedProfileID.flatMap {
                    storage.load(
                        PersistedBrowserSession.self,
                        name: "profile.\($0.uuidString.lowercased()).browser-session"
                    )
                }
            )
        }.value
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

extension AppModel: OAuthTabHost {
    /// Opens the authorization page in a new tab, remembering which tab the
    /// sign-in started from so it can be returned to.
    func presentOAuthAuthorization(_ authorization: OAuthTabAuthorization) {
        oauthAuthorizations[authorization.id] = authorization
        oauthReturnTabs[authorization.id] = activeTabID
        openInNewTab(.oauthAuthorization(authorization.id), title: "Sign In")
    }

    /// Closes the sign-in's tab, if the user has not already, and returns
    /// to the tab it was started from when the sign-in tab was in front.
    func dismissOAuthAuthorization(_ authorization: OAuthTabAuthorization) {
        oauthAuthorizations[authorization.id] = nil
        let returnTabID = oauthReturnTabs.removeValue(forKey: authorization.id)
        #if (canImport(WebKit) && !BACKEND_GTK && (os(macOS) || os(iOS) || os(visionOS))) || BACKEND_GTK_WEBKIT
        OAuthWebPageStore.shared.remove(authorization)
        #endif
        guard let tab = contentTabs.first(where: { $0.current == .oauthAuthorization(authorization.id) }) else {
            return
        }
        let wasActive = tab.id == activeTabID
        closeTab(tab.id)
        if wasActive, let returnTabID, contentTabs.contains(where: { $0.id == returnTabID }) {
            activeTabID = returnTabID
        }
    }
}

/// The local profile's identity, peer service and change journal. Opening it
/// reads (or creates) the instance's identity keys in the credential store
/// and decodes the journal, so app launch does it away from the main actor
/// (`HummingbirdRoot.prepared`).
struct OpenedLocalProfile: Sendable {
    let localProfileID: UUID
    /// Where this profile's keys live in `AppDataStores`.
    var storagePrefix: String { "profile.\(localProfileID.uuidString.lowercased())." }
    let registry: AppSyncProfileRegistry?
    let peerService: AppSyncPeerService?
    let peerServiceFailure: (any Error)?
    let changes: ProfileChangeStore

    @concurrent
    static func openInBackground(stores: AppDataStores, localProfileID: UUID?) async -> Self {
        open(stores: stores, localProfileID: localProfileID)
    }

    /// Without a `localProfileID`, opens the profile `stores` last selected,
    /// or creates one.
    static func open(stores: AppDataStores, localProfileID suppliedLocalProfileID: UUID?) -> Self {
        // The permission ledger, made next on the main actor, is keyed by the
        // app's code-signing identity; those Security calls belong here.
        AppSigningIdentity.prepare()
        let localProfileID: UUID
        if let suppliedLocalProfileID {
            localProfileID = suppliedLocalProfileID
        } else if let restored = stores.selectedLocalProfileID {
            localProfileID = restored
        } else {
            localProfileID = UUID()
            stores.defaults.set(localProfileID.uuidString, forKey: AppDataStores.localProfileIDKey)
        }
        // A store that refuses the identity keys leaves the profile without
        // peer messaging; the reason is kept and shown rather than reported
        // later as a generic "unavailable".
        let registry: AppSyncProfileRegistry?
        var peerService: AppSyncPeerService?
        var peerServiceFailure: (any Error)?
        do {
            let opened = try AppSyncProfileRegistry(
                credentialStore: stores.credentialStore, storageDirectory: stores.appSyncDirectory
            )
            registry = opened
            do {
                peerService = try opened.ensureProfile(
                    id: localProfileID, migrateLegacyIdentity: true
                ).peerService
            } catch {
                peerServiceFailure = error
            }
        } catch {
            registry = nil
            peerServiceFailure = error
        }
        let changes = ProfileChangeStore(
            storageDirectory: stores.profileSyncDirectory,
            signer: try? peerService?.peer.mutationSigner()
        )
        do {
            _ = try changes.activate(localProfileID: localProfileID)
        } catch {
            assertionFailure("Could not create the local profile: \(error)")
        }
        return Self(
            localProfileID: localProfileID, registry: registry, peerService: peerService,
            peerServiceFailure: peerServiceFailure, changes: changes
        )
    }
}

/// A plugin a link asked to install, waiting for the user in Add Source.
struct IncomingPluginInstall: Identifiable, Equatable, Sendable {
    let id = UUID()
    let configURL: URL
}
