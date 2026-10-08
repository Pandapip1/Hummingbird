import Foundation
import BrowserTabs
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif
#if os(macOS)
import AppKit
#endif

@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var loginTarget: LoginTarget?
    @State private var showingTabOverview = false

    var body: some View {
        @Bindable var app = model
        @Bindable var plugins = model.plugins
        Group {
            if app.activeTabID == app.pinnedTab.id {
                PinnedTabView()
                    .environment(\.openRoute, OpenRouteAction { route, title in app.openInNewTab(route, title: title) })
            } else {
                BrowserTabContentView(tab: app.activeTab)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if horizontalSizeClass != nil {
                MobileBrowserToolbar(showingTabOverview: $showingTabOverview)
            }
        }
        .fullScreenCover(isPresented: $showingTabOverview) {
            MobileTabOverview(isPresented: $showingTabOverview)
                .environment(model)
        }
        .navigationTitle(windowTitle)
        // Browser-style tab chrome: native toolbar navigation controls at the
        // leading edge on desktop. macOS seats the tab strip below the toolbar
        // via NSTitlebarAccessoryViewController (Safari-style separate row);
        // other desktop platforms keep tabs in the .principal toolbar slot.
        #if !os(iOS) && !os(tvOS)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                BrowserHistoryControls(tab: app.activeTab)
            }
            #if !os(macOS)
            ToolbarItem(placement: .principal) {
                BrowserTabStrip()
            }
            #endif
        }
        .background {
            #if os(macOS)
            TabBarAccessoryInstaller(app: model).frame(width: 0, height: 0)
            #endif
        }
        #endif
        .overlay {
            if let loginTarget {
                LoginSheet(pluginID: loginTarget.value) { self.loginTarget = nil }
            }
        }
        .overlay {
            if let request = app.incomingCredentialPairing {
                PairedDeviceLoginSheet(request: request) { app.incomingCredentialPairing = nil }
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

    private var windowTitle: String {
        guard model.activeTabID == model.pinnedTab.id else { return model.activeTab.title }
        switch model.selectedTab {
        case .home: return "Home"
        case .subscriptions: return "Subscriptions"
        case .search: return "Search"
        case .library: return "Library"
        case .sources: return "Sources"
        }
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
        .tabViewStyle(.sidebarAdaptable)
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
                PinnedTabView()
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

@MainActor
private struct BrowserTabStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        BrowserTabBar(
            items: [BrowserTabItem(id: app.pinnedTab.id, title: "Home", isPinned: true)]
                + app.contentTabs.map { BrowserTabItem(id: $0.id, title: $0.title) },
            selection: Binding(
                get: { app.activeTabID },
                set: { app.activeTabID = $0 }
            ),
            onClose: { app.closeTab($0) }
        )
    }
}

#if os(macOS)
/// Mounts `BrowserTabStrip` as an `NSTitlebarAccessoryViewController` so it
/// occupies its own row below the window toolbar, matching Safari's layout.
@MainActor
private struct TabBarAccessoryInstaller: NSViewRepresentable {
    let app: AppModel

    func makeNSView(context: Context) -> _WindowObserverView {
        let v = _WindowObserverView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: _WindowObserverView, context: Context) {
        if let window = nsView.window {
            context.coordinator.installIfNeeded(in: window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    @MainActor
    final class Coordinator {
        let app: AppModel
        private weak var installedWindow: NSWindow?
        private var accessory: NSTitlebarAccessoryViewController?
        private var retainedHosting: AnyObject?

        init(app: AppModel) { self.app = app }

        func installIfNeeded(in window: NSWindow) {
            guard installedWindow !== window else { return }
            let hc = NSHostingController(rootView: AnyView(
                BrowserTabStrip().environment(app)
            ))
            // Fix the height so GeometryReader inside TabStripView gets a
            // finite vertical proposal. The accessory VC manages width itself.
            hc.view.frame = NSRect(x: 0, y: 0, width: window.frame.width, height: 28)
            let vc = NSTitlebarAccessoryViewController()
            vc.view = hc.view
            vc.layoutAttribute = .bottom
            vc.fullScreenMinHeight = 0
            window.addTitlebarAccessoryViewController(vc)
            installedWindow = window
            accessory = vc
            retainedHosting = hc
        }
    }

    @MainActor
    final class _WindowObserverView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.installIfNeeded(in: window) }
        }
    }
}
#endif

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
        .background(.background)
    }
}

/// Runs a new isolated login for a QR pairing request. Credentials already
/// stored on the scanning device are deliberately neither loaded nor changed.
@MainActor
private struct PairedDeviceLoginSheet: View {
    @Environment(AppModel.self) private var app
    let request: CredentialPairingRequest
    let onClose: () -> Void
    @State private var config: PluginConfig?
    @State private var error: String?
    @State private var sending = false
    @State private var verified = false
    @State private var remoteAccepted = false

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 16) {
                    ContentUnavailableView("Login unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                    Button("Close", action: onClose)
                }
            } else if !verified {
                VStack(spacing: 20) {
                    Text("Verify this sign-in").font(.title2)
                    Text(request.verificationEmoji)
                        .font(.title2)
                        .accessibilityLabel("Verification emoji: \(request.verificationEmoji)")
                    Text("Check that these emoji match the TV. Continue only if every emoji is the same.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("They don’t match", role: .destructive) {
                            Task { try? await request.reject(); onClose() }
                        }
                        Button("They match") { verified = true }
                    }
                }
                .padding()
            } else if !remoteAccepted {
                VStack(spacing: 16) {
                    ProgressView("Waiting for the TV to confirm…")
                    Button("Cancel pairing", role: .cancel) {
                        Task { try? await request.reject(); onClose() }
                    }
                }
            } else if let config, let spec = WebAuthSpec.login(for: config) {
                WebAuthSheet(spec: spec) { auth in
                    guard let auth else { onClose(); return }
                    sending = true
                    Task {
                        do {
                            try await request.send(auth)
                            onClose()
                        } catch {
                            self.error = error.localizedDescription
                            sending = false
                        }
                    }
                }
                .overlay {
                    if sending { ProgressView("Sending credentials…") }
                }
            } else {
                ProgressView("Preparing secure login…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: verified && remoteAccepted) {
            guard verified, remoteAccepted, config == nil, error == nil else { return }
            do {
                let fetched = try await app.plugins.fetchConfig(from: request.pluginSourceURL)
                guard fetched.id == request.pluginID else {
                    throw PairingError.invalidRequest
                }
                config = fetched
            }
            catch { self.error = error.localizedDescription }
        }
        .task {
            while !Task.isCancelled && !remoteAccepted && error == nil {
                do {
                    switch try await request.remoteStatus() {
                    case .accepted:
                        remoteAccepted = true
                        return
                    case .rejected:
                        error = "The TV reported that the verification emoji did not match."
                        return
                    case .waiting:
                        break
                    }
                } catch {
                    // A transient LAN failure must not dismiss a login the user
                    // has not yet accepted or rejected.
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
