import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif

// MARK: - Source list

@MainActor
struct SourcesView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                if app.plugins.installed.isEmpty {
                    ContentUnavailableView("No sources", systemImage: "puzzlepiece.extension",
                                           description: Text("Tap + and paste a plugin URL or scan its QR code."))
                        .listRowSeparator(.hidden)
                }
                ForEach(app.plugins.installed) { p in
                    NavigationLink(value: Route.plugin(p.id)) {
                        HStack(spacing: 12) {
                            RemoteImage(url: p.iconURL.flatMap(URL.init(string:))).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.config.name).font(.headline)
                                HStack(spacing: 6) {
                                    Text("v\(p.config.version)").font(.caption).foregroundStyle(.secondary)
                                    if let v = p.availableVersion { Text("Update: v\(v)").font(.caption.bold()).foregroundStyle(.orange) }
                                    if !p.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { NavigationLink { AppSettingsView() } label: { Image(systemName: "gearshape") } }
                ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } }
            }
            .sheet(isPresented: $showAdd) { AddSourceSheet() }
            .refreshable { await app.plugins.checkForUpdates() }
            .routeDestinations()
        }
    }
}

// MARK: - Add source

@MainActor
struct AddSourceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var scanning = false
    @State private var working = false
    @State private var errorText: String?
    @State private var preview: InstallPreview?

    var body: some View {
        NavigationStack {
            Group {
                if let preview { PreviewView(preview: preview, onInstall: install, onCancel: { self.preview = nil }) }
                else if scanning {
                    ScannerPane(onCode: { code in scanning = false; urlText = code; Task { await prepare() } })
                } else {
                    Form {
                        Section("Plugin URL") {
                            TextField("https://…/Config.json", text: $urlText)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            Button { Task { await prepare() } } label: { if working { ProgressView() } else { Text("Continue") } }
                                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || working)
                        }
                        Section { Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") } }
                        if let errorText { Section { Text(errorText).foregroundStyle(.red).font(.footnote) } }
                        Section(footer: Text("Plugins are third-party code that runs on your device. Only add sources you trust.")) { EmptyView() }
                    }
                }
            }
            .navigationTitle("Add source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func prepare() async {
        working = true; errorText = nil
        defer { working = false }
        do { preview = try await app.plugins.prepareInstall(from: urlText) }
        catch { errorText = error.localizedDescription }
    }

    private func install() {
        guard let preview else { return }
        app.plugins.commit(preview)
        dismiss()
    }
}

@MainActor
private struct PreviewView: View {
    let preview: InstallPreview
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let c = preview.config
        List {
            Section {
                HStack(spacing: 12) {
                    RemoteImage(url: preview.iconURL.flatMap(URL.init(string:))).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading) {
                        Text(c.name).font(.headline)
                        Text("v\(c.version) · \(c.author)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !c.description.isEmpty { Text(c.description).font(.subheadline) }
                if preview.existing != nil { Label("Replaces your installed version", systemImage: "arrow.triangle.2.circlepath").font(.footnote) }
            }
            if !preview.warnings.isEmpty {
                Section("Review before installing") {
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, w in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(w.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline.bold())
                            Text(w.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !c.allowUrls.isEmpty {
                Section("Can contact") { ForEach(c.allowUrls, id: \.self) { Text($0).font(.footnote.monospaced()) } }
            }
            Section {
                Button(preview.warnings.isEmpty ? "Install" : "Install anyway", action: onInstall).bold()
                Button("Back", role: .cancel, action: onCancel)
            }
        }
    }
}

// MARK: - Plugin detail

@MainActor
struct PluginDetailView: View {
    let pluginID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showLogin = false
    @State private var working = false
    @State private var message: String?
    @State private var confirmRemove = false

    var body: some View {
        if let p = app.plugins.plugin(pluginID) {
            Form {
                Section {
                    Toggle("Enabled", isOn: Binding(get: { p.enabled }, set: { app.plugins.setEnabled(pluginID, $0) }))
                    LabeledContent("Version", value: "\(p.config.version)")
                    if !p.config.author.isEmpty { LabeledContent("Author", value: p.config.author) }
                    if let v = p.availableVersion {
                        Button("Update to v\(v)") { Task { await update() } }.disabled(working)
                    }
                }
                if !p.config.description.isEmpty { Section { Text(p.config.description).font(.subheadline) } }

                if p.config.authentication != nil {
                    Section("Account") {
                        if app.plugins.isLoggedIn(pluginID) {
                            Label("Signed in", systemImage: "checkmark.seal")
                            Button("Sign out", role: .destructive) { app.plugins.logout(pluginID) }
                        } else {
                            Button("Sign in") { showLogin = true }
                        }
                    }
                }

                let settings = p.config.settings
                if !settings.isEmpty {
                    Section("Settings") { ForEach(settings) { SettingRow(plugin: p, setting: $0) } }
                }

                Section("Library") {
                    Button("Import subscriptions") { Task { await importSubscriptions() } }.disabled(working)
                    Button("Import playlists") { Task { await importPlaylists() } }.disabled(working)
                    if working { ProgressView() }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }

                if let changes = p.config.changelog?[String(p.config.version)], !changes.isEmpty {
                    Section("What's new in v\(p.config.version)") { ForEach(changes, id: \.self) { Text($0).font(.footnote) } }
                }
                if !p.config.allowUrls.isEmpty {
                    Section("Can contact") { ForEach(p.config.allowUrls, id: \.self) { Text($0).font(.footnote.monospaced()) } }
                }
                Section {
                    Button("Remove source", role: .destructive) { confirmRemove = true }
                }
            }
            .navigationTitle(p.config.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLogin) { LoginSheet(pluginID: pluginID) }
            .confirmationDialog("Remove \(p.config.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { app.plugins.remove(pluginID); dismiss() }
            } message: { Text("Its settings and sign-in are deleted. Subscriptions you saved stay in your library.") }
        } else {
            ContentUnavailableView("Source removed", systemImage: "trash")
        }
    }

    private func update() async {
        working = true; defer { working = false }
        do { try await app.plugins.update(pluginID); message = "Updated." } catch { message = error.localizedDescription }
    }

    private func importSubscriptions() async {
        guard let rt = app.plugins.runtime(for: pluginID) else { return }
        working = true; message = nil
        defer { working = false }
        do {
            try await rt.enable()
            guard rt.has("getUserSubscriptions") else { message = "This source can't list your subscriptions."; return }
            let urls = Array(Set(try await rt.call("getUserSubscriptions", as: [String].self)))
            var added = 0
            for u in urls where !app.library.isSubscribed(u) {
                let info = try? await rt.call("getChannel", [u], as: ChannelInfo.self)
                app.library.subscribe(url: info?.url.isEmpty == false ? info!.url : u, pluginId: pluginID,
                                      name: info?.name ?? u, thumbnail: info?.thumbnail)
                added += 1
            }
            message = "Imported \(added) subscription\(added == 1 ? "" : "s")."
        } catch { message = app.platform.surface(error, pluginID: pluginID) }
    }

    private func importPlaylists() async {
        guard let rt = app.plugins.runtime(for: pluginID) else { return }
        working = true; message = nil
        defer { working = false }
        do {
            try await rt.enable()
            guard rt.has("getUserPlaylists") else { message = "This source can't list your playlists."; return }
            let urls = try await rt.call("getUserPlaylists", as: [String].self)
            var count = 0
            for u in urls {
                guard let (_, payload, pager) = try? await app.platform.playlist(url: u) else { continue }
                var items = pager.initial
                var rounds = 0
                while pager.hasMore, rounds < 25, let more = try? await pager.next() { items += more; rounds += 1 }
                let videos = items.filter { $0.kind == .video || $0.kind == .nested }.map { SavedVideo($0) }
                app.library.createPlaylist(name: payload.header.name, videos: videos)
                count += 1
            }
            message = "Imported \(count) playlist\(count == 1 ? "" : "s")."
        } catch { message = app.platform.surface(error, pluginID: pluginID) }
    }
}

// MARK: - Plugin settings editor

@MainActor
struct SettingRow: View {
    let plugin: InstalledPlugin
    let setting: PluginSetting
    @Environment(AppModel.self) private var app

    private var stored: String? { app.plugins.plugin(plugin.id).flatMap { app.plugins.settingValue($0, setting) } }

    var body: some View {
        switch setting.kind {
        case "header":
            VStack(alignment: .leading) {
                Text(setting.name).font(.headline)
                if let d = setting.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
        case "boolean", "toggle", "switch":
            Toggle(isOn: Binding(get: { stored == "true" }, set: { app.plugins.setSetting(pluginID: plugin.id, key: setting.key, value: $0 ? "true" : "false") })) {
                label
            }
        case "dropdown", "select", "list":
            Picker(setting.name, selection: Binding(get: { Int(stored ?? "0") ?? 0 }, set: { app.plugins.setSetting(pluginID: plugin.id, key: setting.key, value: String($0)) })) {
                ForEach(Array((setting.options ?? []).enumerated()), id: \.offset) { i, o in Text(o).tag(i) }
            }
        default:
            VStack(alignment: .leading) {
                label
                TextField(setting.name, text: Binding(get: { Self.decodeText(stored) }, set: { app.plugins.setSetting(pluginID: plugin.id, key: setting.key, value: Self.encodeText($0)) }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(setting.name)
            if let d = setting.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// Text settings are stored as JSON strings so the plugin receives a string after parsing.
    static func decodeText(_ s: String?) -> String {
        guard let s else { return "" }
        if let d = s.data(using: .utf8), let v = try? JSONDecoder().decode(String.self, from: d) { return v }
        return s
    }
    static func encodeText(_ s: String) -> String {
        (try? JSONEncoder().encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}

// MARK: - App settings

@MainActor
struct AppSettingsView: View {
    @AppStorage("maxVideoHeight") private var maxHeight = 1080
    @AppStorage("preferAdaptive") private var preferAdaptive = true
    @AppStorage("showSubtitlesByDefault") private var subtitlesDefault = false
    @AppStorage("subscriptionFetchLimit") private var fetchLimit = 0

    var body: some View {
        Form {
            Section("Playback") {
                Picker("Maximum resolution", selection: $maxHeight) {
                    ForEach([360, 480, 720, 1080, 1440, 2160], id: \.self) { Text("\($0)p").tag($0) }
                }
                Toggle("Prefer adaptive streaming (HLS)", isOn: $preferAdaptive)
                Toggle("Show subtitles by default", isOn: $subtitlesDefault)
            }
            Section(footer: Text("Limits how many channels per source are refreshed at once. The rest show their last known videos. 0 means no limit.")) {
                Stepper("Channels per refresh: \(fetchLimit == 0 ? "no limit" : String(fetchLimit))", value: $fetchLimit, in: 0...500, step: 10)
            }
            Section("About") {
                Text("Jaybird plays content from Grayjay-compatible plugins. It is an independent project and is not affiliated with FUTO.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
    }
}

/// Camera QR scanner where the platform has one; otherwise a note (the URL can be typed or pasted instead).
@MainActor
private struct ScannerPane: View {
    let onCode: (String) -> Void
    var body: some View {
        #if canImport(AVFoundation) && canImport(UIKit)
        QRScannerView(onCode: onCode)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { Text("Point the camera at a plugin QR code").padding(10).background(.thinMaterial, in: Capsule()).padding() }
        #else
        Text("QR scanning is not available on this platform. Paste the plugin URL instead.")
        #endif
    }
}
