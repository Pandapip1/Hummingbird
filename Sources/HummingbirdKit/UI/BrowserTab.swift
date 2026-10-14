import Foundation
import SwiftOpenUI
import DynamicTabbingKit

/// One open browser tab: a self-contained, linear back/forward history of
/// `Route`s, the way a real browser tab works — not a `NavigationStack`,
/// which has no notion of "forward" once you've gone back.
///
/// App sections and content pages use the same tab/history model. Top-level
/// sections are opened from the app menu as ordinary, reusable tabs.
typealias BrowserTab = DynamicTab<Route>

struct PersistedBrowserSession: Codable, Sendable {
    struct Tab: Codable, Sendable {
        let id: UUID
        let title: String
        let history: [PersistedRoute]
        let historyIndex: Int
    }
    let tabs: [Tab]
    let activeTabID: UUID
}

enum PersistedRoute: Codable, Sendable {
    case home, subscriptions, manageSubscriptions, search, library, sources, settings, syncSettings
    case content(String), channel(String), playlist(String), plugin(String)

    init(_ route: Route) {
        switch route {
        case .home: self = .home
        case .subscriptions: self = .subscriptions
        case .manageSubscriptions: self = .manageSubscriptions
        case .search: self = .search
        case .library: self = .library
        case .sources: self = .sources
        case .content(let value): self = .content(value)
        case .item(let item): self = .content(item.openURL)
        case .channel(let value): self = .channel(value)
        case .playlist(let value): self = .playlist(value)
        case .plugin(let value): self = .plugin(value)
        case .settings: self = .settings
        case .syncSettings: self = .syncSettings
        }
    }

    var route: Route {
        switch self {
        case .home: .home
        case .subscriptions: .subscriptions
        case .manageSubscriptions: .manageSubscriptions
        case .search: .search
        case .library: .library
        case .sources: .sources
        case .settings: .settings
        case .syncSettings: .syncSettings
        case .content(let value): .content(value)
        case .channel(let value): .channel(value)
        case .playlist(let value): .playlist(value)
        case .plugin(let value): .plugin(value)
        }
    }
}

extension DynamicTab where Page == Route {
    static func hummingbirdTab(
        id: UUID = UUID(), isPinned: Bool = false, title: String = "New Tab",
        history: [Route] = [], historyIndex: Int? = nil,
        didChange: @escaping @MainActor () -> Void = {}
    ) -> DynamicTab<Route> {
        DynamicTab(
            id: id, isPinned: isPinned, title: title, history: history,
            historyIndex: historyIndex, defaultTitle: placeholderTitle, didChange: didChange
        )
    }

    private static func placeholderTitle(for route: Route) -> String {
        switch route {
        case .home: return "Home"
        case .subscriptions: return "Subscriptions"
        case .manageSubscriptions: return "Manage Subscriptions"
        case .search: return "Search"
        case .library: return "Library"
        case .sources: return "Sources"
        case .item(let item): return item.name.isEmpty ? "Video" : item.name
        case .content: return "Loading…"
        case .channel: return "Channel"
        case .playlist: return "Playlist"
        case .plugin: return "Plugin"
        case .settings: return "Settings"
        case .syncSettings: return "Sync"
        }
    }
}

/// An action, carried in the environment, that opens a `Route` somewhere
/// appropriate for where it's called from: a new browser tab when called
/// from the pinned tab, or the current tab's own history when called from
/// within one. Mirrors `Route`-browsing call sites that used to push a
/// `NavigationLink(value:)` directly onto a single shared `NavigationStack`.
struct OpenRouteAction: Sendable {
    let action: @MainActor @Sendable (Route, String?) -> Void
    @MainActor
    func callAsFunction(_ route: Route, title: String? = nil) { action(route, title) }
}

private struct OpenRouteKey: EnvironmentKey {
    // Overwritten by RootView; a no-op default only matters for previews/tests
    // that render a Route-browsing view without the full app environment.
    static let defaultValue = OpenRouteAction { _, _ in }
}

extension EnvironmentValues {
    var openRoute: OpenRouteAction {
        get { self[OpenRouteKey.self] }
        set { self[OpenRouteKey.self] = newValue }
    }
}
