import Foundation
import Observation
import os
import ATProtoKit

/// A plugin as stored on this device.
struct InstalledPlugin: Codable, Identifiable, Hashable, Sendable {
    var config: PluginConfig
    var script: String
    /// Stored setting values (JSON text as the script will see it before parsing). Missing keys use the declared default.
    var settings: [String: String] = [:]
    var enabled: Bool = true
    var iconURL: String?
    var installedAt: Date = Date()
    /// Newer version found by the last update check.
    var availableVersion: Int?
    /// A source another device installs this plugin from that the user chose
    /// not to switch to. Synced records naming it are taken as resolved, so
    /// the user isn't asked again. Never synced.
    var declinedSyncSource: String?
    var id: String { config.id }
}

struct InstallPreview: Identifiable, Sendable {
    var id: String { config.id }
    var config: PluginConfig
    var script: String
    var iconURL: String?
    var warnings: [(title: String, detail: String)]
    var existing: InstalledPlugin?
}

enum InstallError: LocalizedError {
    case badURL
    case download(String)
    case invalidConfig(String)
    case emptyScript
    case invalidSignature
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "That is not a valid plugin URL."
        case .download(let m): return "Could not download the plugin: \(m)"
        case .invalidConfig(let m): return "Invalid plugin config: \(m)"
        case .emptyScript: return "The plugin script is empty."
        case .invalidSignature: return "The script signature is invalid. The plugin may have been tampered with."
        case .invalid(let m): return m
        }
    }
}

@MainActor
@Observable
final class PluginManager {
    private(set) var installed: [InstalledPlugin] = []
    /// Latest plugin toast, shown briefly by the UI.
    var toast: String?
    /// Set when a plugin demands a captcha; the UI presents the captcha sheet.
    var pendingCaptcha: CaptchaRequest?
    /// Set when a plugin needs the user to log in.
    var pendingLogin: String?
    /// Set when the user explicitly taps "Sign in" from the plugin detail screen;
    /// the UI opens the login overlay directly without an intermediate alert.
    var pendingDirectLogin: String?
    /// Invalidates credential-derived UI after login or logout. Credentials
    /// live outside the observable plugin array, so views otherwise keep the
    /// state they read during their previous body evaluation.
    private(set) var credentialRevision = 0
    /// The latest failure to read or write a plugin credential, shown on the
    /// plugin screen instead of the credential silently going missing.
    private(set) var credentialStorageError: String?

    /// Each plugin's stored sign-in and captcha cookies, read from the
    /// credential store once per process when the plugin is installed or this
    /// manager is created, never during view evaluation. Views, runtimes and
    /// pairing read only this; writes update it after the store accepts them.
    @ObservationIgnored private var storedCredentials: [String: PluginCredentials] = [:]
    @ObservationIgnored private var runtimes: [String: PluginRuntime] = [:]
    @ObservationIgnored private var runtimePreparation: [String: Task<PluginRuntime, Never>] = [:]
    @ObservationIgnored private let profileChanges: ProfileChangeStore?
    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private let storageName: String
    @ObservationIgnored private let credentialNamespace: String
    /// Counts local edits per plugin, so a synced change prepared while the
    /// user changed the same plugin never overwrites that change.
    @ObservationIgnored private var localEdits: [String: Int] = [:]
    /// Plugins from other devices being installed here, or that failed to.
    private(set) var syncInstalls: [String: SyncInstall] = [:]
    /// Downloaded replacements waiting for the user to confirm them.
    @ObservationIgnored private var pendingReplacements: [String: (preview: InstallPreview, synced: SyncedPlugin)] = [:]
    /// Fetches plugin configs and scripts. Tests substitute their own; the
    /// app uses `urlSession`.
    @ObservationIgnored private let fetch: PluginFetch?
    /// Puts downloads and plugin requests to local-network hosts behind the
    /// permission gate. Nil (tests, previews) lets them through.
    @ObservationIgnored var localNetworkAccess: PluginLocalNetworkAccess?
    @ObservationIgnored private let urlSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    struct PluginCredentials: Sendable {
        var auth: SourceAuth?
        var captcha: SourceAuth?
    }

    struct CaptchaRequest: Identifiable {
        let id = UUID()
        let pluginID: String
        let url: String?
        let body: String?
    }

