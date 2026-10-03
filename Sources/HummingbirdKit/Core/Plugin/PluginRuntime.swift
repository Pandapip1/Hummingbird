import Foundation

/// Hosts one plugin in its own JavaScript context (JavaScriptCore or QuickJS, see `JSEngines`).
///
/// A JS context is not thread-safe, so every touch of it happens on `queue`. Plugin code is synchronous (it blocks on
/// HTTP calls), which is why calls from the UI are exposed as async wrappers around that queue.
final class PluginRuntime: @unchecked Sendable {
    let config: PluginConfig
    private let script: String
    private let storedSettings: [String: String]
    private let auth: SourceAuth?
    private let captcha: SourceAuth?
    private let queue: DispatchQueue

    private var context: JSContextHost?
    private let dom = DOMStore()
    private var http: HostHTTP?
    private var started = false
    private var enabled = false
    private var savedState: String?
    private var reloadData: String?
    private var installedPackages = Set<String>()
    private var timerSeq = 0
    private var cancelledTimers = Set<Int>()
    private(set) var capabilities: [String: Bool] = [:]

    var onToast: (@Sendable (String) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    /// Used by tests to supply the prelude without a bundle.
    static var preludeOverride: String?

    var isLoggedIn: Bool { auth != nil }
    var id: String { config.id }

    init(config: PluginConfig, script: String, settings: [String: String], auth: SourceAuth?, captcha: SourceAuth?, savedState: String? = nil) {
        self.config = config
        self.script = script
        self.storedSettings = settings
        self.auth = auth
        self.captcha = captcha
        self.savedState = savedState
        self.queue = DispatchQueue(label: "app.hummingbird.plugin.\(config.id)", qos: .userInitiated)
    }

    // MARK: settings

    /// Declared settings with their stored value, or the declared default when nothing is stored.
    private func settingsWithDefaults() -> [String: String] {
        var out: [String: String] = [:]
        for s in config.settings {
            if let v = storedSettings[s.key] { out[s.key] = v }
            else if let d = s.default { out[s.key] = d }
        }
        return out
    }

    // MARK: lifecycle (call only on `queue`)

    private func startLocked() throws {
        if started { return }
        let host = HostHTTP(config: config, auth: auth, captcha: captcha)
        http = host
        let ctx: JSContextHost
        do {
            ctx = try JSEngines.default.makeContext { [weak self] name, a, b in self?.handleHostCall(name, a, b) ?? "" }
        } catch let e as JSEngineError {
            throw PluginError.execution(e.message)
        }
        context = ctx

        do {
            try eval(Self.loadPrelude(), name: "prelude.js")

            for p in config.packages {
                guard installPackage(p) else { throw PluginError.compilation("Unsupported plugin package \"\(p)\" on this platform") }
            }
            for p in config.packagesOptional { _ = installPackage(p) }

            if !config.allowEval {
                try eval("globalThis.eval = function () { throw new ScriptImplementationException('eval is not allowed by this plugin'); };", name: "eval-guard")
            }
            if let reloadData {
                try eval("var __reloadData = \(jsString(reloadData));", name: "reload-data")
            }

            let cfgData = try JSONEncoder().encode(config)
            let settingsData = try JSONSerialization.data(withJSONObject: settingsWithDefaults())
            try eval("plugin.config = \(jsLiteral(cfgData)); plugin.settings = parseSettings(\(jsLiteral(settingsData)));", name: "plugin-config")
            try eval(script, name: "\(config.name).js")

            if let snap = try ctx.evaluate("__jb.capabilitySnapshot()", name: "capabilities"),
               let d = snap.data(using: .utf8),
               let m = try? JSONDecoder().decode([String: Bool].self, from: d) { capabilities = m }
            started = true
        } catch {
            ctx.close()
            context = nil
            throw error
        }
    }

    /// The single native entry point plugin code can reach (`__hostCall` in the prelude). Runs on `queue`.
    private func handleHostCall(_ name: String, _ a: String, _ b: String) -> String {
        switch name {
        case "log": onLog?(a); return ""
        case "toast": onToast?(a); return ""
        case "isLoggedIn": return isLoggedIn ? "1" : "0"
        case "hasPackage": return installedPackages.contains(a) ? "1" : "0"
        case "sleep": Thread.sleep(forTimeInterval: max(0, Double(a) ?? 0) / 1000); return ""
        case "http": return http?.execute(json: a, parallel: b == "1") ?? "[]"
        case "setTimeout":
            guard let id = Int(a) else { return "" }
            let ms = max(0, Double(b) ?? 0)
            queue.asyncAfter(deadline: .now() + ms / 1000) { [weak self] in
                guard let self, let ctx = self.context else { return }
                _ = try? ctx.evaluate("__jb.fireTimer(\(id))", name: "timer")
            }
            return ""
        case "dom.parse": return dom.parse(a)
        case "dom.get": return dom.get(handle: Int(a) ?? 0, property: b)
        case "dom.call": return dom.call(handle: Int(a) ?? 0, argsJSON: b)
        case "dom.release": dom.release(Int(a) ?? 0); return ""
        default:
            if name.hasPrefix("util.") { return UtilityPackage.call(String(name.dropFirst(5)), a) }
            return ""
        }
    }

    private func installPackage(_ name: String) -> Bool {
        guard let ctx = context else { return false }
        let script: String
        switch name {
        case "Http": script = "var http = __makeHttp();"
        // libcurl-impersonate is not available here; plugins get the standard client under the same name.
        case "HttpImp": script = "var httpimp = __makeHttp();"
        case "DOMParser": script = "var domParser = __makeDomParser();"
        case "Utilities": script = "var utility = __makeUtility();"
        default: return false
        }
        do { _ = try ctx.evaluate(script, name: "package-\(name)") } catch { return false }
        installedPackages.insert(name)
        return true
    }

    private func enableLocked() throws {
        try startLocked()
        if enabled { return }
        let state = savedState.map { jsString($0) } ?? "null"
        let js = "__jb.invoke('enable', JSON.stringify([plugin.config, plugin.settings, \(state)]), 'value')"
        _ = try unwrap(try evalResult(js))
        enabled = true
    }

    private func stopLocked() {
        context?.close()
        context = nil
        dom.removeAll()
        started = false
        enabled = false
        cancelledTimers.removeAll()
        capabilities = [:]
    }

    // MARK: helpers (queue only)

    private func eval(_ code: String, name: String) throws {
        guard let ctx = context else { throw PluginError.execution("Runtime is not running") }
        do { _ = try ctx.evaluate(code, name: name.replacingOccurrences(of: " ", with: "_")) }
        catch let e as JSEngineError { throw PluginError.compilation("\(e.message) (\(name):\(e.line ?? "?"))") }
    }

    /// Evaluates host-generated glue code and returns its string result.
    private func evalResult(_ code: String) throws -> String? {
        guard let ctx = context else { throw PluginError.execution("Runtime is not running") }
        do { return try ctx.evaluate(code, name: "host") }
        catch let e as JSEngineError { throw PluginError.execution(e.message) }
    }

    /// Unwraps the `{ok, value | error}` envelope the prelude returns, yielding the JSON of `value`.
    private func unwrap(_ result: String?) throws -> Data {
        guard let text = result, let data = text.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.execution("The plugin returned an unreadable result")
        }
        if (env["ok"] as? Bool) == true {
            let value = env["value"] ?? NSNull()
            return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        }
        if let err = env["error"], let ed = try? JSONSerialization.data(withJSONObject: err),
           let payload = try? JSONDecoder().decode(PluginError.Payload.self, from: ed) {
            throw PluginError(payload: payload)
        }
        throw PluginError.execution("The plugin failed")
    }

