import Foundation
import JavaScriptCore

/// Hosts one plugin in its own JavaScriptCore context.
///
/// A JSContext is not thread-safe, so every touch of it happens on `queue`. Plugin code is synchronous (it blocks on
/// HTTP calls), which is why calls from the UI are exposed as async wrappers around that queue.
final class PluginRuntime: @unchecked Sendable {
    let config: PluginConfig
    private let script: String
    private let storedSettings: [String: String]
    private let auth: SourceAuth?
    private let captcha: SourceAuth?
    private let queue: DispatchQueue

    private var context: JSContext?
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
        self.queue = DispatchQueue(label: "app.jaybird.plugin.\(config.id)", qos: .userInitiated)
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
        guard let ctx = JSContext() else { throw PluginError.execution("Could not create a JavaScript context") }
        ctx.name = "Plugin: \(config.name)"
        let host = HostHTTP(config: config, auth: auth, captcha: captcha)

        let native = JSValue(newObjectIn: ctx)!
        let logBlock: @convention(block) (String) -> Void = { [weak self] s in self?.onLog?(s) }
        let toastBlock: @convention(block) (String) -> Void = { [weak self] s in self?.onToast?(s) }
        let loggedInBlock: @convention(block) () -> Bool = { [weak self] in self?.isLoggedIn ?? false }
        let hasPackageBlock: @convention(block) (String) -> Bool = { [weak self] n in self?.installedPackages.contains(n) ?? false }
        let sleepBlock: @convention(block) (Double) -> Void = { ms in Thread.sleep(forTimeInterval: max(0, ms) / 1000) }
        let httpBlock: @convention(block) (String, Bool) -> String = { json, parallel in host.execute(json: json, parallel: parallel) }
        let setTimeoutBlock: @convention(block) (JSValue, Double) -> Int = { [weak self] fn, ms in
            guard let self else { return 0 }
            self.timerSeq += 1
            let id = self.timerSeq
            self.queue.asyncAfter(deadline: .now() + max(0, ms) / 1000) { [weak self] in
                guard let self, self.context != nil, !self.cancelledTimers.contains(id) else { return }
                _ = fn.call(withArguments: [])
                if let ctx = self.context, ctx.exception != nil { ctx.exception = nil }
            }
            return id
        }
        let clearTimeoutBlock: @convention(block) (Int) -> Void = { [weak self] id in self?.cancelledTimers.insert(id) }