    init(installed: [InstalledPlugin] = [], profileChanges: ProfileChangeStore? = nil,
         storage: Storage, credentialStore: any CredentialStore,
         storageName: String = "plugins", credentialNamespace: String = "",
         preloadedCredentials: PreloadedPluginCredentials? = nil, fetch: PluginFetch? = nil) {
        self.fetch = fetch
        self.installed = installed
        self.profileChanges = profileChanges
        self.storage = storage
        self.credentialStore = credentialStore
        self.storageName = storageName
        self.credentialNamespace = credentialNamespace
        if let preloadedCredentials {
            storedCredentials = preloadedCredentials.credentials
            if let failure = preloadedCredentials.failure { recordCredentialFailure(failure) }
        }
        for plugin in installed { loadCredentials(for: plugin.id) }
    }

    private func persist() { storage.save(installed, name: storageName) }

    // MARK: lookup

    func plugin(_ id: String) -> InstalledPlugin? { installed.first { $0.id == id } }
    var enabledPlugins: [InstalledPlugin] { installed.filter { $0.enabled } }

    /// The running runtime for a plugin, created on first use.
    func runtime(for id: String) async -> PluginRuntime? {
        if let r = runtimes[id] { return r }
        guard let p = plugin(id) else { return nil }
        let preparation: Task<PluginRuntime, Never>
        if let existing = runtimePreparation[id] {
            preparation = existing
        } else {
            let stored = credentials(for: id)
            let localNetworkCheck = localNetworkAccess?.runtimeCheck(source: p.config.name)
            let created = Task.detached(priority: .userInitiated) {
                PluginRuntime(
                    config: p.config, script: p.script, settings: p.settings,
                    auth: stored.auth, captcha: stored.captcha,
                    localNetworkAccess: localNetworkCheck
                )
            }
            runtimePreparation[id] = created
            preparation = created
        }
        let r = await preparation.value
        runtimePreparation[id] = nil
        guard plugin(id) == p else {
            await r.stop()
            return await runtime(for: id)
        }
        if let existing = runtimes[id] {
            await r.stop()
            return existing
        }
        adopt(r, for: id)
        return r
    }

    /// Makes `r` the plugin's running runtime, reporting its toasts and logs.
    private func adopt(_ r: PluginRuntime, for id: String) {
        r.onToast = { [weak self] msg in
            Logger.plugin.notice("alert plugin=\(id, privacy: .public) message=\(msg.prefix(500))")
            Task { @MainActor in self?.toast = msg }
        }
        r.onLog = { msg in
            let lower = msg.lowercased()
            let umpProgress = lower.hasPrefix("ump ") || lower.hasPrefix("ump:") || lower.hasPrefix("ump descriptor ")
                || lower.hasPrefix("====== ump") || lower.hasPrefix("abr enabled:")
            if umpProgress {
                // UMP progress lines are kept at info level so they survive in
                // the log store for diagnosing playback after the fact.
                Logger.player.info("ump_log plugin=\(id, privacy: .public) \(msg.prefix(500))")
            }
            // Plugins can log whole HTML and API responses: private, debug level
            // (streamed but not persisted), and bounded.
            let bounded = msg.count > 2_000 ? String(msg.prefix(2_000)) + "… [truncated]" : msg
            Logger.pluginConsole.debug("plugin=\(id, privacy: .public) \(bounded)")
        }
        runtimes[id] = r
    }

    func enabledRuntimes(where predicate: (PluginConfig) -> Bool = { _ in true }) async -> [PluginRuntime] {
        var result: [PluginRuntime] = []
        for plugin in enabledPlugins where predicate(plugin.config) {
            if let runtime = await runtime(for: plugin.id) { result.append(runtime) }
        }
        return result
    }

    /// Discards the running runtime so the next call starts a fresh one with current settings and credentials.
    func invalidate(_ id: String) {
        runtimePreparation.removeValue(forKey: id)?.cancel()
        if let r = runtimes.removeValue(forKey: id) { Task { await r.stop() } }
    }

    // MARK: install

