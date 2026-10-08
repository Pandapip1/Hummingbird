import Foundation
import SwiftOpenUI
import Observation
#if os(iOS)
import AVFoundation
#endif

enum AppTab: Hashable { case home, subscriptions, search, library, sources }

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
    var selectedTab: AppTab = .home
    var incomingCredentialPairing: CredentialPairingRequest?

    /// The pinned, uncloseable tab holding the five bottom-tab sections. It
    /// has no history of its own (see `BrowserTab`'s doc comment) — only its
    /// `id` is used, to tell `activeTabID` apart from an ordinary content tab.
    let pinnedTab = BrowserTab.hummingbirdTab(isPinned: true)
    /// Ordinary browser tabs opened from `Route`-browsing content (a video, a
    /// channel, a playlist, a plugin page). Order is tab-strip/switcher order.
    var contentTabs: [BrowserTab] = []
    var activeTabID: BrowserTab.ID

    var activeTab: BrowserTab {
        contentTabs.first { $0.id == activeTabID } ?? pinnedTab
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

    func closeTab(_ id: BrowserTab.ID) {
        guard id != pinnedTab.id else { return }
        guard let index = contentTabs.firstIndex(where: { $0.id == id }) else { return }
        contentTabs.remove(at: index)
        guard activeTabID == id else { return }
        // Land on a neighboring content tab if one remains, else back to pinned.
        activeTabID = contentTabs[safe: index]?.id ?? contentTabs[safe: index - 1]?.id ?? pinnedTab.id
    }

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
        self.activeTabID = pinnedTab.id
        self.subscriptionFeed = SubscriptionFeed(library: library, plugins: plugins, platform: platform)
        self.homeFeed = FeedModel(
            initialItems: library.homeCache.map(ContentItem.init(saved:)),
            report: { [platform] error, runtime in
                platform.surface(error, pluginID: runtime.id)
            },
            didUpdate: { [weak library] items in library?.updateHomeCache(items) }
        )
        #if os(iOS)
        // Playback continues with the screen locked and in Picture in Picture.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
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
