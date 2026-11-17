import Foundation
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
                            onClose: { app.closeTab($0) },
                            onMove: { app.moveTab($0, to: $1) },
                            overviewPresented: $showingTabOverview,
                            onReopenClosedTab: app.closedTabs.isEmpty ? nil : { app.reopenClosedTab() },
                            newTabControl: {
                                NewTabDestinationMenu { route, title in
                                    app.openSection(route, title: title)
                                }
                            }) { item in
            ZStack {
                if let tab = browserTab(for: item.id) {
                    BrowserTabContentView(tab: tab)
                }
                if let loginTarget, loginTarget.tabID == item.id {
                    LoginSheet(pluginID: loginTarget.pluginID) { self.loginTarget = nil }
                }
            }
        }
        .browserTabControls { MobileBrowserToolbar(showingTabOverview: $showingTabOverview) }
        .navigationTitle(windowTitle)
        .browserWindowChrome(model: model, overviewPresented: $showingTabOverview)
        .overlay {
            if let request = app.incomingCredentialPairing {
                PairedDeviceLoginSheet(request: request) { app.incomingCredentialPairing = nil }
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let pluginID = plugins.pendingLogin {
                    LoginRequiredBanner(
                        sourceName: plugins.plugin(pluginID)?.config.name ?? "This source",
                        onLogin: { beginLogin(pluginID) },
                        onDismiss: { plugins.pendingLogin = nil }
                    )
                }
                ToastBanner()
            }
        }
        .sheet(item: $plugins.pendingCaptcha) { request in CaptchaSheet(request: request).sheetSize() }
        .permissionPrompts(model.permissions)
        .onChange(of: plugins.pendingDirectLogin) { _, id in
            if let id { beginLogin(id); plugins.pendingDirectLogin = nil }
        }
        .task {
            let overview = $showingTabOverview
            HummingbirdDebug.toggleTabOverviewAction = { overview.wrappedValue.toggle() }
        }
    }

    private func beginLogin(_ pluginID: String) {
        loginTarget = LoginTarget(pluginID: pluginID, tabID: model.activeTabID)
        model.plugins.pendingLogin = nil
    }

    private var windowTitle: String {
        model.activeTab.title
    }

    private var browserTabItems: [BrowserTabItem] {
        model.contentTabs.map {
            BrowserTabItem(id: $0.id, title: $0.title, systemImage: Route.systemImage(for: $0.current))
        }
    }

    private var activeTabBinding: Binding<UUID> {
        Binding(get: { model.activeTabID }, set: { model.activeTabID = $0 })
    }

    /// The tab for one of the container's items. The items are the content
    /// tabs themselves, so there always is one; showing another tab's page
    /// instead would mount that page twice.
    private func browserTab(for id: UUID) -> BrowserTab? {
        let tab = model.contentTabs.first { $0.id == id }
        assert(tab != nil, "the tab container asked for the page of a tab that is gone")
        return tab
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
        .browserNewTabKeyboardShortcut()
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

    var body: some View {
        Group {
            if let route = tab.current {
                RouteContent(
                    route: route,
                    player: app.player(forTab: tab.id),
                    browserToolbar: BrowserToolbarContext(tab: tab),
                    shouldKeepPlaybackWhenHidden: {
                        tab.current == route && app.contentTabs.contains { $0.id == tab.id }
                    }
                )
                    .id(tab.historyIndexIdentity)
            } else {
                NavigationStack {
                    ContentUnavailableView("New Tab", systemImage: "plus.square", description: Text("Choose a section from the menu."))
                        .navigationTitle("New Tab")
                        .profileSwitcherToolbarItem()
                }
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
            // Icon only: `labelsHidden()` hides control labels, not a Label's
            // title, which the bottom bar then squeezes in beside the icon.
            Label("Tabs", systemImage: "square.on.square")
                .labelStyle(.iconOnly)
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
            onClose: { app.closeTab($0) },
            onMove: { app.moveTab($0, to: $1) }
        )
    }
}


private extension BrowserTab {
    /// `.id()` key for `RouteContent` so SwiftUI tears down and rebuilds the
    /// screen on back/forward — these are different pages with different
    /// identity, not the same view updating in place.
    var historyIndexIdentity: Int { historyIndex }
}

/// Associates an authentication browser with the tab that requested it. The
/// browser remains mounted while another tab is active, preserving login state,
/// but no longer obscures that tab's content.
struct LoginTarget: Identifiable, Hashable {
    let pluginID: String
    let tabID: UUID
    var id: String { "\(tabID.uuidString):\(pluginID)" }
}

@MainActor
private struct LoginRequiredBanner: View {
    let sourceName: String
    let onLogin: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
            Text("\(sourceName) needs you to sign in to continue.")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Not now", action: onDismiss)
            Button("Sign in", action: onLogin)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityLabel("Login required for \(sourceName)")
    }
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
    /// This device's identity in the pairing: the profile's peer, or the
    /// device-wide pairing identity when the profile has none.
    @State private var sender: AppSyncPeerIdentity?
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
                            Task { if let sender { try? await request.reject(sender: sender) }; onClose() }
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
                        Task { if let sender { try? await request.reject(sender: sender) }; onClose() }
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
            // Opened from a pairing code the user just scanned, so the system
            // may prompt for local network access straight away.
            guard await app.permissions.authorize(
                .localNetwork, for: "credential-pairing", origin: .userAction,
                explanation: .credentialPairing
            ) == .allowed else {
                error = "Local network access is needed to reach the other device."
                return
            }
            app.permissions.recordUse(of: .localNetwork)
            do {
                let identity = try app.peerService?.peer ?? app.stores.pairingIdentity()
                sender = identity
                senderIdentity = try await request.announceSender(identity, peerService: app.peerService)
            }
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
                    guard let sender else { throw PairingError.unavailable }
                    try await request.send(auth, sender: sender)
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

public extension Scene {
    /// The app's commands for each window: the tab commands (close, new,
    /// reopen, select and cycle tabs), in the menus where the platform has
    /// them and as keyboard shortcuts everywhere.
    func hummingbirdCommands() -> some Scene {
        browserTabCommands()
    }
}
