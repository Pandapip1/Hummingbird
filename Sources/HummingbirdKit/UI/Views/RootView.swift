import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var loginTarget: LoginTarget?

    var body: some View {
        @Bindable var app = model
        @Bindable var plugins = model.plugins
        Group {
            if app.activeTabID == app.pinnedTab.id {
                PinnedTabView()
            } else {
                BrowserTabContentView(tab: app.activeTab)
            }
        }
        // Browser-style tab chrome is desktop-shaped here: native toolbar
        // navigation controls at the leading edge and tabs in the flexible
        // principal region, the same SwiftUI structure used by AppKit on
        // macOS. iOS keeps its ordinary tab-switcher treatment.
        #if !os(iOS) && !os(tvOS)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                BrowserHistoryControls(tab: app.activeTab)
            }
            ToolbarItem(placement: .principal) {
                TabStripView()
            }
        }
        #endif
        .overlay {
            if let loginTarget {
                LoginSheet(pluginID: loginTarget.value) { self.loginTarget = nil }
            }
        }
        .overlay(alignment: .top) { ToastBanner() }
        .sheet(item: $plugins.pendingCaptcha) { request in CaptchaSheet(request: request) }
        .alert("Login required", isPresented: loginBinding, presenting: model.plugins.pendingLogin) { id in
            Button("Log in") { loginTarget = LoginTarget(value: id); model.plugins.pendingLogin = nil }
            Button("Not now", role: .cancel) { model.plugins.pendingLogin = nil }
        } message: { id in
            Text("\(model.plugins.plugin(id)?.config.name ?? "This source") needs you to sign in to continue.")
        }
        .onChange(of: plugins.pendingDirectLogin) { _, id in
            if let id { loginTarget = LoginTarget(value: id); plugins.pendingDirectLogin = nil }
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { model.plugins.pendingLogin != nil }, set: { if !$0 { model.plugins.pendingLogin = nil } })
    }
}

/// The pinned tab: the app's five bottom-tab sections, unchanged from before
/// browser tabs existed. `Route`-browsing content opened from here (a video,
/// a channel, …) leaves this tab entirely and opens a new one.
@MainActor
private struct PinnedTabView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            HomeView().tabItem { Label("Home", systemImage: "house") }.tag(AppTab.home)
            SubscriptionsView().tabItem { Label("Subscriptions", systemImage: "rectangle.stack.person.crop") }.tag(AppTab.subscriptions)
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(AppTab.search)
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }.tag(AppTab.library)
            SourcesView().tabItem { Label("Sources", systemImage: "puzzlepiece.extension") }.tag(AppTab.sources)
        }
        .environment(\.openRoute, OpenRouteAction { route, title in app.openInNewTab(route, title: title) })
    }
}

/// An ordinary browser tab's content: whatever `Route` it's currently showing,
/// with its own back/forward (this tab's own linear history, not a
/// `NavigationStack` — there's no "forward" in one of those once you've gone
/// back). Opening further `Route`-browsing content from here extends this
/// same tab's history rather than opening yet another tab.
@MainActor
struct BrowserTabContentView: View {
    let tab: BrowserTab

    var body: some View {
        Group {
            if let route = tab.current {
                RouteContent(route: route)
                    .id(tab.historyIndexIdentity)
            } else {
                ContentUnavailableView("Nothing here", systemImage: "square.dashed")
            }
        }
        .environment(\.openRoute, OpenRouteAction { route, title in tab.push(route, title: title) })
    }
}

/// The current browser tab's own history, placed in the desktop window
/// toolbar rather than repeated inside every route's content.
@MainActor
private struct BrowserHistoryControls: View {
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 4) {
            Button { tab.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
                .accessibilityLabel("Back")
            Button { tab.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
                .accessibilityLabel("Forward")
        }
    }
}

/// Safari/Epiphany-style tab strip: the pinned tab's chip first (not
/// closable), then each open content tab in order.
@MainActor
private struct TabStripView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // The strip claims all available header width. Each tab gets an equal
        // share while they fit; its 150-point minimum keeps labels usable, at
        // which point the horizontal scroller takes over.
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                TabChip(title: "Home", systemImage: "house.fill", isActive: app.activeTabID == app.pinnedTab.id,
                        onSelect: { app.activeTabID = app.pinnedTab.id }, onClose: nil)
                ForEach(app.contentTabs) { tab in
                    TabChip(title: tab.title, systemImage: nil, isActive: app.activeTabID == tab.id,
                            onSelect: { app.activeTabID = tab.id },
                            onClose: { app.closeTab(tab.id) })
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
private struct TabChip: View {
    let title: String
    let systemImage: String?
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 150, maxWidth: .infinity)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

private extension BrowserTab {
    /// `.id()` key for `RouteContent` so SwiftUI tears down and rebuilds the
    /// screen on back/forward — these are different pages with different
    /// identity, not the same view updating in place.
    var historyIndexIdentity: Int { historyIndex }
}

/// Identifiable wrapper so a plugin id can drive a sheet.
struct LoginTarget: Identifiable, Hashable {
    let value: String
    var id: String { value }
}

@MainActor
struct ToastBanner: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let t = app.plugins.toast {
            Text(t)
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if app.plugins.toast == t { withAnimation { app.plugins.toast = nil } }
                }
        }
    }
}

@MainActor
struct CaptchaSheet: View {
    @Environment(AppModel.self) private var app
    let request: PluginManager.CaptchaRequest

    var body: some View {
        if let plugin = app.plugins.plugin(request.pluginID),
           let spec = WebAuthSpec.captcha(for: plugin.config, url: request.url, body: request.body) {
            WebAuthSheet(spec: spec) { result in
                if let result { app.plugins.saveCaptcha(result, pluginID: request.pluginID) }
                else { app.plugins.pendingCaptcha = nil }
            }
        } else {
            ContentUnavailableView("Captcha unavailable", systemImage: "xmark.octagon",
                                   description: Text("The plugin did not provide a page to solve."))
        }
    }
}

@MainActor
struct LoginSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let pluginID: String
    var onClose: (() -> Void)?

    init(pluginID: String, onClose: (() -> Void)? = nil) {
        self.pluginID = pluginID
        self.onClose = onClose
    }

    var body: some View {
        // Capture the action while this sheet's environment is active. The
        // authentication callback may run later, after an async cookie read.
        let dismissSheet = dismiss
        Group {
            if let plugin = app.plugins.plugin(pluginID), let spec = WebAuthSpec.login(for: plugin.config) {
                WebAuthSheet(spec: spec) { result in
                    if let result { app.plugins.saveAuth(result, pluginID: pluginID) }
                    if let onClose { onClose() } else { dismissSheet() }
                }
            } else {
                VStack {
                    ContentUnavailableView("Login unavailable", systemImage: "person.crop.circle.badge.xmark",
                                           description: Text("This plugin does not support signing in."))
                    Button("Close") {
                        if let onClose { onClose() } else { dismissSheet() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}
