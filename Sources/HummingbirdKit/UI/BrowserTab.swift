import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif
import Observation

/// One open browser tab: a self-contained, linear back/forward history of
/// `Route`s, the way a real browser tab works — not a `NavigationStack`,
/// which has no notion of "forward" once you've gone back.
///
/// The app's five bottom-tab sections (Home, Subscriptions, Search, Library,
/// Sources) live in a single pinned tab instead, which has no history of its
/// own: `AppModel.pinnedTab` is a `BrowserTab` only so it can share `id`/
/// `isPinned` bookkeeping with ordinary tabs, but its `history` stays empty
/// and nothing pushes onto it. See the "browser-style tabs" TODO entry.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    let isPinned: Bool
    private(set) var history: [Route] = []
    private(set) var historyIndex: Int = -1
    var title: String = "New Tab"

    init(id: UUID = UUID(), isPinned: Bool = false) {
        self.id = id
        self.isPinned = isPinned
    }

    var current: Route? { history.indices.contains(historyIndex) ? history[historyIndex] : nil }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    /// Push a new route. Ordinary browser semantics: anything ahead of the
    /// current position (reachable by "forward") is discarded, same as
    /// navigating a web page away from a back-visited page.
    func push(_ route: Route, title: String? = nil) {
        if historyIndex < history.count - 1 { history.removeLast(history.count - 1 - historyIndex) }
        history.append(route)
        historyIndex = history.count - 1
        self.title = title ?? Self.placeholderTitle(for: route)
    }

    func goBack() { guard canGoBack else { return }; historyIndex -= 1 }
    func goForward() { guard canGoForward else { return }; historyIndex += 1 }

    /// Called by a pushed screen once it knows its own title (e.g. a video's
    /// real name after loading, vs. the placeholder guessed from the route
    /// at push time).
    func reportTitle(_ title: String) {
        guard !title.isEmpty, current != nil else { return }
        self.title = title
    }

    fileprivate static func placeholderTitle(for route: Route) -> String {
        switch route {
        case .item(let item): return item.name.isEmpty ? "Video" : item.name
        case .content: return "Loading…"
        case .channel: return "Channel"
        case .playlist: return "Playlist"
        case .plugin: return "Plugin"
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