        native.setObject(logBlock, forKeyedSubscript: "log" as NSString)
        native.setObject(toastBlock, forKeyedSubscript: "toast" as NSString)
        native.setObject(loggedInBlock, forKeyedSubscript: "isLoggedIn" as NSString)
        native.setObject(hasPackageBlock, forKeyedSubscript: "hasPackage" as NSString)
        native.setObject(sleepBlock, forKeyedSubscript: "sleep" as NSString)
        native.setObject(httpBlock, forKeyedSubscript: "http" as NSString)
        native.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)
        native.setObject(clearTimeoutBlock, forKeyedSubscript: "clearTimeout" as NSString)
        ctx.setObject(native, forKeyedSubscript: "__native" as NSString)
        context = ctx

        do {
            try eval(Self.loadPrelude(), name: "prelude.js")

            for p in config.packages {
                guard installPackage(p) else { throw PluginError.compilation("Unsupported plugin package \"\(p)\" on iOS") }
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

            if let snap = ctx.evaluateScript("__jb.capabilitySnapshot()")?.toString(),
               let d = snap.data(using: .utf8),
               let m = try? JSONDecoder().decode([String: Bool].self, from: d) { capabilities = m }
            started = true
        } catch {
            context = nil
            throw error
        }
    }

    private func installPackage(_ name: String) -> Bool {
        guard let ctx = context else { return false }
        switch name {
        case "Http":
            ctx.evaluateScript("var http = __makeHttp();")
        case "HttpImp":
            // libcurl-impersonate is not available on iOS; plugins get the standard client under the same name.
            ctx.evaluateScript("var httpimp = __makeHttp();")
        case "DOMParser":
            ctx.setObject(DOMParserPackage(), forKeyedSubscript: "domParser" as NSString)
        case "Utilities":
            ctx.setObject(UtilityPackage(), forKeyedSubscript: "utility" as NSString)
        default:
            return false
        }
        installedPackages.insert(name)
        return true
    }

    private func enableLocked() throws {
        try startLocked()
        if enabled { return }
        let state = savedState.map { jsString($0) } ?? "null"
        let js = "__jb.invoke('enable', JSON.stringify([plugin.config, plugin.settings, \(state)]), 'value')"
        _ = try unwrap(context?.evaluateScript(js))
        enabled = true
    }

    private func stopLocked() {
        context = nil
        started = false
        enabled = false
        cancelledTimers.removeAll()
        capabilities = [:]
    }

    // MARK: helpers (queue only)

    private func eval(_ code: String, name: String) throws {
        guard let ctx = context else { throw PluginError.execution("Runtime is not running") }
        ctx.evaluateScript(code, withSourceURL: URL(string: "jaybird://plugin/\(name.replacingOccurrences(of: " ", with: "_"))"))
        if let ex = ctx.exception {
            ctx.exception = nil
            let line = ex.objectForKeyedSubscript("line")?.toString() ?? "?"
            throw PluginError.compilation("\(ex.toString() ?? "Script error") (\(name):\(line))")
        }
    }

    /// Unwraps the `{ok, value | error}` envelope the prelude returns, yielding the JSON of `value`.
    private func unwrap(_ result: JSValue?) throws -> Data {
        if let ctx = context, let ex = ctx.exception {
            ctx.exception = nil
            throw PluginError.execution(ex.toString() ?? "Script error")
        }
        guard let text = result?.toString(), let data = text.data(using: .utf8),
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
        let bundle = Bundle(for: PluginRuntime.self)
        guard let url = bundle.url(forResource: "prelude", withExtension: "js"),
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
                let ok = self.context?.evaluateScript("__jb.has(\(jsString(name)))")?.toBool() ?? false
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
                return try self.unwrap(self.context?.evaluateScript("__jb.invoke('saveState', '[]', 'value')"))
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
            return try self.unwrap(self.context?.evaluateScript(js))
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
        try await perform { try self.unwrap(self.context?.evaluateScript("__jb.nextPage(\(handle))")) }
    }

    func callHandle(_ handle: Int, _ method: String, _ args: [Any] = []) async throws -> Data {
        try await perform {
            try self.unwrap(self.context?.evaluateScript("__jb.callHandle(\(handle), \(jsString(method)), \(jsString(try self.argsJSON(args))))"))
        }
    }

    func handlePager<Item: Decodable & Sendable>(_ handle: Int, _ method: String, _ args: [Any] = [], as item: Item.Type) async throws -> PluginPager<Item> {
        let data = try await perform {
            try self.unwrap(self.context?.evaluateScript("__jb.callHandleForPager(\(handle), \(jsString(method)), \(jsString(try self.argsJSON(args))))"))
        }
        return PluginPager(runtime: self, payload: try Self.decode(PagerPayload<Item>.self, from: data))
    }

    func subCommentsPager(handle: Int) async throws -> PluginPager<PluginComment> {
        let data = try await perform { try self.unwrap(self.context?.evaluateScript("__jb.subComments(\(handle))")) }
        return PluginPager(runtime: self, payload: try Self.decode(PagerPayload<PluginComment>.self, from: data))
    }

    struct HandleRef: Decodable { var handle: Int; var nextRequest: Int? }

    func handleFromCall(_ handle: Int, _ method: String, _ args: [Any] = []) async throws -> HandleRef? {
        let data = try await perform {
            try self.unwrap(self.context?.evaluateScript("__jb.callHandleForHandle(\(handle), \(jsString(method)), \(jsString(try self.argsJSON(args))))"))
        }
        return try Self.decode(HandleRef?.self, from: data)
    }

    func handleFromSource(_ name: String, _ args: [Any] = []) async throws -> HandleRef? {
        let data = try await perform {
            try self.enableLocked()
            return try self.unwrap(self.context?.evaluateScript("__jb.invokeForHandle(\(jsString(name)), \(jsString(try self.argsJSON(args))))"))
        }
        return try Self.decode(HandleRef?.self, from: data)
    }

    /// Reads a numeric property from a retained plugin object (e.g. a tracker's `nextRequest`).
    func intProperty(handle: Int, _ name: String) async -> Int? {
        let text: String? = try? await perform {
            self.context?.evaluateScript("__jb.getProperty(\(handle), \(jsString(name)))")?.toString()
        }
        guard let text, let v = Double(text), v.isFinite else { return nil }
        return Int(v)
    }

    func hasMember(handle: Int, _ name: String) async -> Bool {
        (try? await perform { self.context?.evaluateScript("__jb.hasMember(\(handle), \(jsString(name)))")?.toBool() ?? false }) ?? false
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
