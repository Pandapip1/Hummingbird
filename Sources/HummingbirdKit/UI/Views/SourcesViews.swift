import Foundation
#if canImport(SwiftUI)
import SwiftUI
#else
import SwiftOpenUI
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Source list

@MainActor
struct SourcesView: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var removeTarget: String?

    var body: some View {
        NavigationStack {
            List {
                if app.plugins.installed.isEmpty {
                    ContentUnavailableView("No sources", systemImage: "puzzlepiece.extension",
                                           description: Text("Tap + and paste a plugin URL or scan its QR code."))
                        .hiddenListRowSeparator()
                }
                ForEach(app.plugins.installed) { p in
                    PluginRow(plugin: p) { removeTarget = p.id }
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { NavigationLink { AppSettingsView() } label: { Image(systemName: "gearshape") } }
                ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } }
                #else
                ToolbarItem(placement: .automatic) { NavigationLink { AppSettingsView() } label: { Image(systemName: "gearshape") } }
                ToolbarItem(placement: .primaryAction) { Button { showAdd = true } label: { Image(systemName: "plus") } }
                #endif
            }
            .sheet(isPresented: $showAdd) { AddSourceSheet() }
            .confirmationDialog("Remove source?", isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } }
            ), titleVisibility: .visible) {
                if let removeTarget, let plugin = app.plugins.plugin(removeTarget) {
                    Button("Remove \(plugin.config.name)", role: .destructive) {
                        app.plugins.remove(removeTarget)
                        self.removeTarget = nil
                    }
                }
                Button("Cancel", role: .cancel) { removeTarget = nil }
            } message: {
                Text("Its settings and sign-in are deleted. Subscriptions you saved stay in your library.")
            }
            .refreshable { await app.plugins.checkForUpdates() }
            .routeDestinations()
        }
    }
}

/// A source row keeps the most useful plugin actions available without opening its detail page.
@MainActor
private struct PluginRow: View {
    let plugin: InstalledPlugin
    let requestRemove: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let row = NavigationLink(value: Route.plugin(plugin.id)) {
            HStack(spacing: 12) {
                RemoteImage(url: plugin.iconURL.flatMap(URL.init(string:))).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.config.name).font(.headline)
                    HStack(spacing: 6) {
                        Text("v\(plugin.config.version)").font(.caption).foregroundStyle(.secondary)
                        if let v = plugin.availableVersion { Text("Update: v\(v)").font(.caption.bold()).foregroundStyle(.orange) }
                        if !plugin.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }

        row
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive, action: requestRemove) {
                    Label("Remove", systemImage: "trash")
                }
            }
            .contextMenu {
                Button(plugin.enabled ? "Disable" : "Enable") {
                    app.plugins.setEnabled(plugin.id, !plugin.enabled)
                }
                Button("Remove source", role: .destructive, action: requestRemove)
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

    static let hasCamera: Bool = {
        #if canImport(AVFoundation)
        return AVCaptureDevice.default(for: .video) != nil
        #else
        return false
        #endif
    }()

    var body: some View {
        NavigationStack {
            Group {
                if let preview { PreviewView(preview: preview) }
                else if scanning {
                    ScannerPane(onCode: { code in scanning = false; urlText = code; Task { await prepare() } })
                } else {
                    Form {
                        Section("Plugin URL") {
                            TextField("https://…/Config.json", text: $urlText)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                #endif
                        }
                        if AddSourceSheet.hasCamera {
                            Section { Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") } }
                        }
                        if let errorText { Section { Text(errorText).foregroundStyle(.red).font(.footnote) } }
                        Section(footer: Text("Plugins are third-party code that runs on your device. Only add sources you trust.")) { EmptyView() }
                    }
                }
            }
            .navigationTitle("Add source")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if preview != nil {
                            preview = nil
                        } else {
                            dismiss()
                        }
                    }
                }
                if let preview {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(preview.warnings.isEmpty ? "Install" : "Install anyway", action: install)
                            .bold()
                    }
                }
                if preview == nil && !scanning {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { await prepare() } } label: {
                            if working { ProgressView() } else { Text("Continue") }
                        }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    }
                }
            }
        }
        .frame(minHeight: 320)
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
        }
    }
}

// MARK: - Plugin detail

@MainActor
struct PluginDetailView: View {
    let pluginID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var updateMessage: String?
    @State private var libraryMessage: String?
    @State private var confirmRemove = false

