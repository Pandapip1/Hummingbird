import Foundation
import SwiftOpenUI

// MARK: - Source list

@MainActor
struct SourcesView: View {
    @Environment(AppModel.self) private var app
    let browserToolbar: BrowserToolbarContext?
    @State private var showAdd = false
    @State private var removeTarget: String?

    var body: some View {
        NavigationStack {
            List {
                if app.plugins.installed.isEmpty, app.plugins.syncInstalls.isEmpty {
                    ContentUnavailableView("No sources", systemImage: "puzzlepiece.extension",
                                           description: Text("Tap + and paste a plugin URL or scan its QR code."))
                        .hiddenListRowSeparator()
                }
                // Sources another device has that this one is still
                // installing, or couldn't install. Never shown as installed
                // before they are.
                ForEach(app.plugins.syncInstalls.values.sorted { $0.displayName < $1.displayName }) { install in
                    SyncInstallRow(install: install)
                }
                ForEach(app.plugins.installed) { p in
                    PluginRow(plugin: .init(p)) { removeTarget = p.id }
                        .equatable()
                }
            }
            .navigationTitle("Sources")
            .browserPageToolbarItem(id: "sources.add", placement: .trailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add source")
            }
            .profileSwitcherToolbarItem()
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
            .refreshable { await app.plugins.checkForUpdates(origin: .userAction) }
        }
    }

}

/// A source another device has that is installing here (spinner), or that
/// couldn't install (its error, and a retry that runs a sync pass). Retrying
/// shows the pass running rather than pretending the install is underway.
@MainActor
private struct SyncInstallRow: View {
    let install: SyncInstall
    @Environment(AppModel.self) private var app

    var body: some View {
        if let confirmation = install.confirmation {
            confirm(confirmation)
        } else {
            progress
        }
    }

    /// Another device uses a different copy of a plugin this device has:
    /// nothing is replaced until the user picks one.
    private func confirm(_ confirmation: SyncInstall.Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(install.displayName).font(.headline)
            Text("Your other device uses this source from \(install.sourceURL); this device’s copy is from \(confirmation.replacing).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(confirmation.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Use Other Device’s") { app.plugins.confirmSyncedReplacement(install.pluginID) }
                Button("Keep This Device’s") { app.plugins.keepLocalPlugin(install.pluginID) }
            }
        }
    }

    private var progress: some View {
        let syncing = app.profileAccount.syncService?.state == .syncing
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(install.displayName).font(.headline)
                if let failure = install.failure {
                    Text("Couldn’t install from your other device: \(failure)")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    Text("Installing from your other device…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if install.failure == nil || syncing {
                ProgressView()
            }
            if install.failure != nil {
                Button("Retry") { app.profileAccount.syncService?.startSync() }
                    .disabled(syncing)
            }
        }
    }
}

/// A source row keeps the most useful plugin actions available without opening its detail page.
@MainActor
private struct PluginRow: View, Equatable {
    /// What the row shows, and nothing else: an installed plugin carries its
    /// whole script.
    struct Model: Equatable {
        let id: String
        let name: String
        let version: Int
        let availableVersion: Int?
        let enabled: Bool
        let iconURL: URL?

        init(_ plugin: InstalledPlugin) {
            id = plugin.id
            name = plugin.config.name
            version = plugin.config.version
            availableVersion = plugin.availableVersion
            enabled = plugin.enabled
            iconURL = plugin.iconURL.flatMap(URL.init(string:))
        }
    }

    let plugin: Model
    let requestRemove: () -> Void

    /// The closure never compares equal, which would redraw every row (with
    /// its swipe action and context menu) whenever the list changes. It only
    /// ever names this row's plugin, so the model decides.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.plugin == rhs.plugin }
    @Environment(AppModel.self) private var app
    @Environment(\.openRoute) private var openRoute

