import Foundation
import SwiftOpenUI
import Observation

/// Owns the long-lived services and wires them together.
@MainActor
@Observable
final class AppModel {
    let plugins: PluginManager
    let library: LibraryStore
    let platform: PlatformService
    let subscriptionFeed: SubscriptionFeed
    let homeFeed: FeedModel
    let playbackQueue: PlaybackQueue
    let searchHistory: SearchHistory
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

    init() {
        let plugins = PluginManager()
        let library = LibraryStore()
        let platform = PlatformService(plugins: plugins)
        self.plugins = plugins
        self.library = library
        self.platform = platform
        self.playbackQueue = PlaybackQueue()
        self.searchHistory = SearchHistory()
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
        await homeFeed.reload(sources: platform.homeSources())
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

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
