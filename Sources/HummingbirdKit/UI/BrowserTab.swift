import Foundation
import SwiftOpenUI
import DynamicTabbingKit

/// One open browser tab: a self-contained, linear back/forward history of
/// `Route`s, the way a real browser tab works — not a `NavigationStack`,
/// which has no notion of "forward" once you've gone back.
///
/// The app's five bottom-tab sections (Home, Subscriptions, Search, Library,
/// Sources) live in a single pinned tab instead, which has no history of its
/// own: `AppModel.pinnedTab` is a `BrowserTab` only so it can share `id`/
/// `isPinned` bookkeeping with ordinary tabs, but its `history` stays empty
/// and nothing pushes onto it. See the "browser-style tabs" TODO entry.
typealias BrowserTab = DynamicTab<Route>

extension DynamicTab where Page == Route {
    static func hummingbirdTab(id: UUID = UUID(), isPinned: Bool = false) -> DynamicTab<Route> {
        DynamicTab(id: id, isPinned: isPinned, defaultTitle: placeholderTitle)
    }

    private static func placeholderTitle(for route: Route) -> String {
        switch route {
        case .item(let item): return item.name.isEmpty ? "Video" : item.name
        case .content: return "Loading…"
        case .channel: return "Channel"
        case .playlist: return "Playlist"
        case .plugin: return "Plugin"
        default: return "Page"
        }
    }
}

/// An action, carried in the environment, that opens a `Route` somewhere
/// appropriate for where it's called from: a new browser tab when called
/// from the pinned tab, or the current tab's own history when called from
/// within one. Mirrors `Route`-browsing call sites that used to push a
/// `NavigationLink(value:)` directly onto a single shared `NavigationStack`.
struct OpenRouteAction {
    let action: (Route, String?) -> Void
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
