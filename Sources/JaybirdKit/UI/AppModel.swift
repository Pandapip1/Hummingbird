import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif
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
    var selectedTab: AppTab = .home

    init() {
        let plugins = PluginManager()
        let library = LibraryStore()
        let platform = PlatformService(plugins: plugins)
        self.plugins = plugins
        self.library = library
        self.platform = platform
        self.subscriptionFeed = SubscriptionFeed(library: library, plugins: plugins, platform: platform)
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
}