    /// Fetches only the signed-in browser configuration for a one-time remote
    /// login. It does not install the plugin or read credentials on this device.
    func fetchConfig(from rawURL: URL) async throws -> PluginConfig {
        guard ["http", "https"].contains(rawURL.scheme?.lowercased()) else { throw InstallError.badURL }
        let data: Data
        do { data = try await download(rawURL, origin: .userAction, source: nil) } catch { throw InstallError.download(error.localizedDescription) }
        var config: PluginConfig
        do { config = try JSONDecoder().decode(PluginConfig.self, from: data) }
        catch { throw InstallError.invalidConfig(error.localizedDescription) }
        if config.sourceUrl == nil || config.sourceUrl?.isEmpty == true { config.sourceUrl = rawURL.absoluteString }
        guard config.authentication != nil else { throw InstallError.invalid("This plugin does not support signing in.") }
        return config
    }

    /// Downloads and checks a plugin. Nothing is stored until `commit` is called.
    /// `origin` is `.settings` when nobody on this instance asked for it (a
    /// plugin synced from another instance).
    func prepareInstall(from rawURL: String, origin: PermissionOrigin = .userAction) async throws -> InstallPreview {
        var text = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // QR codes and links may wrap the config URL in a grayjay://plugin/ link,
        // which must be a well-formed one (PluginInstallLink).
        if text.lowercased().hasPrefix(PluginInstallLink.scheme + ":") {
            guard let link = PluginInstallLink(text: text) else { throw InstallError.badURL }
            text = link.configURL.absoluteString
        }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme) else { throw InstallError.badURL }

        let configData: Data
        do { configData = try await download(url, origin: origin, source: nil) } catch { throw InstallError.download(error.localizedDescription) }
        var config: PluginConfig
        do { config = try JSONDecoder().decode(PluginConfig.self, from: configData) }
        catch { throw InstallError.invalidConfig(error.localizedDescription) }
        if config.sourceUrl == nil || config.sourceUrl?.isEmpty == true { config.sourceUrl = url.absoluteString }

        let base = URL(string: config.sourceUrl ?? "") ?? url
        guard let scriptURL = config.resolve(config.scriptUrl, base: base) else { throw InstallError.invalidConfig("scriptUrl is missing") }
        let scriptData: Data
        do { scriptData = try await download(scriptURL, origin: origin, source: config.name) } catch { throw InstallError.download(error.localizedDescription) }
        let (script, signatureValid) = try await Self.checkScript(
            scriptData, config: config,
            localNetworkCheck: localNetworkAccess?.runtimeCheck(source: config.name)
        )