    var body: some View {
        if let p = app.plugins.plugin(pluginID) {
            Form {
                Section {
                    Toggle("Enabled", isOn: Binding(get: { p.enabled }, set: { app.plugins.setEnabled(pluginID, $0) }))
                    LabeledContent("Version", value: "\(p.config.version)")
                    if !p.config.author.isEmpty { LabeledContent("Author", value: p.config.author) }
                    Button { Task { await checkForUpdate() } } label: {
                        if working { ProgressView() } else { Text("Check for updates") }
                    }
                    .disabled(working)
                    if let v = p.availableVersion {
                        Button("Update to v\(v)") { Task { await update() } }.disabled(working)
                    }
                    if let updateMessage { Text(updateMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                if !p.config.description.isEmpty { Section { Text(p.config.description).font(.subheadline) } }

                if p.config.authentication != nil {
                    Section("Account") {
                        if app.plugins.isLoggedIn(pluginID) {
                            Label("Signed in", systemImage: "checkmark.seal")
                            Button("Sign out", role: .destructive) { app.plugins.logout(pluginID) }
                        } else {
                            Button("Sign in") {
                                app.plugins.pendingDirectLogin = pluginID
                            }
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
                    if let libraryMessage { Text(libraryMessage).font(.footnote).foregroundStyle(.secondary) }
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .confirmationDialog("Remove \(p.config.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { app.plugins.remove(pluginID); dismiss() }
            } message: { Text("Its settings and sign-in are deleted. Subscriptions you saved stay in your library.") }
        } else {
            ContentUnavailableView("Source removed", systemImage: "trash")
        }
    }

    private func update() async {
        working = true; defer { working = false }
        do { try await app.plugins.update(pluginID); updateMessage = "Updated." }
        catch { updateMessage = error.localizedDescription }
    }

    private func checkForUpdate() async {
        working = true; updateMessage = nil
        defer { working = false }
        do {
            if let version = try await app.plugins.checkForUpdate(pluginID) {
                updateMessage = "Version \(version) is available."
            } else {
                updateMessage = "This source is up to date."
            }
        } catch {
            updateMessage = error.localizedDescription
        }
    }

    private func importSubscriptions() async {
        guard let rt = app.plugins.runtime(for: pluginID) else { return }
        working = true; libraryMessage = nil
        defer { working = false }
        do {
            try await rt.enable()
            guard rt.has("getUserSubscriptions") else { libraryMessage = "This source can't list your subscriptions."; return }
            let urls = Array(Set(try await rt.call("getUserSubscriptions", as: [String].self)))
            var added = 0
            for u in urls where !app.library.isSubscribed(u) {
                let info = try? await rt.call("getChannel", [u], as: ChannelInfo.self)
                app.library.subscribe(url: info?.url.isEmpty == false ? info!.url : u, pluginId: pluginID,
                                      name: info?.name ?? u, thumbnail: info?.thumbnail)
                added += 1
            }
            libraryMessage = "Imported \(added) subscription\(added == 1 ? "" : "s")."
        } catch { libraryMessage = app.platform.surface(error, pluginID: pluginID) }
    }

    private func importPlaylists() async {
        guard let rt = app.plugins.runtime(for: pluginID) else { return }
        working = true; libraryMessage = nil
        defer { working = false }
        do {
            try await rt.enable()
            guard rt.has("getUserPlaylists") else { libraryMessage = "This source can't list your playlists."; return }
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
            libraryMessage = "Imported \(count) playlist\(count == 1 ? "" : "s")."
        } catch { libraryMessage = app.platform.surface(error, pluginID: pluginID) }
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
                    #if !os(tvOS)
                    .textFieldStyle(.roundedBorder)
                    #endif
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
                #if !os(tvOS)
                Stepper("Channels per refresh: \(fetchLimit == 0 ? "no limit" : String(fetchLimit))", value: $fetchLimit, in: 0...500, step: 10)
                #else
                Picker("Channels per refresh", selection: $fetchLimit) {
                    Text("No limit").tag(0)
                    ForEach([10, 25, 50, 100, 200, 500], id: \.self) { Text(String($0)).tag($0) }
                }
                #endif
            }
            Section("About") {
                Text("Hummingbird plays content from Grayjay-compatible plugins. It is an independent project and is not affiliated with FUTO.")
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
        #if os(iOS) || os(macOS)
        QRScannerView(onCode: onCode)
            #if os(iOS)
            .ignoresSafeArea()
            #endif
            .overlay(alignment: .bottom) { Text("Point the camera at a plugin QR code").padding(10).background(.thinMaterial, in: Capsule()).padding() }
        #else
        Text("QR scanning is not available on this platform. Paste the plugin URL instead.")
        #endif
    }
}
