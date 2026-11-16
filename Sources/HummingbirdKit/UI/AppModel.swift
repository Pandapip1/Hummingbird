import Foundation
import SwiftOpenUI
import Observation
import os
import ATProtoKit
import ATAppSync
#if DEBUG && os(iOS)
import UIKit
#endif

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
    let subscriptionFeed: SubscriptionFeed
    let homeFeed: FeedModel
    let playbackQueue: PlaybackQueue
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

    func closeTab(_ id: BrowserTab.ID) {
        guard let index = contentTabs.firstIndex(where: { $0.id == id }) else { return }
        // Closing a sign-in tab abandons that sign-in.
        for route in contentTabs[index].history {
            if case .oauthAuthorization(let authorizationID) = route {
                oauthAuthorizations[authorizationID]?.cancel()
            }
        }
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
        let player = PlayerModel(stores: stores)
        tabPlayers[id] = player
        return player
    }

    var activePlayerForDebug: PlayerModel? { tabPlayers[activeTabID] }

    private func makeBrowserTab() -> BrowserTab {
        BrowserTab.hummingbirdTab(didChange: { [weak self] in self?.persistBrowserSession() })
    }

    private func persistBrowserSession() {
        // A tab holding a route that cannot outlive this launch, such as a
        // pending sign-in, is not restored.
        let tabs: [PersistedBrowserSession.Tab] = contentTabs.compactMap { tab in
            let history = tab.history.compactMap(PersistedRoute.init)
            guard history.count == tab.history.count else { return nil }
            return .init(id: tab.id, title: tab.title, history: history, historyIndex: tab.historyIndex)
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
         permissions suppliedPermissions: PermissionGate? = nil) {
        let defaults = stores.defaults
        let localProfileID: UUID
        if let suppliedLocalProfileID {
            localProfileID = suppliedLocalProfileID
        } else if let restored = stores.selectedLocalProfileID {
            localProfileID = restored
        } else {
            localProfileID = UUID()
            defaults.set(localProfileID.uuidString, forKey: AppDataStores.localProfileIDKey)
        }
        let credentialStore = stores.credentialStore
        let storage = stores.storage
        // Opening the profile reads (or creates) this instance's identity keys
        // in the credential store. A store that refuses them leaves the
        // profile without peer messaging; the reason is kept and shown rather
        // than reported later as a generic "unavailable".
        let profileRegistry: AppSyncProfileRegistry?
        var peerService: AppSyncPeerService?
        var peerServiceFailure: (any Error)?
        do {
            let registry = try AppSyncProfileRegistry(
                credentialStore: credentialStore, storageDirectory: stores.appSyncDirectory
            )
            profileRegistry = registry
            do {
                peerService = try registry.ensureProfile(
                    id: localProfileID, migrateLegacyIdentity: true
                ).peerService
            } catch {
                peerServiceFailure = error
            }
        } catch {
            profileRegistry = nil
            peerServiceFailure = error
        }
        let localNetworkSyncEnabled = suppliedLocalNetworkSyncEnabled
            ?? defaults.bool(forKey: Self.localNetworkSyncEnabledKey)
        let storagePrefix = "profile.\(localProfileID.uuidString.lowercased())."
        let profileChanges = ProfileChangeStore(
            storageDirectory: stores.profileSyncDirectory,
            signer: try? peerService?.peer.mutationSigner()
        )
        do {
            _ = try profileChanges.activate(localProfileID: localProfileID)
        } catch {
            assertionFailure("Could not create the local profile: \(error)")
        }
        let plugins = PluginManager(
            installed: persistence.plugins, profileChanges: profileChanges,
            storage: storage, credentialStore: credentialStore,
            storageName: storagePrefix + "plugins", credentialNamespace: storagePrefix
        )
        let library = LibraryStore(
            snapshot: persistence.library, profileChanges: profileChanges,
            storage: storage, storagePrefix: storagePrefix
        )
        let platform = PlatformService(
            plugins: plugins, storage: storage, detailsCacheStorageName: storagePrefix + "details_cache"
        )
        self.stores = stores
        self.plugins = plugins
        self.localProfileID = localProfileID
        self.library = library
        self.platform = platform
        self.playbackQueue = PlaybackQueue(
            storage: storage, storageName: storagePrefix + "playback_queue", restored: persistence.playbackQueue
        )
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
                conceal: { profileRegistry?.concealAll() }
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
        self.homeFeed = FeedModel(
            initialItems: library.homeCache.map(ContentItem.init(saved:)),
            report: { [platform] error, runtime in
                platform.surface(error, pluginID: runtime.id)
            },
            didUpdate: { [weak library] items in library?.updateHomeCache(items) }
        )
        for tab in contentTabs { tab.onChange { [weak self] in self?.persistBrowserSession() } }
        oauthTabPresenter?.host = self
        // A restored or synced setting is applied without touching the
        // network here: the gate explains it before the system can prompt.
        let localNetworkSync = self.localNetworkSync
        Task { await localNetworkSync.applyStoredSetting() }
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
                playbackQueue: load(PersistedPlaybackQueue.self, "playback_queue"),
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

#if DEBUG && os(iOS)
/// Marks frames that arrive 250 ms or more late, in debug builds, as
/// `RenderStall` signpost events (Instruments: os_signpost, category
/// `performance`) and log entries carrying what the app was doing. Instruments'
/// Hangs and Hitches instruments and MetricKit hang diagnostics give the
/// stacks; this adds app context they cannot know.
@MainActor
private final class RenderStallMonitor: NSObject {
    static let shared = RenderStallMonitor()
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
        let milliseconds = Int((gap * 1_000).rounded())
        let state = (context?() ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        OSSignposter.performance.emitEvent("RenderStall", "ms=\(milliseconds)")
        // The route can name a URL, so the state is private.
        Logger.performance.notice("render_stall ms=\(milliseconds) \(state)")
    }
}
#endif

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
