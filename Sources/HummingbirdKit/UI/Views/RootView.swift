import Foundation
import DebugKit
import DynamicTabbingKit
import SwiftOpenUI
#if os(macOS) && !BACKEND_GTK
import AppKit
#endif

@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var loginTarget: LoginTarget?
    @State private var showingTabOverview = false

    var body: some View {
        @Bindable var app = model
        @Bindable var plugins = model.plugins
        BrowserTabContainer(items: browserTabItems, selection: activeTabBinding,
                            onClose: { app.closeTab($0) }, overviewPresented: $showingTabOverview) { item in
            BrowserTabContentView(tab: browserTab(for: item.id), showingTabOverview: $showingTabOverview)
        }
        #if !os(macOS)
        .fullScreenCover(isPresented: $showingTabOverview) {
            MobileTabOverview(isPresented: $showingTabOverview)
                .environment(model)
        }
        #endif
        .navigationTitle(windowTitle)
        // Browser-style tab chrome: native toolbar navigation controls at the
        // leading edge on desktop. macOS seats the tab strip below the toolbar
        // via NSTitlebarAccessoryViewController (Safari-style separate row);
        // other desktop platforms keep tabs in the .principal toolbar slot.
        .toolbar {
            #if !os(iOS) && !os(tvOS)
            BrowserTopToolbar(tab: app.activeTab) { showingTabOverview = true }
            #endif
        }
        #if !os(iOS) && !os(tvOS)
        .background {
            #if os(macOS) && !BACKEND_GTK
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
        .task {
            let overview = $showingTabOverview
            DebugServer.shared.registerAction("toggleTabOverview") { overview.wrappedValue.toggle() }
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { model.plugins.pendingLogin != nil }, set: { if !$0 { model.plugins.pendingLogin = nil } })
    }

    private var windowTitle: String {
        model.activeTab.title
    }

    private var browserTabItems: [BrowserTabItem] {
        model.contentTabs.map { BrowserTabItem(id: $0.id, title: $0.title) }
    }

    private var activeTabBinding: Binding<UUID> {
        Binding(get: { model.activeTabID }, set: { model.activeTabID = $0 })
    }

    private func browserTab(for id: UUID) -> BrowserTab {
        model.contentTabs.first { $0.id == id } ?? model.activeTab
    }
}