        var warnings = config.warnings(signatureValid: signatureValid)
        let existing = plugin(config.id)
        if let existing, let old = existing.config.scriptPublicKey, !old.isEmpty, old != (config.scriptPublicKey ?? "") {
            warnings.insert(("Different author", "This plugin is signed with a different key than the version you have installed."), at: 0)
        }
        return InstallPreview(config: config, script: script,
                              iconURL: config.resolve(config.iconUrl, base: base)?.absoluteString,
                              warnings: warnings, existing: existing)
    }

    /// Decodes a downloaded script, checks its signature and does a dry run, so
    /// unsupported packages or missing entry points are reported before
    /// installing. Scripts run to megabytes, and a dry run starts a JavaScript
    /// context, so none of this happens on the main actor.
    @concurrent
    private static func checkScript(
        _ scriptData: Data, config: PluginConfig, localNetworkCheck: (@Sendable (URL) async -> Bool)?
    ) async throws -> (script: String, signatureValid: Bool?) {
        guard let script = String(data: scriptData, encoding: .utf8),
              script.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw InstallError.emptyScript
        }
        var signatureValid: Bool?
        if let sig = config.scriptSignature, let key = config.scriptPublicKey, !sig.isEmpty, !key.isEmpty {
            signatureValid = ScriptSignature.verify(script: script, signatureBase64: sig, publicKeyBase64: key)
            if signatureValid == false { throw InstallError.invalidSignature }
        }
        let probe = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil,
                                  localNetworkAccess: localNetworkCheck)
        do { try await probe.validate() } catch { await probe.stop(); throw InstallError.invalid(error.localizedDescription) }
        await probe.stop()
        return (script, signatureValid)
    }

    /// Stores a previewed plugin. Reinstalling keeps the user's settings and credentials.
    func commit(_ preview: InstallPreview) {
        var entry = InstalledPlugin(config: preview.config, script: preview.script, iconURL: preview.iconURL)
        if let old = preview.existing {
            entry.settings = old.settings
            entry.enabled = old.enabled
            entry.installedAt = old.installedAt
            installed.removeAll { $0.id == old.id }
        }
        installed.append(entry)
        installed.sort { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
        loadCredentialsInBackground(for: entry.id)
        invalidate(entry.id)
        persist()
        recordLocalEdit(entry)
    }

    func remove(_ id: String) {
        installed.removeAll { $0.id == id }
        forget(id)
        persist()
        localEdits[id, default: 0] &+= 1
        profileChanges?.delete(collection: HummingbirdProfileSchema.plugin, key: HummingbirdProfileSchema.key(for: id))
    }

    /// Stops a removed plugin and deletes its credentials.
    private func forget(_ id: String) {
        invalidate(id)
        do {
            try credentialStore.saveSourceAuth(nil, pluginID: id, kind: "auth", namespace: credentialNamespace)
            try credentialStore.saveSourceAuth(nil, pluginID: id, kind: "captcha", namespace: credentialNamespace)
            storedCredentials[id] = nil
        } catch {
            recordCredentialFailure(error)
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[i].enabled = on
        if !on { invalidate(id) }
        persist()
        recordLocalEdit(installed[i])
    }

    // MARK: settings

    func settingValue(_ plugin: InstalledPlugin, _ setting: PluginSetting) -> String? {
        plugin.settings[setting.key] ?? setting.default
    }

    func setSetting(pluginID: String, key: String, value: String) {
        guard let i = installed.firstIndex(where: { $0.id == pluginID }) else { return }
        installed[i].settings[key] = value
        invalidate(pluginID)
        persist()
        recordLocalEdit(installed[i])
    }

    /// Changes a setting only once the plugin runs with it. A runtime is
    /// started with the candidate value away from the main actor; the setting
    /// is stored and synced, and that runtime adopted, only if it starts.
    /// Otherwise nothing changes and the error is thrown.
    func applySetting(pluginID: String, key: String, value: String) async throws {
        guard let current = plugin(pluginID) else { throw InstallError.invalid("The source isn’t installed.") }
        var candidate = current
        candidate.settings[key] = value
        let started = try await Self.startRuntime(
            candidate, credentials: credentials(for: pluginID),
            localNetworkCheck: localNetworkAccess?.runtimeCheck(source: current.config.name)
        )
        guard let i = installed.firstIndex(where: { $0.id == pluginID }), installed[i] == current else {
            await started.stop()
            throw InstallError.invalid("The source changed while the setting was being applied. Try again.")
        }
        installed[i].settings[key] = value
        invalidate(pluginID)
        adopt(started, for: pluginID)
        persist()
        recordLocalEdit(installed[i])
    }

    /// Starts a runtime for `plugin` as it would be with its settings, and
    /// checks it runs. The JavaScript context is made off the main actor.
    @concurrent
    private static func startRuntime(
        _ plugin: InstalledPlugin, credentials: PluginCredentials,
        localNetworkCheck: (@Sendable (URL) async -> Bool)?
    ) async throws -> PluginRuntime {
        let runtime = PluginRuntime(
            config: plugin.config, script: plugin.script, settings: plugin.settings,
            auth: credentials.auth, captcha: credentials.captcha, localNetworkAccess: localNetworkCheck
        )
        do { try await runtime.validate() } catch {
            await runtime.stop()
            throw error
        }
        return runtime
    }

    // MARK: credentials

    func isLoggedIn(_ id: String) -> Bool {
        _ = credentialRevision
        return auth(for: id) != nil
    }

    /// The stored sign-in. Served from memory, so views may call this freely.
    func auth(for id: String) -> SourceAuth? {
        storedCredentials[id]?.auth
    }

    private func credentials(for id: String) -> PluginCredentials {
        storedCredentials[id] ?? PluginCredentials()
    }

    /// Reads a plugin's credentials from the store the first time it is seen.
    /// A failed read is reported and remembered as empty, so it is not retried
    /// (and cannot prompt again) until the user signs in anew.
    private func loadCredentials(for id: String) {
        guard storedCredentials[id] == nil else { return }
        var loaded = PluginCredentials()
        do {
            loaded.auth = try credentialStore.loadSourceAuth(pluginID: id, kind: "auth", namespace: credentialNamespace)
            loaded.captcha = try credentialStore.loadSourceAuth(pluginID: id, kind: "captcha", namespace: credentialNamespace)
        } catch {
            recordCredentialFailure(error)
        }
        storedCredentials[id] = loaded
    }

    /// `loadCredentials(for:)` for a plugin installed while the app runs: its
    /// credential-store read happens away from the main actor. A runtime
    /// started before it finishes is replaced once it has.
    private func loadCredentialsInBackground(for id: String) {
        guard storedCredentials[id] == nil else { return }
        let preload = (store: credentialStore, namespace: credentialNamespace)
        Task { [weak self] in
            let loaded = await PreloadedPluginCredentials.load(
                pluginIDs: [id], from: preload.store, namespace: preload.namespace
            )
            guard let self, self.storedCredentials[id] == nil else { return }
            self.storedCredentials[id] = loaded.credentials[id] ?? PluginCredentials()
            if let failure = loaded.failure { self.recordCredentialFailure(failure) }
            let found = loaded.credentials[id]
            if found?.auth != nil || found?.captcha != nil { self.invalidate(id) }
        }
    }

    func saveAuth(_ auth: SourceAuth, pluginID: String) {
        do {
            try credentialStore.saveSourceAuth(auth, pluginID: pluginID, kind: "auth", namespace: credentialNamespace)
            storedCredentials[pluginID, default: PluginCredentials()].auth = auth
            clearCredentialFailure()
        } catch {
            recordCredentialFailure(error)
        }
        credentialRevision &+= 1
        invalidate(pluginID)
        pendingLogin = nil
    }

    func saveCaptcha(_ data: SourceAuth, pluginID: String) {
        do {
            try credentialStore.saveSourceAuth(data, pluginID: pluginID, kind: "captcha", namespace: credentialNamespace)
            storedCredentials[pluginID, default: PluginCredentials()].captcha = data
        } catch {
            recordCredentialFailure(error)
        }
        invalidate(pluginID)
        pendingCaptcha = nil
    }

    func logout(_ id: String) {
        do {
            try credentialStore.saveSourceAuth(nil, pluginID: id, kind: "auth", namespace: credentialNamespace)
            storedCredentials[id, default: PluginCredentials()].auth = nil
        } catch {
            recordCredentialFailure(error)
        }
        credentialRevision &+= 1
        invalidate(id)
    }

    private func recordCredentialFailure(_ error: any Error) {
        let message = error.localizedDescription
        if credentialStorageError != message { credentialStorageError = message }
    }

    private func clearCredentialFailure() {
        if credentialStorageError != nil { credentialStorageError = nil }
    }

    // MARK: updates

    /// Re-downloads each plugin's config and records newer versions. The user applies them explicitly.
    /// `origin` is `.settings` for the automatic check at launch.
    /// Checks every plugin for a newer version. The configs are fetched and
    /// decoded concurrently away from the main actor, and the results land in
    /// one write that touches only plugins whose answer changed, so the list
    /// redraws once, and only the rows that changed.
    func checkForUpdates(origin: PermissionOrigin) async {
        var checks: [(id: String, url: URL, version: Int)] = []
        for p in installed {
            guard let src = p.config.sourceUrl, let url = URL(string: src) else { continue }
            if let localNetworkAccess, !(await localNetworkAccess.authorize(url, source: p.config.name, origin: origin)) {
                continue
            }
            checks.append((p.id, url, p.config.version))
        }
        let session = urlSession
        let results = await withTaskGroup(of: (String, Int?)?.self) { group in
            for check in checks {
                group.addTask {
                    guard let fresh = try? await Self.fetchConfig(check.url, session: session) else { return nil }
                    return (check.id, fresh.version > check.version ? fresh.version : nil)
                }
            }
            var results: [String: Int?] = [:]
            for await result in group { if let result { results[result.0] = result.1 } }
            return results
        }
        applyAvailableVersions(results)
    }

    /// Checks one plugin immediately and reports whether a newer version exists.
    @discardableResult
    func checkForUpdate(_ id: String, origin: PermissionOrigin = .userAction) async throws -> Int? {
        guard let p = plugin(id), let src = p.config.sourceUrl,
              let url = URL(string: src) else { throw InstallError.badURL }
        if let localNetworkAccess, !(await localNetworkAccess.authorize(url, source: p.config.name, origin: origin)) {
            throw LocalNetworkAccessDeclined(host: url.host ?? url.absoluteString)
        }
        let fresh = try await Self.fetchConfig(url, session: urlSession)
        let available = fresh.version > p.config.version ? fresh.version : nil
        applyAvailableVersions([id: available])
        return available
    }

    /// Records update-check answers. Every write to `installed` redraws
    /// whatever lists plugins, so unchanged answers write nothing.
    private func applyAvailableVersions(_ results: [String: Int?]) {
        var updated = installed
        var changed = false
        for (id, available) in results {
            guard let i = updated.firstIndex(where: { $0.id == id }), updated[i].availableVersion != available else { continue }
            updated[i].availableVersion = available
            changed = true
        }
        guard changed else { return }
        installed = updated
        persist()
    }

    @concurrent
    private static func fetchConfig(_ url: URL, session: URLSession) async throws -> PluginConfig {
        var req = URLRequest(url: url)
        req.setValue("Hummingbird/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.download("HTTP \(http.statusCode) from \(url.host ?? url.absoluteString)")
        }
        do { return try JSONDecoder().decode(PluginConfig.self, from: data) }
        catch { throw InstallError.invalidConfig(error.localizedDescription) }
    }

    func update(_ id: String) async throws {
        guard let p = plugin(id), let src = p.config.sourceUrl else { return }
        let preview = try await prepareInstall(from: src)
        commit(preview)
    }

    /// Plugin id -> config URL for backups.
    var sourceMap: [String: String] {
        Dictionary(uniqueKeysWithValues: installed.compactMap { p in p.config.sourceUrl.map { (p.id, $0) } })
    }

    // MARK: networking

    private func download(_ url: URL, origin: PermissionOrigin, source: String?) async throws -> Data {
        if let localNetworkAccess, !(await localNetworkAccess.authorize(url, source: source, origin: origin)) {
            throw LocalNetworkAccessDeclined(host: url.host ?? url.absoluteString)
        }
        var req = URLRequest(url: url)
        req.setValue("Hummingbird/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        if let fetch { (data, response) = try await fetch(req) } else { (data, response) = try await urlSession.data(for: req) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.download("HTTP \(http.statusCode) from \(url.host ?? url.absoluteString)")
        }
        return data
    }

    /// Only the deliberately constrained `SyncedPlugin` crosses this boundary;
    /// runtime source and SourceAuth/keychain data are structurally unavailable.
    /// Every local edit goes through here, so sync can tell that a plugin
    /// changed while a synced change to it was being prepared.
    private func recordLocalEdit(_ plugin: InstalledPlugin) {
        localEdits[plugin.id, default: 0] &+= 1
        guard let synced = SyncedPlugin(plugin) else { return }
        profileChanges?.put(.plugin(synced))
    }

    // MARK: sync

    /// How many synced plugins download and verify at once.
    static let maximumConcurrentSyncInstalls = 6

    /// Applies synced plugin records in one batch. A plugin already
    /// installed from the same source only takes the synced enabled state
    /// and settings; nothing is downloaded. Every other plugin is downloaded
    /// and checked concurrently (at most `maximumConcurrentSyncInstalls` at
    /// a time) while its row shows it installing; then everything that
    /// succeeded lands in `installed` with one assignment and one save. A
    /// plugin that fails stays listed with its error and is not reported as
    /// applied, so the next sync tries it again; it never holds back the
    /// others. Returns the record keys whose state now matches the change.
    func applySynced(_ changes: [PluginSyncChange]) async -> Set<RecordKey> {
        guard !changes.isEmpty else { return [] }
        let editsAtStart = localEdits
        var applied = Set<RecordKey>()
        var toInstall: [(change: PluginSyncChange, plugin: SyncedPlugin)] = []
        for change in changes {
            guard let plugin = change.plugin else { continue }
            if let current = self.plugin(plugin.pluginID), current.config.sourceUrl == plugin.sourceURL { continue }
            if self.plugin(plugin.pluginID)?.declinedSyncSource == plugin.sourceURL { continue }
            // Already downloaded and waiting for the user to choose.
            if let waiting = syncInstalls[plugin.pluginID], waiting.confirmation != nil,
               waiting.sourceURL == plugin.sourceURL { continue }
            toInstall.append((change, plugin))
        }

        var installs = syncInstalls
        for item in toInstall {
            installs[item.plugin.pluginID] = SyncInstall(
                pluginID: item.plugin.pluginID, sourceURL: item.plugin.sourceURL, failure: nil
            )
        }
        if installs != syncInstalls { syncInstalls = installs }

        let prepared = await prepareSyncedInstalls(toInstall.map(\.plugin))

        // Everything below is one batch on the main actor.
        var updated = installed
        var removedIDs: [String] = []
        var changedIDs: [String] = []
        installs = syncInstalls
        for change in changes {
            // A removal names only a record key: match it to an installed
            // plugin, or to a row for one that never finished installing.
            let id = change.plugin?.pluginID
                ?? updated.first { HummingbirdProfileSchema.key(for: $0.id) == change.key }?.id
                ?? installs.values.first { HummingbirdProfileSchema.key(for: $0.pluginID) == change.key }?.pluginID
            // A plugin edited here meanwhile keeps the local edit; its journal
            // event supersedes this change.
            if let id, localEdits[id] != editsAtStart[id] {
                if installs[id]?.failure == nil { installs[id] = nil }
                continue
            }
            guard let plugin = change.plugin else {
                if let id {
                    if updated.contains(where: { $0.id == id }) {
                        updated.removeAll { $0.id == id }
                        removedIDs.append(id)
                    }
                    installs[id] = nil
                    pendingReplacements[id] = nil
                }
                applied.insert(change.key)
                continue
            }
            // The user kept this device's copy over this source: resolved.
            if updated.first(where: { $0.id == plugin.pluginID })?.declinedSyncSource == plugin.sourceURL {
                installs[plugin.pluginID] = nil
                applied.insert(change.key)
                continue
            }
            var entry: InstalledPlugin
            if let index = updated.firstIndex(where: { $0.id == plugin.pluginID }),
               updated[index].config.sourceUrl == plugin.sourceURL {
                entry = updated[index]
            } else {
                switch prepared[plugin.pluginID] {
                case .success(let preview)?:
                    if let old = updated.first(where: { $0.id == plugin.pluginID }) {
                        // Replacing this device's copy with one from another
                        // source (maybe another author) is the user's call.
                        pendingReplacements[plugin.pluginID] = (preview, plugin)
                        installs[plugin.pluginID]?.confirmation = SyncInstall.Confirmation(
                            replacing: old.config.sourceUrl ?? "",
                            warnings: preview.warnings.map { "\($0.title): \($0.detail)" }
                        )
                        continue
                    }
                    entry = InstalledPlugin(config: preview.config, script: preview.script, iconURL: preview.iconURL)
                    installs[plugin.pluginID] = nil
                case .failure(let error)?:
                    installs[plugin.pluginID]?.failure = error.localizedDescription
                    continue
                case nil:
                    if installs[plugin.pluginID]?.confirmation == nil { installs[plugin.pluginID] = nil }
                    continue
                }
            }
            let before = updated.first { $0.id == plugin.pluginID }
            entry.enabled = plugin.enabled
            entry.settings = plugin.settings
            applied.insert(change.key)
            guard entry != before else { continue }
            updated.removeAll { $0.id == plugin.pluginID }
            updated.append(entry)
            changedIDs.append(plugin.pluginID)
        }
        // A row is only for a plugin that is still missing here.
        installs = installs.filter { entry in
            !updated.contains { $0.id == entry.key && $0.config.sourceUrl == entry.value.sourceURL }
        }
        pendingReplacements = pendingReplacements.filter { installs[$0.key]?.confirmation != nil }
        if installs != syncInstalls { syncInstalls = installs }
        guard !removedIDs.isEmpty || !changedIDs.isEmpty else { return applied }
        updated.sort { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
        installed = updated
        persist()
        for id in removedIDs { forget(id) }
        for id in changedIDs {
            loadCredentialsInBackground(for: id)
            invalidate(id)
        }
        return applied
    }

    /// Replaces this device's copy of a plugin with the synced one the
    /// user confirmed, taking its enabled state and settings. The next sync
    /// finds it installed from the synced source and records it applied.
    func confirmSyncedReplacement(_ id: String) {
        guard let pending = pendingReplacements.removeValue(forKey: id) else { return }
        var entry = InstalledPlugin(config: pending.preview.config, script: pending.preview.script,
                                    iconURL: pending.preview.iconURL)
        if let old = plugin(id) { entry.installedAt = old.installedAt }
        entry.enabled = pending.synced.enabled
        entry.settings = pending.synced.settings
        var updated = installed
        updated.removeAll { $0.id == id }
        updated.append(entry)
        updated.sort { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
        installed = updated
        syncInstalls[id] = nil
        persist()
        loadCredentialsInBackground(for: id)
        invalidate(id)
    }

    /// Keeps this device's copy and remembers the other source as declined,
    /// so the next sync records the choice as resolved and nobody is asked
    /// again. Nothing is published: the other devices keep theirs.
    func keepLocalPlugin(_ id: String) {
        let declined = pendingReplacements.removeValue(forKey: id)?.synced.sourceURL ?? syncInstalls[id]?.sourceURL
        syncInstalls[id] = nil
        guard let declined, let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].declinedSyncSource = declined
        persist()
    }

    /// Downloads and checks every plugin concurrently, at most
    /// `maximumConcurrentSyncInstalls` at a time. Downloads and script checks
    /// run away from the main actor; one failure fails only its plugin.
    private func prepareSyncedInstalls(_ plugins: [SyncedPlugin]) async -> [String: Result<InstallPreview, any Error>] {
        guard !plugins.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, Result<InstallPreview, any Error>).self) { group in
            var results: [String: Result<InstallPreview, any Error>] = [:]
            var pending = plugins[...]
            var running = 0
            while let plugin = pending.popFirst() {
                // At the limit, start the next one only when one finishes.
                if running == Self.maximumConcurrentSyncInstalls, let finished = await group.next() {
                    results[finished.0] = finished.1
                    running -= 1
                }
                group.addTask { await self.prepareSyncedInstall(plugin) }
                running += 1
            }
            for await finished in group { results[finished.0] = finished.1 }
            return results
        }
    }

    private func prepareSyncedInstall(_ plugin: SyncedPlugin) async -> (String, Result<InstallPreview, any Error>) {
        do {
            let preview = try await prepareInstall(from: plugin.sourceURL, origin: .settings)
            guard preview.config.id == plugin.pluginID else {
                throw InstallError.invalid("The plugin at \(plugin.sourceURL) is no longer “\(plugin.pluginID)”.")
            }
            return (plugin.pluginID, .success(preview))
        } catch {
            Logger.plugin.error("sync_install_failed plugin=\(plugin.pluginID, privacy: .public) error=\(error.localizedDescription)")
            return (plugin.pluginID, .failure(error))
        }
    }
}

