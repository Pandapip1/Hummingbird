import Foundation
import Observation

/// A plugin as stored on this device.
struct InstalledPlugin: Codable, Identifiable, Hashable {
    var config: PluginConfig
    var script: String
    /// Stored setting values (JSON text as the script will see it before parsing). Missing keys use the declared default.
    var settings: [String: String] = [:]
    var enabled: Bool = true
    var iconURL: String?
    var installedAt: Date = Date()
    /// Newer version found by the last update check.
    var availableVersion: Int?
    var id: String { config.id }
}

struct InstallPreview: Identifiable {
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
    /// Invalidates credential-derived UI after login or logout. Credentials
    /// live outside the observable plugin array, so views otherwise keep the
    /// state they read during their previous body evaluation.
    private(set) var credentialRevision = 0

    @ObservationIgnored private var runtimes: [String: PluginRuntime] = [:]
    @ObservationIgnored private let urlSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    struct CaptchaRequest: Identifiable {
        let id = UUID()
        let pluginID: String
        let url: String?
        let body: String?
    }

    init() {
        installed = Storage.load([InstalledPlugin].self, name: "plugins") ?? []
    }

    private func persist() { Storage.save(installed, name: "plugins") }

    // MARK: lookup

    func plugin(_ id: String) -> InstalledPlugin? { installed.first { $0.id == id } }
    var enabledPlugins: [InstalledPlugin] { installed.filter { $0.enabled } }

    /// The running runtime for a plugin, created on first use.
    func runtime(for id: String) -> PluginRuntime? {
        if let r = runtimes[id] { return r }
        guard let p = plugin(id) else { return nil }
        let r = PluginRuntime(config: p.config, script: p.script, settings: p.settings,
                              auth: AuthKeychain.load(pluginID: id, kind: "auth"),
                              captcha: AuthKeychain.load(pluginID: id, kind: "captcha"))
        r.onToast = { [weak self] msg in Task { @MainActor in self?.toast = msg } }
        r.onLog = { msg in
            #if DEBUG
            print("[plugin \(id)] \(msg)")
            #endif
        }
        runtimes[id] = r
        return r
    }

    func enabledRuntimes(where predicate: (PluginConfig) -> Bool = { _ in true }) -> [PluginRuntime] {
        enabledPlugins.filter { predicate($0.config) }.compactMap { runtime(for: $0.id) }
    }

    /// Discards the running runtime so the next call starts a fresh one with current settings and credentials.
    func invalidate(_ id: String) {
        if let r = runtimes.removeValue(forKey: id) { Task { await r.stop() } }
    }

    // MARK: install

    /// Downloads and checks a plugin. Nothing is stored until `commit` is called.
    func prepareInstall(from rawURL: String) async throws -> InstallPreview {
        var text = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // QR codes may wrap the config URL; accept the config URL directly or after a custom-scheme prefix.
        if let r = text.range(of: "grayjay://plugin/") { text = String(text[r.upperBound...]).removingPercentEncoding ?? String(text[r.upperBound...]) }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme) else { throw InstallError.badURL }

        let configData: Data
        do { configData = try await download(url) } catch { throw InstallError.download(error.localizedDescription) }
        var config: PluginConfig
        do { config = try JSONDecoder().decode(PluginConfig.self, from: configData) }
        catch { throw InstallError.invalidConfig(error.localizedDescription) }
        if config.sourceUrl == nil || config.sourceUrl?.isEmpty == true { config.sourceUrl = url.absoluteString }

        let base = URL(string: config.sourceUrl ?? "") ?? url
        guard let scriptURL = config.resolve(config.scriptUrl, base: base) else { throw InstallError.invalidConfig("scriptUrl is missing") }
        let scriptData: Data
        do { scriptData = try await download(scriptURL) } catch { throw InstallError.download(error.localizedDescription) }
        guard let script = String(data: scriptData, encoding: .utf8), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstallError.emptyScript
        }

        var signatureValid: Bool?
        if let sig = config.scriptSignature, let key = config.scriptPublicKey, !sig.isEmpty, !key.isEmpty {
            signatureValid = ScriptSignature.verify(script: script, signatureBase64: sig, publicKeyBase64: key)
            if signatureValid == false { throw InstallError.invalidSignature }
        }

        var warnings = config.warnings(signatureValid: signatureValid)
        let existing = plugin(config.id)
        if let existing, let old = existing.config.scriptPublicKey, !old.isEmpty, old != (config.scriptPublicKey ?? "") {
            warnings.insert(("Different author", "This plugin is signed with a different key than the version you have installed."), at: 0)
        }
        // Dry run so unsupported packages or missing entry points are reported before installing.
        let probe = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        do { try await probe.validate() } catch { await probe.stop(); throw InstallError.invalid(error.localizedDescription) }
        await probe.stop()

        return InstallPreview(config: config, script: script,
                              iconURL: config.resolve(config.iconUrl, base: base)?.absoluteString,
                              warnings: warnings, existing: existing)
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
        invalidate(entry.id)
        persist()
    }

    func remove(_ id: String) {
        invalidate(id)
        installed.removeAll { $0.id == id }
        AuthKeychain.save(nil, pluginID: id, kind: "auth")
        AuthKeychain.save(nil, pluginID: id, kind: "captcha")
        persist()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[i].enabled = on
        if !on { invalidate(id) }
        persist()
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
    }

    // MARK: credentials

    func isLoggedIn(_ id: String) -> Bool {
        _ = credentialRevision
        return AuthKeychain.load(pluginID: id, kind: "auth") != nil
    }

    func saveAuth(_ auth: SourceAuth, pluginID: String) {
        AuthKeychain.save(auth, pluginID: pluginID, kind: "auth")
        credentialRevision &+= 1
        invalidate(pluginID)
        pendingLogin = nil
    }

    func saveCaptcha(_ data: SourceAuth, pluginID: String) {
        AuthKeychain.save(data, pluginID: pluginID, kind: "captcha")
        invalidate(pluginID)
        pendingCaptcha = nil
    }

    func logout(_ id: String) {
        AuthKeychain.save(nil, pluginID: id, kind: "auth")
        credentialRevision &+= 1
        invalidate(id)
    }

    // MARK: updates

    /// Re-downloads each plugin's config and records newer versions. The user applies them explicitly.
    func checkForUpdates() async {
        for p in installed {
            _ = try? await checkForUpdate(p.id)
        }
    }

    /// Checks one plugin immediately and reports whether a newer version exists.
    @discardableResult
    func checkForUpdate(_ id: String) async throws -> Int? {
        guard let p = plugin(id), let src = p.config.sourceUrl,
              let url = URL(string: src) else { throw InstallError.badURL }
        let data = try await download(url)
        let fresh: PluginConfig
        do { fresh = try JSONDecoder().decode(PluginConfig.self, from: data) }
        catch { throw InstallError.invalidConfig(error.localizedDescription) }
        let available = fresh.version > p.config.version ? fresh.version : nil
        if let i = installed.firstIndex(where: { $0.id == id }) {
            installed[i].availableVersion = available
            persist()
        }
        return available
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

    private func download(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Hummingbird/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await urlSession.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError.download("HTTP \(http.statusCode) from \(url.host ?? url.absoluteString)")
        }
        return data
    }
}
