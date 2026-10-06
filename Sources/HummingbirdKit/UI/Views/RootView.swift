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
        TabView(selection: $app.selectedTab) {
            HomeView().tabItem { Label("Home", systemImage: "house") }.tag(AppTab.home)
            SubscriptionsView().tabItem { Label("Subscriptions", systemImage: "rectangle.stack.person.crop") }.tag(AppTab.subscriptions)
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(AppTab.search)
            LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }.tag(AppTab.library)
            SourcesView().tabItem { Label("Sources", systemImage: "puzzlepiece.extension") }.tag(AppTab.sources)
        }
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