@MainActor
struct AppSectionMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            sectionButton("Home", systemImage: "house", route: .home)
            sectionButton("Subscriptions", systemImage: "rectangle.stack.person.crop", route: .subscriptions)
            sectionButton("Search", systemImage: "magnifyingglass", route: .search)
            sectionButton("Library", systemImage: "books.vertical", route: .library)
            sectionButton("Sources", systemImage: "puzzlepiece.extension", route: .sources)
        } label: {
            Image(systemName: "plus.square")
        }
        .accessibilityLabel("Open section in new tab")
    }

    private func sectionButton(_ title: String, systemImage: String, route: Route) -> some View {
        Button { app.openSection(route, title: title) } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

/// An ordinary browser tab's content: whatever `Route` it's currently showing,
/// with its own back/forward (this tab's own linear history, not a
/// `NavigationStack` — there's no "forward" in one of those once you've gone
/// back). Opening further `Route`-browsing content from here extends this
/// same tab's history rather than opening yet another tab.
@MainActor
struct BrowserTabContentView: View {
    @Environment(AppModel.self) private var app
    let tab: BrowserTab
    @Binding var showingTabOverview: Bool

    var body: some View {
        Group {
            if let route = tab.current {
                RouteContent(
                    route: route,
                    player: app.player(forTab: tab.id),
                    browserToolbar: BrowserToolbarContext(
                        tab: tab,
                        showTabOverview: { showingTabOverview = true }
                    ),
                    shouldKeepPlaybackWhenHidden: {
                        tab.current == route && app.contentTabs.contains { $0.id == tab.id }
                    }
                )
                    .id(tab.historyIndexIdentity)
                    #if os(iOS)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        MobileBrowserToolbar(showingTabOverview: $showingTabOverview)
                    }
                    #endif
            } else {
                NavigationStack {
                    ContentUnavailableView("New Tab", systemImage: "plus.square", description: Text("Choose a section from the menu."))
                        .navigationTitle("New Tab")
                }
                #if os(iOS)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MobileBrowserToolbar(showingTabOverview: $showingTabOverview)
                }
                #endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.openRoute, OpenRouteAction { route, title in tab.push(route, title: title) })
    }
}

#if !os(iOS)
@MainActor
struct BrowserTopToolbar: ToolbarContent {
    let tab: BrowserTab
    let showTabOverview: () -> Void

    var body: some ToolbarContent {
        #if os(tvOS)
        ToolbarItemGroup(placement: .navigation) {
            AppSectionMenu()
            BrowserBackButton(tab: tab)
            BrowserForwardButton(tab: tab)
        }
        #if !os(macOS)
        ToolbarItem(placement: .primaryAction) {
            BrowserTabOverviewButton(action: showTabOverview)
        }
        #endif
        #else
        ToolbarItemGroup(placement: .navigation) {
            AppSectionMenu()
            BrowserBackButton(tab: tab)
            BrowserForwardButton(tab: tab)
        }
        #if !os(macOS)
        ToolbarItem(placement: .primaryAction) {
            BrowserTabOverviewButton(action: showTabOverview)
        }
        #endif
        #endif
    }
}
#endif

@MainActor
struct BrowserBackButton: View {
    let tab: BrowserTab

    var body: some View {
        Button { tab.goBack() } label: { Image(systemName: "chevron.left") }
            .disabled(!tab.canGoBack)
            .accessibilityLabel("Back")
    }
}

@MainActor
struct BrowserForwardButton: View {
    let tab: BrowserTab

    var body: some View {
        Button { tab.goForward() } label: { Image(systemName: "chevron.right") }
            .disabled(!tab.canGoForward)
            .accessibilityLabel("Forward")
    }
}

@MainActor
struct BrowserTabOverviewButton: View {
    @Environment(AppModel.self) private var app
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(tabCountLabel, systemImage: "square.on.square")
        }
        .accessibilityLabel("Show \(tabCountLabel)")
    }

    private var tabCountLabel: String {
        "\(app.contentTabs.count) \(app.contentTabs.count == 1 ? "tab" : "tabs")"
    }
}

struct BrowserToolbarContext {
    let tab: BrowserTab
    let showTabOverview: () -> Void
}

private struct BrowserTopToolbarModifier: ViewModifier {
    let context: BrowserToolbarContext?

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.toolbar {
            if let context {
                BrowserTopToolbar(tab: context.tab, showTabOverview: context.showTabOverview)
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    func browserTopToolbar(_ context: BrowserToolbarContext?) -> some View {
        modifier(BrowserTopToolbarModifier(context: context))
    }
}

@MainActor
private struct BrowserTabStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        BrowserTabBar(
            items: app.contentTabs.map { BrowserTabItem(id: $0.id, title: $0.title) },
            selection: Binding(
                get: { app.activeTabID },
                set: { app.activeTabID = $0 }
            ),
            onClose: { app.closeTab($0) }
        )
    }
}

#if os(macOS) && !BACKEND_GTK
private final class HummingbirdTabBarAccessoryViewController: NSTitlebarAccessoryViewController {}

/// Owns the tab strip as window chrome. SwiftUI representables can be rebuilt
/// or briefly overlap during navigation, so installation is reconciled at the
/// NSWindow level rather than treating each representable as the accessory's
/// owner.
@MainActor
final class WindowTabBarAccessoryManager {
    // BrowserTabBar's label, tab padding, capsule padding, and outer padding
    // require about 37 points at the default macOS font size. Leave one point
    // for pixel rounding rather than clipping the capsule's lower edge.
    static let height: CGFloat = 38

