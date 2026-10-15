import Foundation
import DebugKit
import DynamicTabbingKit
import SwiftOpenUI
import ATAppSync
@MainActor
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var loginTarget: LoginTarget?
    @State private var showingTabOverview = false

    var body: some View {
        @Bindable var app = model
        @Bindable var plugins = model.plugins
        BrowserTabContainer(items: browserTabItems, selection: activeTabBinding,
                            onClose: { app.closeTab($0) }, overviewPresented: $showingTabOverview,
                            newTabControl: {
                                NewTabDestinationMenu { route, title in
                                    app.openSection(route, title: title)
                                }
                            }) { item in
            BrowserTabContentView(tab: browserTab(for: item.id), showingTabOverview: $showingTabOverview)
        }
        .navigationTitle(windowTitle)
        .browserWindowChrome(model: model, overviewPresented: $showingTabOverview)
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
        NewTabDestinationMenu { route, title in
            app.openSection(route, title: title)
        }
    }
}

/// Presents the useful destinations for a new tab. It deliberately has no
/// default action because a destination-less tab is not meaningful here.
@MainActor
struct NewTabDestinationMenu: View {
    let open: @MainActor @Sendable (Route, String) -> Void

    var body: some View {
        AdaptiveActionMenu(
            title: "Open section in new tab",
            systemImage: "plus",
            items: [
                AdaptiveMenuItem(id: "home", title: "Home", systemImage: "house", value: Route.home),
                AdaptiveMenuItem(id: "subscriptions", title: "Subscriptions", systemImage: "rectangle.stack.person.crop", value: Route.subscriptions),
                AdaptiveMenuItem(id: "search", title: "Search", systemImage: "magnifyingglass", value: Route.search),
                AdaptiveMenuItem(id: "library", title: "Library", systemImage: "books.vertical", value: Route.library),
                AdaptiveMenuItem(id: "sources", title: "Sources", systemImage: "puzzlepiece.extension", value: Route.sources),
                AdaptiveMenuItem(id: "settings", title: "Settings", systemImage: "gearshape", value: Route.settings),
            ]
        ) { route, title in
            open(route, title)
        }
        .keyboardShortcut("t")
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
                    .profileSwitcherToolbarItem()
                    .browserTabControls(overviewPresented: $showingTabOverview)
            } else {
                NavigationStack {
                    ContentUnavailableView("New Tab", systemImage: "plus.square", description: Text("Choose a section from the menu."))
                        .navigationTitle("New Tab")
                }
                .profileSwitcherToolbarItem()
                .browserTabControls(overviewPresented: $showingTabOverview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.openRoute, OpenRouteAction { route, title in tab.push(route, title: title) })
    }
}

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
            Label("Tabs", systemImage: "square.on.square")
                .labelsHidden()
        }
        .accessibilityLabel("Tabs")
        .accessibilityValue(tabCountLabel)
    }

    private var tabCountLabel: String {
        "\(app.contentTabs.count) \(app.contentTabs.count == 1 ? "tab" : "tabs")"
    }
}

struct BrowserToolbarContext {
    let tab: BrowserTab
    let showTabOverview: () -> Void
}

@MainActor
struct BrowserTabStrip: View {
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

/// Shares an existing local login when available, or captures a replacement in
/// an isolated browser. The transferred credential is never replicated.
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
    @State private var senderIdentity: AppSyncPeer?
    @State private var savedAuth: SourceAuth?
    @State private var useFreshLogin = false

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 16) {
                    ContentUnavailableView("Login unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                    Button("Close", action: onClose)
                }
            } else if !verified, let senderIdentity {
                VStack(spacing: 20) {
                    Text("Verify this sign-in").font(.title2)
                    pairingFingerprint("Sender (this device)", request.senderVerificationEmoji(senderIdentity))
                    pairingFingerprint("Receiver", request.receiverVerificationEmoji)
                    Text("Check that both labeled fingerprints match the TV. Continue only if every emoji is the same.")
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
            } else if !verified {
                ProgressView("Introducing this device…")
            } else if !remoteAccepted {
                VStack(spacing: 16) {
                    ProgressView("Waiting for the TV to confirm…")
                    Button("Cancel pairing", role: .cancel) {
                        Task { try? await request.reject(); onClose() }
                    }
                }
            } else if let savedAuth, !useFreshLogin {
                VStack(spacing: 16) {
                    Text("This profile already has a sign-in for \(config?.name ?? request.pluginID).")
                        .multilineTextAlignment(.center)
                    Button("Send saved sign-in") { deliver(savedAuth) }
                        .disabled(sending)
                    Button("Sign in again") { useFreshLogin = true }
                        .disabled(sending)
                    if sending { ProgressView("Sending credentials…") }
                }
                .padding()
            } else if let config, let spec = WebAuthSpec.login(for: config) {
                WebAuthSheet(spec: spec) { auth in
                    guard let auth else { onClose(); return }
                    deliver(auth)
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
                savedAuth = app.plugins.auth(for: request.pluginID)
            }
            catch { self.error = error.localizedDescription }
        }
        .task {
            do { senderIdentity = try await request.announceSender(peerService: app.peerService) }
            catch { self.error = error.localizedDescription; return }
            while !Task.isCancelled && !remoteAccepted && error == nil {
                do {
                    switch try await request.remoteStatus(peerService: app.peerService) {
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

    private func deliver(_ auth: SourceAuth) {
        sending = true
        Task {
            do {
                do {
                    try await request.send(auth)
                } catch {
                    // The QR endpoint is preferred and works without Internet.
                    // If the devices leave the same LAN, use the recipient's
                    // append-only encrypted peer messaging instead.
                    try await app.profileAccount.sendCredential(
                        auth, pluginID: request.pluginID,
                        sourceURL: request.pluginSourceURL, recipient: request.receiver
                    )
                }
                onClose()
            } catch {
                self.error = error.localizedDescription
                sending = false
            }
        }
    }

    private func pairingFingerprint(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).accessibilityLabel("\(label): \(value)")
        }
    }
}