/// A synced plugin record: its key, and the plugin, or nil for a removal.
struct PluginSyncChange: Sendable {
    let key: RecordKey
    let plugin: SyncedPlugin?
}

/// A plugin another device has that this one is installing, or failed to.
/// Sources lists these until they install: installing (with a spinner)
/// while `failure` is nil, then the error; sync retries failures.
struct SyncInstall: Equatable, Identifiable, Sendable {
    let pluginID: String
    let sourceURL: String
    var failure: String?
    /// Set when the download would replace this device's own copy of the
    /// plugin, from another source: nothing changes until the user picks.
    var confirmation: Confirmation?

    struct Confirmation: Equatable, Sendable {
        /// Where this device's copy came from.
        let replacing: String
        /// What installing it would warn about (different author, ...).
        let warnings: [String]
    }
    var id: String { pluginID }

    /// What to call it before its config is known.
    var displayName: String {
        guard let url = URL(string: sourceURL) else { return sourceURL }
        let file = url.deletingPathExtension().lastPathComponent
        let name = file.hasSuffix("Config") ? String(file.dropLast("Config".count)) : file
        return name.isEmpty ? (url.host ?? sourceURL) : name
    }
}

/// The installed plugins' credentials, read at launch away from the main
/// actor: two credential-store reads per plugin add up, and the login
/// keychain can be slow to answer.
struct PreloadedPluginCredentials: Sendable {
    var credentials: [String: PluginManager.PluginCredentials] = [:]
    var failure: (any Error)?

    @concurrent
    static func load(pluginIDs: [String], from store: any CredentialStore, namespace: String) async -> Self {
        var preloaded = Self()
        for id in pluginIDs {
            var loaded = PluginManager.PluginCredentials()
            do {
                loaded.auth = try store.loadSourceAuth(pluginID: id, kind: "auth", namespace: namespace)
                loaded.captcha = try store.loadSourceAuth(pluginID: id, kind: "captcha", namespace: namespace)
            } catch {
                // As on the main path: reported once, remembered as empty.
                preloaded.failure = preloaded.failure ?? error
            }
            preloaded.credentials[id] = loaded
        }
        return preloaded
    }
}

/// Fetches a plugin download: the config or script. Runs off the main actor.
typealias PluginFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