    private weak var window: NSWindow?
    private let accessory = HummingbirdTabBarAccessoryViewController()
    private let hosting: NSHostingController<AnyView>
    private var owners = Set<UUID>()
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow, app: AppModel) {
        self.window = window
        hosting = NSHostingController(rootView: AnyView(BrowserTabStrip().environment(app)))
        accessory.view = hosting.view
        accessory.layoutAttribute = .bottom
        accessory.fullScreenMinHeight = 0
        hosting.view.autoresizingMask = [.width]

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.reconcile() }
            },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) {
                [weak self] _ in self?.reconcileAfterFullScreenTransition()
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) {
                [weak self] _ in self?.reconcileAfterFullScreenTransition()
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isUnused: Bool { owners.isEmpty }

    func attach(owner: UUID, app: AppModel) {
        owners.insert(owner)
        hosting.rootView = AnyView(BrowserTabStrip().environment(app))
        reconcile()
    }

    func detach(owner: UUID) {
        owners.remove(owner)
        guard owners.isEmpty, let window else { return }
        if let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    func reconcile() {
        guard !owners.isEmpty, let window, window.styleMask.contains(.titled) else { return }
        // Remove abandoned Hummingbird accessories left by a replaced SwiftUI
        // coordinator before ensuring this manager's accessory is installed.
        for index in window.titlebarAccessoryViewControllers.indices.reversed() {
            let candidate = window.titlebarAccessoryViewControllers[index]
            if candidate is HummingbirdTabBarAccessoryViewController, candidate !== accessory {
                window.removeTitlebarAccessoryViewController(at: index)
            }
        }
        let width = max(0, window.contentLayoutRect.width)
        hosting.view.frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        accessory.view.frame = hosting.view.frame
        if !window.titlebarAccessoryViewControllers.contains(where: { $0 === accessory }) {
            window.addTitlebarAccessoryViewController(accessory)
        }
        window.contentView?.needsLayout = true
    }

    private nonisolated func reconcileAfterFullScreenTransition() {
        // AppKit can report its old content-layout rect until the following
        // main-run-loop turn after a fullscreen transition.
        DispatchQueue.main.async { [weak self] in self?.reconcile() }
    }
}

@MainActor
private final class WindowTabBarAccessoryRegistry {
    static let shared = WindowTabBarAccessoryRegistry()
    private struct Entry { weak var window: NSWindow?; let manager: WindowTabBarAccessoryManager }
    private var entries: [ObjectIdentifier: Entry] = [:]

    func manager(for window: NSWindow, app: AppModel) -> WindowTabBarAccessoryManager {
        purgeReleasedWindows()
        let key = ObjectIdentifier(window)
        if let entry = entries[key], entry.window === window { return entry.manager }
        let manager = WindowTabBarAccessoryManager(window: window, app: app)
        entries[key] = Entry(window: window, manager: manager)
        return manager
    }

    func releaseManager(for window: NSWindow) {
        let key = ObjectIdentifier(window)
        if entries[key]?.manager.isUnused == true { entries[key] = nil }
        purgeReleasedWindows()
    }

    private func purgeReleasedWindows() {
        entries = entries.filter { $0.value.window != nil }
    }
}

/// Mounts `BrowserTabStrip` as a window-managed titlebar accessory so it
/// occupies its own row below the toolbar, matching Safari and iTerm2.
@MainActor
private struct TabBarAccessoryInstaller: NSViewRepresentable {
    let app: AppModel

    func makeNSView(context: Context) -> _WindowObserverView {
        let v = _WindowObserverView()
        v.coordinator = context.coordinator
        return v
    }

    func updateNSView(_ nsView: _WindowObserverView, context: Context) {
        context.coordinator.app = app
        context.coordinator.move(to: nsView.window)
    }

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    static func dismantleNSView(_ nsView: _WindowObserverView, coordinator: Coordinator) {
        coordinator.move(to: nil)
        nsView.coordinator = nil
    }

    @MainActor
    final class Coordinator {
        var app: AppModel
        private let owner = UUID()
        private weak var installedWindow: NSWindow?

        init(app: AppModel) { self.app = app }

        func move(to window: NSWindow?) {
            if installedWindow !== window, let old = installedWindow {
                let registry = WindowTabBarAccessoryRegistry.shared
                let manager = registry.manager(for: old, app: app)
                manager.detach(owner: owner)
                registry.releaseManager(for: old)
            }
            guard let window else { installedWindow = nil; return }
            let manager = WindowTabBarAccessoryRegistry.shared.manager(for: window, app: app)
            manager.attach(owner: owner, app: app)
            installedWindow = window
        }
    }

    @MainActor
    final class _WindowObserverView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.move(to: window)
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
