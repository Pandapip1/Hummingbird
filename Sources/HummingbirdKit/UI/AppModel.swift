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
        let player = PlayerModel()
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
        Storage.save(
            PersistedBrowserSession(tabs: tabs, activeTabID: activeTabID),
            name: "profile.\(localProfileID.uuidString.lowercased()).browser-session"
        )
    }

    @ObservationIgnored private var homeFeedPluginIDs: [String] = []

    init(persistence: AppPersistenceSnapshot = .empty,
         credentialStore: any CredentialStore = AuthKeychain.store,
         profileStorageDirectory: URL = Storage.directory.appendingPathComponent(
            "profile-sync", isDirectory: true
         ),
         // Holds the local-profile registry, instance inboxes and trust facts.
         // Every profile listed there is opened, and its identity keys read,
         // when local sync starts, so tests must never use the real one.
         appSyncStorageDirectory: URL = Storage.directory,
         localProfileID suppliedLocalProfileID: UUID? = nil,
         localNetworkSyncEnabled suppliedLocalNetworkSyncEnabled: Bool? = nil,
         permissions suppliedPermissions: PermissionGate? = nil) {
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
        // Opening the profile reads (or creates) this instance's identity keys
        // in the credential store. A store that refuses them leaves the
        // profile without peer messaging; the reason is kept and shown rather
        // than reported later as a generic "unavailable".
        let profileRegistry: AppSyncProfileRegistry?
        var peerService: AppSyncPeerService?
        var peerServiceFailure: (any Error)?
        do {
            let registry = try AppSyncProfileRegistry(
                credentialStore: credentialStore, storageDirectory: appSyncStorageDirectory
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
        self.peerServiceFailure = peerServiceFailure?.localizedDescription
        let permissions = suppliedPermissions ?? PermissionGate(
            system: PlatformPermissions(), ledger: FilePermissionLedger()
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
            localProfileID: localProfileID, changes: profileChanges, library: library, plugins: plugins,
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
            persist: { UserDefaults.standard.set($0, forKey: Self.localNetworkSyncEnabledKey) },
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
        self.subscriptionFeed = SubscriptionFeed(library: library, plugins: plugins, platform: platform)
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
