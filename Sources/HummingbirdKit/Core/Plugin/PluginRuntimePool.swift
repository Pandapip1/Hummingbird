import Foundation
import Synchronization
import os

/// A plugin, run in a small pool of JavaScript contexts so calls do not wait
/// for each other.
///
/// Each context (`PluginContextWorker`) is a full plugin instance with the
/// same immutable inputs, given explicitly: configuration, settings, saved
/// state and sign-in/captcha data. A call to the plugin (`getContentDetails`,
/// `search`, a pager's first page…) takes a context that is not busy, or
/// starts a new one up to `maximumContexts`, so a slow call (YouTube's
/// details, 10 s or more) never blocks another (comments, a request
/// modifier for a download). Calls on an object the plugin returned (a
/// handle: details, pagers, request modifiers, executors, trackers) go to the
/// context that made it: each context hands out handles from its own range.
/// Contexts stay warm between calls, so a plugin's in-memory caches (YouTube's
/// cipher) keep their value, as with Grayjay's plugin copies.
final class PluginRuntime: Sendable {
    /// Contexts per plugin. Each costs a JavaScript heap; four keeps memory
    /// bounded while letting details, comments, related videos and playback
    /// requests run side by side.
    static let maximumContexts = 4
    /// Handles of context `n` are `n * handleSpan + 1…`.
    static let handleSpan = 1_000_000_000

    struct HandleRef: Decodable, Sendable { var handle: Int; var nextRequest: Int? }

    let config: PluginConfig
    let appliedCompatibilityPatches: [String]
    let failedCompatibilityPatches: [String]
    let detailsCacheFingerprint: String
    let isLoggedIn: Bool

    private struct Inputs: Sendable {
        let script: String
        let settings: [String: String]
        let auth: SourceAuth?
        let captcha: SourceAuth?
        let savedState: String?
        let localNetworkAccess: (@Sendable (URL) async -> Bool)?
        let httpSession: URLSession?
    }
    private let inputs: Inputs

    private struct State {
        var workers: [PluginContextWorker]
        var busy: [Int]
        var onToast: (@Sendable (String) -> Void)?
        var onLog: (@Sendable (String) -> Void)?
    }
    private let state: Mutex<State>

    init(config: PluginConfig, script: String, settings: [String: String], auth: SourceAuth?, captcha: SourceAuth?,
         savedState: String? = nil, localNetworkAccess: (@Sendable (URL) async -> Bool)? = nil,
         httpSession: URLSession? = nil) {
        let inputs = Inputs(script: script, settings: settings, auth: auth, captcha: captcha, savedState: savedState,
                            localNetworkAccess: localNetworkAccess, httpSession: httpSession)
        let first = Self.makeWorker(config: config, inputs: inputs, index: 0)
        self.config = config
        self.inputs = inputs
        appliedCompatibilityPatches = first.appliedCompatibilityPatches
        failedCompatibilityPatches = first.failedCompatibilityPatches
        detailsCacheFingerprint = first.detailsCacheFingerprint
        isLoggedIn = auth != nil
        state = Mutex(State(workers: [first], busy: [0]))
    }

    private static func makeWorker(config: PluginConfig, inputs: Inputs, index: Int) -> PluginContextWorker {
        PluginContextWorker(config: config, script: inputs.script, settings: inputs.settings, auth: inputs.auth,
                            captcha: inputs.captcha, savedState: inputs.savedState,
                            localNetworkAccess: inputs.localNetworkAccess, httpSession: inputs.httpSession,
                            handleBase: index * handleSpan)
    }

    var id: String { config.id }