    private static func loadPrelude() throws -> String {
        if let o = preludeOverride { return o }
        guard let url = Bundle.module.url(forResource: "prelude", withExtension: "js"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            throw PluginError.execution("prelude.js is missing from the app bundle")
        }
        return src
    }

    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func argsJSON(_ args: [Any]) throws -> String {
        let d = try JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed])
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: public API

    /// Starts the runtime, runs `source.enable`, and returns the detected capabilities.
    @discardableResult
    func enable() async throws -> [String: Bool] {
        try await perform { try self.enableLocked(); return self.capabilities }
    }

    func has(_ capability: String) -> Bool { capabilities[capability] ?? false }

    /// Checks that the functions every plugin must provide exist.
    func validate() async throws {
        let required = ["getHome", "search", "isChannelUrl", "getChannel", "getChannelContents", "isContentDetailsUrl", "getContentDetails"]
        try await perform {
            try self.startLocked()
            for name in required {
                let ok = (try self.evalResult("__jb.has(\(jsString(name)))")) == "true"
                if !ok { throw PluginError.compilation("Plugin is missing required function source.\(name)") }
            }
        }
    }

    func stop() async { await withCheckedContinuation { c in queue.async { self.stopLocked(); c.resume() } } }

    /// Restarts the runtime; `reloadData` becomes the global `__reloadData` seen by the script (ReloadRequiredException).
    func reload(reloadData: String?) async {
        await withCheckedContinuation { c in queue.async { self.stopLocked(); self.reloadData = reloadData; c.resume() } }
    }

    func saveState() async -> String? {
        guard has("saveState") else { return nil }
        do {
            let data: Data = try await perform {
                try self.enableLocked()
                return try self.unwrap(try self.evalResult("__jb.invoke('saveState', '[]', 'value')"))
            }
            return try? JSONDecoder().decode(String.self, from: data)
        } catch {
            return nil
        }
    }

    /// Invokes `source.<name>(...args)`; `kind` is "value", "pager" or "details". Returns the JSON of the result.
    func callRaw(_ name: String, _ args: [Any] = [], kind: String = "value") async throws -> Data {
        try await perform {
            try self.enableLocked()
            let js = "__jb.invoke(\(jsString(name)), \(jsString(try self.argsJSON(args))), \(jsString(kind)))"
            return try self.unwrap(try self.evalResult(js))
        }
    }

    func call<T: Decodable>(_ name: String, _ args: [Any] = [], as type: T.Type = T.self) async throws -> T {
        try Self.decode(T.self, from: try await callRaw(name, args))
    }

    func pager<Item: Decodable & Sendable>(_ name: String, _ args: [Any] = [], as item: Item.Type) async throws -> PluginPager<Item> {
        let data = try await callRaw(name, args, kind: "pager")
        return PluginPager(runtime: self, payload: try Self.decode(PagerPayload<Item>.self, from: data))
    }

    func nextPageRaw(handle: Int) async throws -> Data {
        try await perform { try self.unwrap(try self.evalResult("__jb.nextPage(\(handle))")) }
    }

    func callHandle(_ handle: Int, _ method: String, _ args: [Any] = []) async throws -> Data {
        try await perform {
            try self.unwrap(try self.evalResult("__jb.callHandle(\(handle), \(jsString(method)), \(jsString(try self.argsJSON(args))))"))
        }
    }

    func handlePager<Item: Decodable & Sendable>(_ handle: Int, _ method: String, _ args: [Any] = [], as item: Item.Type) async throws -> PluginPager<Item> {
        let data = try await perform {
            try self.unwrap(try self.evalResult("__jb.callHandleForPager(\(handle), \(jsString(method)), \(jsString(try self.argsJSON(args))))"))
        }
        return PluginPager(runtime: self, payload: try Self.decode(PagerPayload<Item>.self, from: data))
    }

    func subCommentsPager(handle: Int) async throws -> PluginPager<PluginComment> {
        let data = try await perform { try self.unwrap(try self.evalResult("__jb.subComments(\(handle))")) }
        return PluginPager(runtime: self, payload: try Self.decode(PagerPayload<PluginComment>.self, from: data))
    }

    struct HandleRef: Decodable { var handle: Int; var nextRequest: Int? }

    func handleFromCall(_ handle: Int, _ method: String, _ args: [Any] = []) async throws -> HandleRef? {
        let data = try await perform {
            try self.unwrap(try self.evalResult("__jb.callHandleForHandle(\(handle), \(jsString(method)), \(jsString(try self.argsJSON(args))))"))
        }
        return try Self.decode(HandleRef?.self, from: data)
    }

    func handleFromSource(_ name: String, _ args: [Any] = []) async throws -> HandleRef? {
        let data = try await perform {
            try self.enableLocked()
            return try self.unwrap(try self.evalResult("__jb.invokeForHandle(\(jsString(name)), \(jsString(try self.argsJSON(args))))"))
        }
        return try Self.decode(HandleRef?.self, from: data)
    }

    /// Reads a numeric property from a retained plugin object (e.g. a tracker's `nextRequest`).
    func intProperty(handle: Int, _ name: String) async -> Int? {
        let text: String? = try? await perform {
            try self.evalResult("__jb.getProperty(\(handle), \(jsString(name)))")
        }
        guard let text, let v = Double(text), v.isFinite else { return nil }
        return Int(v)
    }

    func hasMember(handle: Int, _ name: String) async -> Bool {
        (try? await perform { (try self.evalResult("__jb.hasMember(\(handle), \(jsString(name)))")) == "true" }) ?? false
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PluginError.execution("Unexpected data from the plugin: \(error.localizedDescription)") }
    }
}

// MARK: - JS literal helpers

/// A JS string literal for `s` (JSON string syntax, with the two line separators JS treats specially escaped).
func jsString(_ s: String) -> String {
    let d = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
    return jsLiteral(d)
}

/// Embeds JSON text in a script.
func jsLiteral(_ json: Data) -> String {
    String(decoding: json, as: UTF8.self)
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
}