    var body: some View {
        // A plain Button draws none of List's automatic NavigationLink
        // chevron, since opening a plugin's page now opens a tab rather than
        // pushing — draw the same affordance explicitly.
        let row = Button { openRoute(.plugin(plugin.id), title: plugin.name) } label: {
            HStack(spacing: 12) {
                RemoteImage(url: plugin.iconURL, contentMode: .fill).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).font(.headline)
                    HStack(spacing: 6) {
                        Text("v\(plugin.version)").font(.caption).foregroundStyle(.secondary)
                        if let v = plugin.availableVersion { Text("Update: v\(v)").font(.caption.bold()).foregroundStyle(.orange) }
                        if !plugin.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)

        row
            .destructiveRowAction("Remove", action: requestRemove)
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
    @State private var hasCamera = false

    var body: some View {
        NavigationStack {
            Group {
                if let preview { PreviewView(preview: preview) }
                else if scanning {
                    QRCodeScanner(instruction: "Point the camera at a plugin QR code") { code in
                        scanning = false
                        urlText = code
                        Task { await prepare() }
                    }
                } else {
                    Form {
                        Section("Plugin URL") {
                            TextField("https://…/Config.json", text: $urlText)
                                .autocorrectionDisabled()
                                .urlEntryStyle()
                        }
                        if hasCamera {
                            Section { Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") } }
                        }
                        if working {
                            Section { ProgressView("Checking the plugin…") }
                        }
                        if let errorText {
                            Section {
                                Text(errorText).foregroundStyle(.red).font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Section(footer: Text("Plugins are third-party code that runs on your device. Only add sources you trust.")
                            .fixedSize(horizontal: false, vertical: true)) { EmptyView() }
                    }
                    .task { hasCamera = await QRCodeScanning.isAvailable() }
                }
            }
            .navigationTitle("Add source")
            .detailNavigationStyle()
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
                        // The label stays put; progress shows in the form.
                        Button("Continue") { Task { await prepare() } }
                            .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    }
                }
            }
        }
        .sheetSize()
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
struct PreviewView: View {
    let preview: InstallPreview

    var body: some View {
        let c = preview.config
        List {
            Section {
                HStack(spacing: 12) {
                    RemoteImage(url: preview.iconURL.flatMap(URL.init(string:)), contentMode: .fill).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading) {
                        Text(c.name).font(.headline)
                        Text("v\(c.version) · \(c.author)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .modifier(TVPreviewFocus())
                if !c.description.isEmpty {
                    Text(c.description).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .modifier(TVPreviewFocus())
                }
                if preview.existing != nil { Label("Replaces your installed version", systemImage: "arrow.triangle.2.circlepath").font(.footnote).modifier(TVPreviewFocus()) }
            }
            if !preview.warnings.isEmpty {
                Section("Review before installing") {
                    ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, w in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(w.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline.bold())
                            Text(w.detail).font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .modifier(TVPreviewFocus())
                    }
                }
            }
            if !c.allowUrls.isEmpty {
                Section("Can contact") {
                    ForEach(Array(c.allowUrls.enumerated()), id: \.offset) { index, url in
                        FocusableReadOnlyValue(
                            text: url,
                            monospaced: true,
                            accessibilityIdentifier: "install-preview-url-\(index)"
                        )
                    }
                }
            }
        }
    }
}

private typealias TVPreviewFocus = FocusableReadOnlyModifier

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
            Group {
                SettingsDetailContainer {
                pluginForm(for: p)
                }
            }
            .navigationTitle(p.config.name)
            .detailNavigationStyle()
            .confirmationDialog("Remove \(p.config.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { app.plugins.remove(pluginID); dismiss() }
            } message: { Text("Its settings and sign-in are deleted. Subscriptions you saved stay in your library.") }
        } else {
            ContentUnavailableView("Source removed", systemImage: "trash")
        }
    }

    private func pluginForm(for p: InstalledPlugin) -> some View {
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
                        if let failure = app.plugins.credentialStorageError {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    }
                }

                let settings = p.config.settings
                if !settings.isEmpty {
                    Section("Settings") {
                        ForEach(settings) { setting in
                            SettingRow(pluginID: p.id, setting: setting, stored: app.plugins.settingValue(p, setting))
                                .equatable()
                        }
                    }
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
        guard let rt = await app.plugins.runtime(for: pluginID) else { return }
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
        guard let rt = await app.plugins.runtime(for: pluginID) else { return }
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
struct SettingRow: View, Equatable {
    let pluginID: String
    let setting: PluginSetting
    /// The value in effect, passed in so that one changed setting redraws
    /// only its own row.
    let stored: String?
    @Environment(AppModel.self) private var app

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pluginID == rhs.pluginID && lhs.setting == rhs.setting && lhs.stored == rhs.stored
    }

    var body: some View {
        switch setting.kind {
        case "header":
            VStack(alignment: .leading) {
                Text(setting.name).font(.headline)
                if let d = setting.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
        case "boolean", "toggle", "switch":
            PendingToggle(title: setting.name, isOn: stored == "true", apply: { value in
                try await apply(value ? "true" : "false")
            }) {
                label
            }
        case "dropdown", "select", "list":
            PendingPicker(title: setting.name, selection: Int(stored ?? "0") ?? 0, apply: { index in
                try await apply(String(index))
            }) {
                ForEach(Array((setting.options ?? []).enumerated()), id: \.offset) { i, o in Text(o).tag(i) }
            }
        default:
            VStack(alignment: .leading) {
                label
                PendingTextField(title: setting.name, text: Self.decodeText(stored)) { text in
                    try await apply(Self.encodeText(text))
                }
            }
        }
    }

    /// Takes effect only once the plugin runs with the new value.
    private func apply(_ value: String) async throws {
        try await app.plugins.applySetting(pluginID: pluginID, key: setting.key, value: value)
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
    @Environment(AppModel.self) private var app
    let browserToolbar: BrowserToolbarContext?

    var body: some View {
        AppSettingsForm(stores: app.stores, browserToolbar: browserToolbar)
    }
}

/// The settings live in the stores' preferences domain, not necessarily
/// `UserDefaults.standard`, so each setting names its store.
@MainActor
private struct AppSettingsForm: View {
    @AppStorage private var maxHeight: Int
    @AppStorage private var subtitlesDefault: Bool
    @AppStorage private var fetchLimit: Int
    @AppStorage private var mediaCacheLimitGigabytes: Int
    @Environment(\.openRoute) private var openRoute
    private let stores: AppDataStores
    let browserToolbar: BrowserToolbarContext?

    init(stores: AppDataStores, browserToolbar: BrowserToolbarContext?) {
        self.stores = stores
        self.browserToolbar = browserToolbar
        let defaults = stores.defaults
        _maxHeight = AppStorage(wrappedValue: 1080, PlaybackPreferenceKey.maxVideoHeight, store: defaults)
        _subtitlesDefault = AppStorage(
            wrappedValue: false, PlaybackPreferenceKey.showSubtitlesByDefault, store: defaults
        )
        _fetchLimit = AppStorage(wrappedValue: 0, PlaybackPreferenceKey.subscriptionFetchLimit, store: defaults)
        _mediaCacheLimitGigabytes = AppStorage(
            wrappedValue: MediaCache.defaultLimitGigabytes, PlaybackPreferenceKey.mediaCacheLimitGigabytes, store: defaults
        )
    }

    var body: some View {
        Form {
            Section("Sync") {
                Button {
                    openRoute(.syncSettings, title: "Sync")
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            #if os(macOS) && !BACKEND_GTK
            if let store = stores.keychain {
                CredentialStorageSettingsSection(store: store)
            }
            #endif
            Section("Playback") {
                Picker("Maximum resolution", selection: $maxHeight) {
                    ForEach([360, 480, 720, 1080, 1440, 2160], id: \.self) { Text("\($0)p").tag($0) }
                }
                Toggle("Show subtitles by default", isOn: $subtitlesDefault)
            }
            Section(footer: Text("Videos download in full as soon as they play, and keep downloading in the background after you close them; whatever is playing always gets the bandwidth first. They stay on this device until the cache is full, then the videos watched longest ago are removed.")) {
                Picker("Video cache", selection: $mediaCacheLimitGigabytes) {
                    ForEach([2, 5, 10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                }
                MediaCacheUsageRows(cache: stores.mediaCache, limitGigabytes: mediaCacheLimitGigabytes)
            }
            Section(footer: Text("Off by default. Finished downloads are re-encoded with the hardware encoder in the background, only while the device is cool, not in Low Power Mode and, on iPhone and iPad, charging. The original is deleted only once the smaller copy is stored.")) {
                TranscodeToggle(stage: stores.transcoding, defaults: stores.defaults)
            }
            Section(footer: Text("Limits how many channels per source are refreshed at once. The rest show their last known videos. 0 means no limit.")) {
                RemoteFriendlyBoundedSelection(
                    title: "Channels per refresh",
                    value: $fetchLimit,
                    values: [0, 10, 25, 50, 100, 200, 500],
                    zeroLabel: "No limit",
                    step: 10
                )
            }
            #if !os(tvOS)
            PerformanceReportsSection(store: PerformanceReports.store(for: stores), exportDirectory: stores.cachesDirectory)
            #endif
            Section("About") {
                Text("Hummingbird plays content from Grayjay-compatible plugins. It is an independent project and is not affiliated with FUTO.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .profileSwitcherToolbarItem()
    }
}

#if !os(tvOS)
/// Shares the MetricKit reports kept on this device (crashes, hangs, CPU and
/// disk-write exceptions, daily metrics), and in debug builds the main-thread
/// stalls the app recorded, as one JSON file.
@MainActor
private struct PerformanceReportsSection: View {
    let store: PerformanceReportStore
    let exportDirectory: URL
    @State private var exportURL: URL?
    @State private var reportCount = 0
    @State private var stallCount = 0

    var body: some View {
        Section("Diagnostics") {
            if let exportURL {
                ShareContentAction(item: exportURL) {
                    Label("Export performance reports (\(reportCount))", systemImage: "square.and.arrow.up")
                }
                if stallCount > 0 {
                    Text("Includes \(stallCount) recorded main-thread stall\(stallCount == 1 ? "" : "s").")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No crash, hang or stall reports yet.")
                    .foregroundStyle(.secondary)
            }
            Text("Reports come from the system's MetricKit and stay on this device unless you share them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task {
            let store = store
            let destination = exportDirectory.appendingPathComponent("Export", isDirectory: true)
            let result = await Task.detached(priority: .utility) {
                (store.reports().count, store.stallLog.records().count, try? store.exportBundle(to: destination))
            }.value
            reportCount = result.0
            stallCount = result.1
            exportURL = result.2 ?? nil
        }
    }
}
#endif

/// How much the video cache holds, applying a new limit, and clearing what
/// is not playing. Slow work shows as such: the usage line shows a spinner
/// while it is measured or while a new limit or a clear is applied, and the
/// button is disabled meanwhile.
@MainActor
struct MediaCacheUsageRows: View {
    let cache: MediaCache
    let limitGigabytes: Int
    @State private var usage: Int64?
    @State private var working = false

    var body: some View {
        HStack {
            Text("In use")
            Spacer()
            if working || usage == nil {
                ProgressView()
            } else if let usage {
                Text(Fmt.bytes(usage)).foregroundStyle(.secondary)
            }
        }
        .task(id: limitGigabytes) {
            // A new limit evicts what no longer fits before the usage is shown.
            working = true
            await cache.setLimit(MediaCache.bytes(gigabytes: limitGigabytes))
            usage = await cache.usage()
            working = false
        }
        Button("Clear videos that are not playing") {
            Task {
                working = true
                await cache.clearUnused()
                usage = await cache.usage()
                working = false
            }
        }
        .disabled(working || usage == nil || usage == 0)
    }
}

/// Turns optional transcoding on or off. The toggle shows what the stage
/// reports: it is indeterminate with a spinner until the stage has applied
/// the change, and unavailable (with the reason) without a hardware encoder.
@MainActor
struct TranscodeToggle: View {
    let stage: TranscodeStage
    let defaults: UserDefaults
    @State private var isEnabled: Bool?
    @State private var isAvailable = true
    @State private var applying = false

    var body: some View {
        HStack {
            Toggle("Save space by re-encoding videos", isOn: Binding(
                get: { isEnabled ?? false },
                set: { newValue in apply(newValue) }
            ))
            .disabled(applying || isEnabled == nil || !isAvailable)
            if applying || isEnabled == nil { ProgressView() }
        }
        .task {
            isAvailable = await stage.isAvailable
            isEnabled = await stage.isEnabled
        }
        if !isAvailable {
            Text("This device has no hardware video encoder Hummingbird can use.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func apply(_ enabled: Bool) {
        applying = true
        Task {
            await stage.setEnabled(enabled)
            defaults.set(enabled, forKey: PlaybackPreferenceKey.transcodeDownloads)
            isEnabled = await stage.isEnabled
            applying = false
        }
    }
}