    var onToast: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onToast } }
        set {
            let workers = state.withLock { state in state.onToast = newValue; return state.workers }
            for worker in workers { worker.onToast = newValue }
        }
    }

    var onLog: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onLog } }
        set {
            let workers = state.withLock { state in state.onLog = newValue; return state.workers }
            for worker in workers { worker.onLog = newValue }
        }
    }

    /// Capabilities detected when the plugin was enabled (first context).
    var capabilities: [String: Bool] { primary.capabilities }
    func has(_ capability: String) -> Bool { primary.has(capability) }

    private var primary: PluginContextWorker { state.withLock { $0.workers[0] } }

    /// Contexts started so far (tests, diagnostics).
    var contextCount: Int { state.withLock { $0.workers.count } }

    // MARK: routing

    /// Runs a call on a context that is not busy, starting one if needed.
    private func onFreeContext<T>(_ body: (PluginContextWorker) async throws -> T) async throws -> T {
        let (index, worker) = state.withLock { state -> (Int, PluginContextWorker) in
            if let free = state.busy.firstIndex(of: 0) {
                state.busy[free] += 1
                return (free, state.workers[free])
            }
            if state.workers.count < Self.maximumContexts {
                let index = state.workers.count
                let worker = Self.makeWorker(config: config, inputs: inputs, index: index)
                worker.onToast = state.onToast
                worker.onLog = state.onLog
                state.workers.append(worker)
                state.busy.append(1)
                return (index, worker)
            }
            let least = state.busy.indices.min { state.busy[$0] < state.busy[$1] } ?? 0
            state.busy[least] += 1
            return (least, state.workers[least])
        }
        defer { state.withLock { $0.busy[index] -= 1 } }
        return try await body(worker)
    }

    /// Runs a call on the context that made `handle`.
    private func onOwner<T>(of handle: Int, _ body: (PluginContextWorker) async throws -> T) async throws -> T {
        let index = max(0, (handle - 1) / Self.handleSpan)
        let worker: PluginContextWorker? = state.withLock { state in
            guard index < state.workers.count else { return nil }
            state.busy[index] += 1
            return state.workers[index]
        }
        guard let worker else { throw PluginError.execution("The plugin object is no longer available") }
        defer { state.withLock { $0.busy[index] -= 1 } }
        return try await body(worker)
    }

    // MARK: lifecycle

    /// Starts the plugin (first context) and returns the detected capabilities.
    @discardableResult
    func enable() async throws -> [String: Bool] { try await primary.enable() }

    func validate() async throws { try await primary.validate() }

    func stop() async {
        for worker in state.withLock({ $0.workers }) { await worker.stop() }
    }

    /// A separate plugin instance with the same inputs and its own contexts.
    func isolatedClone() -> PluginRuntime {
        let clone = PluginRuntime(config: config, script: inputs.script, settings: inputs.settings, auth: inputs.auth,
                                  captcha: inputs.captcha, savedState: inputs.savedState,
                                  localNetworkAccess: inputs.localNetworkAccess, httpSession: inputs.httpSession)
        clone.onLog = onLog
        clone.onToast = onToast
        return clone
    }

    /// Restarts every context; `reloadData` becomes `__reloadData`. Handles
    /// from before are gone, as with a single context.
    func reload(reloadData: String?) async {
        for worker in state.withLock({ $0.workers }) { await worker.reload(reloadData: reloadData) }
    }

    func saveState() async -> String? { await primary.saveState() }

    // MARK: calls

    func callRaw(_ name: String, _ args: [Any] = [], kind: String = "value") async throws -> Data {
        let arguments = SendableArguments(args)
        return try await onFreeContext { try await $0.callRaw(name, arguments.values, kind: kind) }
    }

    func call<T: Decodable>(_ name: String, _ args: [Any] = [], as type: T.Type = T.self) async throws -> T {
        try Self.decode(T.self, from: try await callRaw(name, args))
    }

    func pager<Item: Decodable & Sendable>(_ name: String, _ args: [Any] = [], as item: Item.Type) async throws -> PluginPager<Item> {
        let arguments = SendableArguments(args)
        let data = try await onFreeContext { try await $0.pagerRaw(name, arguments.values) }
        return PluginPager(runtime: self, payload: try Self.decode(PagerPayload<Item>.self, from: data))
    }

    func nextPageRaw(handle: Int) async throws -> Data {
        try await onOwner(of: handle) { try await $0.nextPageRaw(handle: handle) }
    }

    func callHandle(_ handle: Int, _ method: String, _ args: [Any] = []) async throws -> Data {
        let arguments = SendableArguments(args)
        return try await onOwner(of: handle) { try await $0.callHandle(handle, method, arguments.values) }
    }

    func callHandleBytes(_ handle: Int, _ method: String, _ args: [Any] = []) async throws -> Data {
        let arguments = SendableArguments(args)
        return try await onOwner(of: handle) { try await $0.callHandleBytes(handle, method, arguments.values) }
    }

    func handlePager<Item: Decodable & Sendable>(_ handle: Int, _ method: String, _ args: [Any] = [], as item: Item.Type) async throws -> PluginPager<Item> {
        let arguments = SendableArguments(args)
        let data = try await onOwner(of: handle) { try await $0.handlePagerRaw(handle, method, arguments.values) }
        return PluginPager(runtime: self, payload: try Self.decode(PagerPayload<Item>.self, from: data))
    }

    func subCommentsPager(handle: Int) async throws -> PluginPager<PluginComment> {
        let data = try await onOwner(of: handle) { try await $0.subCommentsRaw(handle: handle) }
        return PluginPager(runtime: self, payload: try Self.decode(PagerPayload<PluginComment>.self, from: data))
    }

    func handleFromCall(_ handle: Int, _ method: String, _ args: [Any] = []) async throws -> HandleRef? {
        let arguments = SendableArguments(args)
        return try await onOwner(of: handle) { try await $0.handleFromCall(handle, method, arguments.values) }
    }

    func handleFromSource(_ name: String, _ args: [Any] = []) async throws -> HandleRef? {
        let arguments = SendableArguments(args)
        return try await onFreeContext { try await $0.handleFromSource(name, arguments.values) }
    }

    func intProperty(handle: Int, _ name: String) async -> Int? {
        try? await onOwner(of: handle) { await $0.intProperty(handle: handle, name) }
    }

    func hasMember(handle: Int, _ name: String) async -> Bool {
        (try? await onOwner(of: handle) { await $0.hasMember(handle: handle, name) }) ?? false
    }

    // MARK: decoding

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PluginError.execution("Unexpected data from the plugin: \(error.localizedDescription)") }
    }

    /// Decodes away from the caller's actor: plugin payloads (details, pages)
    /// can be large.
    static func decodeOffMain<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try decode(type, from: data) }.value
    }
}

/// Plugin call arguments: JSON-compatible values (strings, numbers, booleans,
/// arrays, dictionaries, NSNull) that are serialized before they cross into a
/// context, so they never cross isolation as live objects.
private struct SendableArguments: Sendable {
    private let json: Data

    init(_ values: [Any]) {
        json = (try? JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed])) ?? Data("[]".utf8)
    }

    var values: [Any] {
        (try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])) as? [Any] ?? []
    }
}
