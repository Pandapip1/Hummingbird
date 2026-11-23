import Foundation
import PluginEngine
import os
import Crypto
import Synchronization
import PlatformSupport

/// Hosts one plugin as a small pool of isolated JavaScript contexts (`PluginWorker`), so calls run in
/// parallel and one stuck call cannot hold up the others.
///
/// Workers share only what is passed to them explicitly: the config, settings, saved state, reload data, and
/// the plugin's HTTP client (`HostHTTP`: its auth and captcha cookies and its cookie jars). Nothing else
/// crosses between contexts. Handles a call returns (pagers, details, sources, trackers) carry the serial of
/// the worker that made them, so follow-up calls reach that same context.
///
/// Containment (Documentation/PluginSecurity.md): every call has a deadline; a worker that misses it is
/// abandoned (its host calls fail from then on and it never serves another call) and replaced. A plugin
/// with `PluginLimits.maximumHungWorkers` abandoned workers still running is suspended: its calls fail
/// with `PluginError.unresponsive` until the user retries. Results are size-bounded and decoded only into
/// `PluginOutput` types, which contain themselves against this plugin's identity and network policy.
final class PluginRuntime: @unchecked Sendable {
    let config: PluginConfig
    /// The plugin's script exactly as published: workers evaluate these
    /// bytes and nothing else, so no code can rewrite a plugin.
    let checkedScript: CheckedScript
    var script: String { checkedScript.text }
    let storedSettings: [String: String]
    /// The source-access policy's permission to run, kept so clones run
    /// under the same decision.
    let approval: LoadApproval
    let auth: SourceAuth?
    let captcha: SourceAuth?
    let approvals: [LocalHostApproval]
    let resolver: any HostResolving
    /// Asked before each request to an approved local-network host; nil lets them through.
    let localNetworkAccess: (@Sendable (URL) async -> Bool)?
    /// The URL session plugin HTTP goes through; nil uses HostHTTP's own (proxied).
    /// Tests pass a session with a stub protocol so no request reaches the network.
    let httpSession: URLSession?
    let policy: PluginNetworkPolicy
    let timeouts: Timeouts
    /// The engine this plugin's contexts run in: its own host process where the platform has process
    /// isolation (`PluginExecutionLimits`), killed when a call overruns; else in-process.
    let engine: any JSEngine

    /// How long calls may take (`PluginLimits`); tests shorten them.
    struct Timeouts: Sendable {
        var call = PluginLimits.callTimeout
        var enable = PluginLimits.enableTimeout
        var requestModifier = PluginLimits.requestModifierTimeout
        static let standard = Timeouts()
    }
    let detailsCacheFingerprint: String

    private let lock = NSLock()
    private var workers: [PluginWorker] = []
    private var nextSerial = 1
    private var http: HostHTTP?
    /// Workers taken out of service whose script has not returned yet.
    private var hungWorkers = Set<ObjectIdentifier>()
    private var suspendedMessage: String?
    private var savedState: String?
    private var reloadData: String?
    private var capabilitiesSnapshot: [String: Bool] = [:]
    /// Virtual machines whose calls all ended cleanly, ready for another call's fresh context (script
    /// caching: the plugin's script is already compiled in them). At most
    /// `PluginLimits.maximumIdleMachines`; a machine serves one call (and its continuations) at a time.
    private var idleMachines: [JSMachine] = []
    private var machineCounts = (reused: 0, dropped: 0)
    private var callbacks: (toast: (@Sendable (String) -> Void)?, log: (@Sendable (String) -> Void)?) = (nil, nil)

    var onToast: (@Sendable (String) -> Void)? {
        get { lock.withLock { callbacks.toast } }
        set { lock.withLock { callbacks.toast = newValue } }
    }
    var onLog: (@Sendable (String) -> Void)? {
        get { lock.withLock { callbacks.log } }
        set { lock.withLock { callbacks.log = newValue } }
    }

    var capabilities: [String: Bool] { lock.withLock { capabilitiesSnapshot } }
    var isLoggedIn: Bool { auth != nil }
    var id: String { config.id }
    var outputContext: PluginOutputContext { PluginOutputContext(pluginID: config.id, policy: policy) }

    /// Whether the plugin stopped responding and is waiting for the user to retry.
    var isSuspended: Bool { lock.withLock { suspendedMessage != nil } }

    /// Contexts alive now: running calls and retained sessions.
    var liveContextCountForTesting: Int { lock.withLock { workers.count } }

    /// Idle pooled machines, how many calls reused one, and how many were dropped after a call that
    /// threw or was stopped.
    var machinePoolForTesting: (idle: Int, reused: Int, dropped: Int) {
        lock.withLock { (idleMachines.count, machineCounts.reused, machineCounts.dropped) }
    }

    /// A machine for a new context: an idle one when there is one, else a new one (nil where the
    /// engine has none, as a host process's).
    fileprivate func takeMachine() -> JSMachine? {
        let idle: JSMachine? = lock.withLock {
            guard let machine = idleMachines.popLast() else { return nil }
            machineCounts.reused += 1
            return machine
        }
        return idle ?? engine.makeMachine()
    }

    /// A context's machine once the context has closed: back to the pool only if every call in it
    /// ended cleanly, so nothing a failed or stopped script left in it reaches another call.
    fileprivate func returnMachine(_ machine: JSMachine, reusable: Bool) {
        lock.withLock {
            if !reusable {
                machineCounts.dropped += 1
            } else if idleMachines.count < PluginLimits.maximumIdleMachines {
                idleMachines.append(machine)
            }
        }
    }

    /// Where a fresh context's startup time goes, and how many host calls the plugin made: read by
    /// the call-cost measurements (PluginCallCostBenchmarks), never by the app.
    struct StartupTimings: Sendable, Equatable {
        var context: TimeInterval = 0, prelude: TimeInterval = 0, script: TimeInterval = 0, enable: TimeInterval = 0
    }
    private let measurements = Mutex((startup: StartupTimings(), hostCalls: 0))
    var lastStartupTimings: StartupTimings { measurements.withLock { $0.startup } }
    var hostCallCount: Int { measurements.withLock { $0.hostCalls } }
    fileprivate func recordStartup(_ update: (inout StartupTimings) -> Void) { measurements.withLock { update(&$0.startup) } }
    fileprivate func countHostCall() { measurements.withLock { $0.hostCalls += 1 } }

    /// Identifies every input that may change persisted content details or the
    /// host-side capabilities embedded in their playback sources.
    private static func makeDetailsCacheFingerprint(
        config: PluginConfig, script: String, settings: [String: String],
        auth: SourceAuth?, captcha: SourceAuth?
    ) -> String {
        var inputs = [
            "host-details-abi:2",
            "plugin:\(config.id):\(config.version)",
            "script:\(script)",
            "settings:\(settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))",
        ]
        if let auth, let data = try? JSONEncoder().encode(auth) {
            inputs.append("auth:\(data.base64EncodedString())")
        } else {
            inputs.append("auth:none")
        }
        if let captcha, let data = try? JSONEncoder().encode(captcha) {
            inputs.append("captcha:\(data.base64EncodedString())")
        } else {
            inputs.append("captcha:none")
        }
        return SHA256.hash(data: Data(inputs.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// `approval` comes from `SourceAccessPolicy`, the only way to make one,
    /// so no runtime starts without the policy's decision; its forced
    /// settings (restricted modes) replace the user's values here. `script`
    /// comes from `ScriptSignature.check`, the only way to make a
    /// `CheckedScript`: the published text, its signature verified when the
    /// plugin is signed.
    init(approval: LoadApproval, config: PluginConfig, script: CheckedScript, settings: [String: String],
         auth: SourceAuth?, captcha: SourceAuth?,
         savedState: String? = nil, approvals: [LocalHostApproval] = [], resolver: any HostResolving = SystemHostResolver(),
         localNetworkAccess: (@Sendable (URL) async -> Bool)? = nil, httpSession: URLSession? = nil,
         timeouts: Timeouts = .standard, engine: (any JSEngine)? = nil) {
        precondition(approval.pluginID == config.id, "a load approval is for one plugin")
        precondition(script.pluginID == config.id, "a checked script is for one plugin")
        let settings = settings.merging(approval.forcedSettings) { _, forced in forced }
        self.approval = approval
        self.engine = engine ?? PluginExecutionLimits.makeEngine()
        self.timeouts = timeouts
        self.localNetworkAccess = localNetworkAccess
        self.httpSession = httpSession
        self.config = config
        self.checkedScript = script
        self.detailsCacheFingerprint = Self.makeDetailsCacheFingerprint(
            config: config, script: script.text, settings: settings, auth: auth, captcha: captcha
        )
        self.storedSettings = settings
        self.auth = auth
        self.captcha = captcha
        self.savedState = savedState
        self.approvals = approvals
        self.resolver = resolver
        self.policy = PluginNetworkPolicy(config: config, approvals: approvals, resolver: resolver)
    }

    // MARK: shared inputs, read by workers

    /// Declared settings with their stored value, or the declared default when nothing is stored.
    func settingsWithDefaults() -> [String: String] {
        var out: [String: String] = [:]
        for s in config.settings {
            if let v = storedSettings[s.key] { out[s.key] = v }
            else if let d = s.default { out[s.key] = d }
        }
        return out
    }

    var currentSavedState: String? { lock.withLock { savedState } }
    var currentReloadData: String? { lock.withLock { reloadData } }

    /// The plugin's HTTP client, shared by its workers (one cookie jar per plugin, as in Grayjay).
    func sharedHTTP() -> HostHTTP {
        lock.withLock {
            if let http { return http }
            let made = HostHTTP(config: config, auth: auth, captcha: captcha, policy: policy,
                                session: httpSession, localNetworkAccess: localNetworkAccess)
            http = made
            return made
        }
    }

    private var referenced: (proxy: PluginEgressProxy?, session: URLSession)?

    /// A URL session for content this plugin points the app at (media segments, subtitles): no cookies,
    /// cache, credentials or client certificates, and, where the platform supports it, every connection
    /// pinned by a proxy that checks `policy.forReferencedContent` (any public host; non-public addresses
    /// only when approved). Never call on the main actor: starting the proxy binds a socket.
    func contentSession() -> URLSession {
        lock.withLock {
            if let referenced { return referenced.session }
            if let httpSession {
                referenced = (nil, httpSession)
                return httpSession
            }
            let configuration = HostHTTP.containedConfiguration()
            var proxy: PluginEgressProxy?
            if PluginEgressProxy.pinsURLSessionConnections {
                proxy = try? PluginEgressProxy.start(policy: policy.forReferencedContent)
                proxy?.apply(to: configuration)
                // Without the proxy where it is required, nothing is reachable rather than everything.
                if proxy == nil { configuration.protocolClasses = [RefusingURLProtocol.self] }
            }
            let session = URLSession(configuration: configuration)
            referenced = (proxy, session)
            return session
        }
    }

    /// Fetches content the plugin referenced (a subtitle file, say), checked and bounded.
    func fetchReferenced(_ url: URL, limit: Int = 8 * 1024 * 1024) async throws -> Data {
        let policy = policy.forReferencedContent
        let checked = await Task.detached(priority: .userInitiated) { policy.check(url: url) }.value
        if case .failure(let denial) = checked { throw denial }
        let session = await Task.detached(priority: .userInitiated) { self.contentSession() }.value
        let (data, response) = try await session.data(for: URLRequest(url: url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PluginError.execution("HTTP \(http.statusCode)")
        }
        guard data.count <= limit else { throw PluginError.execution("The file is too large") }
        return data
    }

    func recordCapabilities(_ capabilities: [String: Bool]) {
        lock.withLock { if capabilitiesSnapshot.isEmpty { capabilitiesSnapshot = capabilities } }
    }

    // MARK: contexts

    /// Contexts kept alive for their call's handles (pagers, details, modifiers, trackers), at most.
    /// The least recently used beyond it is discarded; its handles then report a session that ended.
    static let maximumRetainedSessions = 6
    /// A retained context unused this long is discarded.
    static let sessionIdleLifetime: TimeInterval = 600

    /// A fresh context for one top-level call. No other call ever uses it: only the continuations of
    /// this call (its handles and promises) reach it later, by the serial in their handles.
    private func freshWorker() throws -> PluginWorker {
        try lock.withLock {
            if let message = suspendedMessage { throw PluginError.unresponsive(message) }
            let worker = PluginWorker(runtime: self, serial: nextSerial)
            nextSerial += 1
            worker.inFlight = 1
            worker.lastUsed = Date()
            workers.append(worker)
            return worker
        }
    }

    /// Marks `worker` busy again for a follow-up step of the call that owns it; false if it is gone.
    private func claim(_ worker: PluginWorker) -> Bool {
        lock.withLock {
            guard workers.contains(where: { $0 === worker }) else { return false }
            worker.inFlight += 1
            worker.lastUsed = Date()
            return true
        }
    }

    /// The context that owns a handle (its serial is in the handle's high bits).
    private func worker(forHandle handle: Int) throws -> PluginWorker {
        let serial = PluginWorker.serial(ofHandle: handle)
        return try lock.withLock {
            if let message = suspendedMessage { throw PluginError.unresponsive(message) }
            guard let worker = workers.first(where: { $0.serial == serial }) else {
                throw PluginError.execution("This item belongs to a plugin session that has ended. Reload to continue.")
            }
            worker.inFlight += 1
            worker.lastUsed = Date()
            return worker
        }
    }

    private func release(_ worker: PluginWorker) {
        lock.withLock { worker.inFlight = max(0, worker.inFlight - 1) }
    }

    /// Ends a context: no call can reach it again.
    private func discard(_ worker: PluginWorker) {
        let removed: Bool = lock.withLock {
            guard let index = workers.firstIndex(where: { $0 === worker }) else { return false }
            workers.remove(at: index)
            return true
        }
        if removed { Task { await worker.stop() } }
    }

    /// Keeps a context for its call's live handles, discarding retained contexts that idled out or
    /// exceed `maximumRetainedSessions` (least recently used first, never one in use).
    private func retain(_ worker: PluginWorker) {
        let evicted: [PluginWorker] = lock.withLock {
            worker.lastUsed = Date()
            let now = Date()
            var out = workers.filter { $0.inFlight == 0 && $0 !== worker && now.timeIntervalSince($0.lastUsed) > Self.sessionIdleLifetime }
            let idle = workers.filter { w in w.inFlight == 0 && !out.contains(where: { $0 === w }) }
                .sorted { $0.lastUsed < $1.lastUsed }
            let excess = idle.count - Self.maximumRetainedSessions
            if excess > 0 { out += idle.filter { $0 !== worker }.prefix(excess) }
            workers.removeAll { w in out.contains { $0 === w } }
            return out
        }
        for worker in evicted { Task { await worker.stop() } }
    }

    /// After a top-level call (and its promise) finished: the plugin's state is saved for the next
    /// call's fresh context (explicit, host-held data), and the context is discarded unless the
    /// call left live handles or promises behind.
    private func finish(_ worker: PluginWorker) async {
        guard claim(worker) else { return }
        let saves = has("saveState")
        let outcome: (live: Int, state: String?)? = try? await run(on: worker, timeout: 5) { worker in
            var state: String?
            if saves, let data = try? PluginWorker.unwrap(try worker.evalResult("__jb.invoke('saveState', '[]', 'value')")),
               let text = try? JSONDecoder().decode(String.self, from: data),
               text.utf8.count <= PluginLimits.maximumTextLength * 10 {
                state = text
            }
            let live = Int(try worker.evalResult("__jb.liveCount()") ?? "0") ?? 0
            return (live, state)
        }
        if let state = outcome?.state { lock.withLock { savedState = state } }
        if let outcome, outcome.live > 0 { retain(worker) } else { discard(worker) }
    }

    /// The caller no longer needs `handle` (a pager went away): its context ends with its last handle.
    func releaseHandle(_ handle: Int) async {
        guard let worker = try? worker(forHandle: handle) else { return }
        let live: Int? = try? await run(on: worker, timeout: 5) { worker in
            Int(try worker.evalResult("__jb.releaseHandle(\(handle))") ?? "0") ?? 0
        }
        if (live ?? 0) == 0 { discard(worker) }
    }

    /// Takes a worker that missed its deadline out of service.
    fileprivate func abandon(_ worker: PluginWorker) {
        let suspended: Bool = lock.withLock {
            guard let index = workers.firstIndex(where: { $0 === worker }) else { return false }
            workers.remove(at: index)
            hungWorkers.insert(ObjectIdentifier(worker))
            if hungWorkers.count >= PluginLimits.maximumHungWorkers, suspendedMessage == nil {
                suspendedMessage = "\(config.name) stopped responding. Try again, or turn the source off and on."
            }
            return suspendedMessage != nil
        }
        worker.abandon()
        if let remote = engine as? RemoteJSEngine {
            // Process isolation: kill the plugin's host process. The stuck script stops at once, and
            // so does every other context of this plugin (their calls fail and can be retried; the
            // next call starts a new process). Nothing of it keeps running.
            let others: [PluginWorker] = lock.withLock {
                defer { workers.removeAll() }
                return workers
            }
            remote.terminate()
            for other in others { other.abandon() }
        }
        Logger.plugin.error("worker_abandoned plugin=\(pluginLogID(self.config.id), privacy: .public) serial=\(worker.serial) suspended=\(suspended)")
        OSSignposter.plugin.emitEvent("PluginTimeout", "plugin=\(pluginLogID(self.config.id), privacy: .public)")
    }

    /// An abandoned worker's script finally returned: it no longer counts as hung.
    fileprivate func abandonedWorkerFinished(_ worker: PluginWorker) {
        lock.withLock {
            hungWorkers.remove(ObjectIdentifier(worker))
            if hungWorkers.count < PluginLimits.maximumHungWorkers { suspendedMessage = nil }
        }
    }

    /// Runs `body` on a worker with a deadline. Missing the deadline abandons
    /// the worker; the caller gets a timeout at once either way.
    private func run<T: Sendable>(on worker: PluginWorker, timeout requested: TimeInterval? = nil,
                                  _ body: @escaping @Sendable (PluginWorker) throws -> T) async throws -> T {
        let timeout = requested ?? timeouts.call
        defer { release(worker) }
        do {
            return try await worker.perform(timeout: timeout, body)
        } catch let missed as PluginWorker.DeadlineMissed {
            // A running overrun was already taken out of service by the watchdog.
            _ = missed.whileRunning
            worker.markNotReusable()
            Logger.plugin.error("call_timeout plugin=\(pluginLogID(self.config.id), privacy: .public) seconds=\(timeout)")
            throw PluginError.timeout("\(config.name) took too long to respond")
        } catch {
            // A call that threw keeps its machine out of the pool.
            worker.markNotReusable()
            throw error
        }
    }

    /// Starts a fresh context for one call: prelude, plugin script and `enable` (with the enable
    /// allowance), then `body` (with the call's). Returns the context so the caller can `finish` it.
    private func withNewCall<T: Sendable>(timeout requested: TimeInterval? = nil,
                                          _ body: @escaping @Sendable (PluginWorker) throws -> T) async throws -> (T, PluginWorker) {
        let worker = try freshWorker()
        do {
            try await run(on: worker, timeout: timeouts.enable) { worker in try worker.enableLocked() }
            guard claim(worker) else { throw CancellationError() }
            return (try await run(on: worker, timeout: requested ?? timeouts.call, body), worker)
        } catch {
            await finish(worker)
            throw error
        }
    }

    private func withHandle<T: Sendable>(_ handle: Int, timeout: TimeInterval? = nil,
                                         _ body: @escaping @Sendable (PluginWorker) throws -> T) async throws -> T {
        try await run(on: try worker(forHandle: handle), timeout: timeout, body)
    }

    /// Polls a pending promise on its worker until it settles or `deadline` passes.
    private func settle(_ initial: String?, on handleOrNil: Int?, worker serial: Int, deadline: Date) async throws -> Data {
        var result = initial
        while let id = PluginWorker.pendingPromise(in: result) {
            guard Date() < deadline else { throw PluginError.timeout("\(config.name)’s asynchronous operation timed out") }
            try await Task.sleep(for: .milliseconds(10))
            // A reload or stop ended the context the promise lives in: the call is cancelled.
            let alive = lock.withLock { workers.contains { $0.serial == serial } }
            guard alive else { throw CancellationError() }
            do {
                let worker = try self.worker(forHandle: PluginWorker.handleBase(serial: serial))
                result = try await run(on: worker, timeout: max(1, deadline.timeIntervalSinceNow)) { worker in
                    try worker.evalResult("__jb.pollPromise(\(id))")
                }
            } catch {
                // The context ended while the poll waited: that is a cancellation, not a plugin failure.
                if !lock.withLock({ workers.contains { $0.serial == serial } }) { throw CancellationError() }
                throw error
            }
        }
        return try PluginWorker.unwrap(result)
    }

    // MARK: public API

    /// Starts the runtime, runs `source.enable`, and returns the detected capabilities.
    @discardableResult
    func enable() async throws -> [String: Bool] {
        let (_, worker) = try await withNewCall(timeout: 5) { _ in () }
        await finish(worker)
        return capabilities
    }

    func has(_ capability: String) -> Bool { capabilities[capability] ?? false }

    /// Checks that the functions every plugin must provide exist.
    func validate() async throws {
        let required = ["getHome", "search", "isChannelUrl", "getChannel", "getChannelContents", "isContentDetailsUrl", "getContentDetails"]
        let worker = try freshWorker()
        defer { discard(worker) }
        try await run(on: worker, timeout: timeouts.enable) { worker in
            try worker.startLocked()
            for name in required {
                let ok = (try worker.evalResult("__jb.has(\(jsString(name)))")) == "true"
                if !ok { throw PluginError.compilation("Plugin is missing required function source.\(name)") }
            }
        }
    }

    func stop() async {
        let (current, http): ([PluginWorker], HostHTTP?) = lock.withLock {
            defer { workers.removeAll(); self.http = nil; idleMachines.removeAll() }
            return (workers, self.http)
        }
        for worker in current { await worker.stop() }
        http?.close()
        (engine as? RemoteJSEngine)?.terminate()
        let referenced: (proxy: PluginEgressProxy?, session: URLSession)? = lock.withLock {
            defer { self.referenced = nil }
            return self.referenced
        }
        if let referenced, referenced.session !== httpSession {
            referenced.session.invalidateAndCancel()
            referenced.proxy?.close()
        }
    }

    /// Creates a fresh runtime with the same immutable plugin inputs.
    /// Handles and mutable executor state are intentionally not shared.
    func isolatedClone() -> PluginRuntime {
        let clone = PluginRuntime(approval: approval, config: config, script: checkedScript, settings: storedSettings,
                                  auth: auth, captcha: captcha, savedState: currentSavedState,
                                  approvals: approvals, resolver: resolver,
                                  localNetworkAccess: localNetworkAccess, httpSession: httpSession, timeouts: timeouts)
        clone.onLog = onLog
        clone.onToast = onToast
        return clone
    }

    /// Restarts the runtime; `reloadData` becomes the global `__reloadData` seen by the script (ReloadRequiredException).
    func reload(reloadData: String?) async {
        let current: [PluginWorker] = lock.withLock {
            defer { workers.removeAll() }
            self.reloadData = reloadData
            return workers
        }
        for worker in current { await worker.stop() }
    }

    /// The plugin's saved state, as captured after its latest call (`finish`).
    func saveState() async -> String? {
        guard has("saveState") else { return nil }
        return currentSavedState
    }

    /// Invokes `source.<name>(...args)`; `kind` is "value", "pager", "details" or "playlist".
    /// The result can only be decoded into `PluginOutput` types (see `decodeOffMain`).
    func callRaw(_ name: String, _ args: [Any] = [], kind: String = "value") async throws -> PluginResult {
        let signposter = OSSignposter.plugin
        let signpost = signposter.beginInterval(
            "PluginCall", id: signposter.makeSignpostID(),
            "plugin=\(pluginLogID(self.config.id), privacy: .public) function=\(name, privacy: .public) kind=\(kind, privacy: .public)"
        )
        var outcome = "failed"
        defer { signposter.endInterval("PluginCall", signpost, "\(outcome, privacy: .public)") }
        let encodedArgs = try PluginWorker.argsJSON(args)
        let (result, worker) = try await withNewCall { worker in
            let js = "__jb.invoke(\(jsString(name)), \(jsString(encodedArgs)), \(jsString(kind)))"
            return try worker.evalResult(js)
        }
        let data: Data
        do {
            data = try await settle(result, on: nil, worker: worker.serial, deadline: Date().addingTimeInterval(timeouts.call))
        } catch {
            await finish(worker)
            throw error
        }
        await finish(worker)
        outcome = "ok"
        return PluginResult(data: data, context: outputContext)
    }

    func call<T: PluginOutput>(_ name: String, _ args: [Any] = [], as type: T.Type = T.self) async throws -> T {
        try Self.decode(T.self, from: try await callRaw(name, args))
    }

    func pager<Item: PluginOutput>(_ name: String, _ args: [Any] = [], as item: Item.Type) async throws -> PluginPager<Item> {
        let result = try await callRaw(name, args, kind: "pager")
        return PluginPager(runtime: self, payload: try Self.decodeEnvelope(PagerPayload<Item>.self, from: result.data))
    }

    func nextPageRaw(handle: Int) async throws -> Data {
        try await withHandle(handle) { worker in try PluginWorker.unwrap(try worker.evalResult("__jb.nextPage(\(handle))")) }
    }

    func callHandle(_ handle: Int, _ method: String, _ args: [Any] = [],
                    timeout requested: TimeInterval? = nil) async throws -> PluginResult {
        let timeout = requested ?? timeouts.call
        let encodedArgs = try PluginWorker.argsJSON(args)
        let deadline = Date().addingTimeInterval(timeout)
        let (result, serial) = try await withHandle(handle, timeout: timeout) { worker in
            (try worker.evalResult("__jb.callHandle(\(handle), \(jsString(method)), \(jsString(encodedArgs)))"), worker.serial)
        }
        return PluginResult(data: try await settle(result, on: handle, worker: serial, deadline: deadline), context: outputContext)
    }

    func callHandleBytes(_ handle: Int, _ method: String, _ args: [Any] = []) async throws -> Data {
        let encodedArgs = try PluginWorker.argsJSON(args)
        let deadline = Date().addingTimeInterval(timeouts.call)
        let (result, serial) = try await withHandle(handle) { worker in
            (try worker.evalResult("__jb.callHandleBytes(\(handle), \(jsString(method)), \(jsString(encodedArgs)))"), worker.serial)
        }
        let encoded = try Self.decodeEnvelope(String.self, from: try await settle(result, on: handle, worker: serial, deadline: deadline))
        guard let bytes = Data(base64Encoded: encoded) else {
            throw PluginError.execution("The plugin returned invalid base64 media data")
        }
        return bytes
    }

    func handlePager<Item: PluginOutput>(_ handle: Int, _ method: String, _ args: [Any] = [], as item: Item.Type) async throws -> PluginPager<Item> {
        let encodedArgs = try PluginWorker.argsJSON(args)
        let data = try await withHandle(handle) { worker in
            try PluginWorker.unwrap(try worker.evalResult("__jb.callHandleForPager(\(handle), \(jsString(method)), \(jsString(encodedArgs)))"))
        }
        return PluginPager(runtime: self, payload: try Self.decodeEnvelope(PagerPayload<Item>.self, from: data))
    }

    func subCommentsPager(handle: Int) async throws -> PluginPager<PluginComment> {
        let data = try await withHandle(handle) { worker in try PluginWorker.unwrap(try worker.evalResult("__jb.subComments(\(handle))")) }
        return PluginPager(runtime: self, payload: try Self.decodeEnvelope(PagerPayload<PluginComment>.self, from: data))
    }

    struct HandleRef: Decodable, Sendable { var handle: Int; var nextRequest: Int? }

    func handleFromCall(_ handle: Int, _ method: String, _ args: [Any] = []) async throws -> HandleRef? {
        let encodedArgs = try PluginWorker.argsJSON(args)
        let data = try await withHandle(handle) { worker in
            try PluginWorker.unwrap(try worker.evalResult("__jb.callHandleForHandle(\(handle), \(jsString(method)), \(jsString(encodedArgs)))"))
        }
        return try Self.decodeEnvelope(HandleRef?.self, from: data)
    }

    func handleFromSource(_ name: String, _ args: [Any] = []) async throws -> HandleRef? {
        let encodedArgs = try PluginWorker.argsJSON(args)
        let (data, worker) = try await withNewCall { worker in
            try PluginWorker.unwrap(try worker.evalResult("__jb.invokeForHandle(\(jsString(name)), \(jsString(encodedArgs)))"))
        }
        await finish(worker)
        return try Self.decodeEnvelope(HandleRef?.self, from: data)
    }

    /// Reads a numeric property from a retained plugin object (e.g. a tracker's `nextRequest`).
    func intProperty(handle: Int, _ name: String) async -> Int? {
        let text: String? = try? await withHandle(handle) { worker in
            try worker.evalResult("__jb.getProperty(\(handle), \(jsString(name)))")
        }
        guard let text, let v = Double(text), v.isFinite, abs(v) < 9e15 else { return nil }
        return Int(v)
    }

    func hasMember(handle: Int, _ name: String) async -> Bool {
        (try? await withHandle(handle) { worker in (try worker.evalResult("__jb.hasMember(\(handle), \(jsString(name)))")) == "true" }) ?? false
    }

    /// Asks a source's request modifier to adjust one media request, and keeps
    /// only what a modifier may change: the URL (http(s), on the original host
    /// or the plugin's allow-list, resolving to a public or approved address)
    /// and a bounded set of plain headers. Time-limited to
    /// `timeouts.requestModifier`. Playback uses only this.
    func modifyRequest(handle: Int, url: URL, headers: [String: String]) async throws -> ContainedRequest {
        let result = try await callHandle(handle, "modifyRequest", [url.absoluteString, headers],
                                          timeout: timeouts.requestModifier)
        let modified = try Self.decodeEnvelope(RawModifiedRequest.self, from: result.data)
        return try ContainedRequest.make(original: url, originalHeaders: headers,
                                         modifiedURL: modified.url, modifiedHeaders: modified.headers, policy: policy)
    }

    private struct RawModifiedRequest: Decodable, Sendable {
        var url: String?
        var headers: [String: String]?
    }

    // MARK: decoding

    /// Decodes host envelopes (pager payloads, handle refs): bounded in size.
    static func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= PluginLimits.maximumResultBytes else { throw PluginError.execution("The plugin returned too much data") }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PluginError.execution("Unexpected data from the plugin: \(error.localizedDescription)") }
    }

    /// The only way to turn a plugin's result into a value: decode, then contain
    /// it against the plugin that produced it.
    static func decode<T: PluginOutput>(_ type: T.Type, from result: PluginResult) throws -> T {
        var value = try decodeEnvelope(T.self, from: result.data)
        value.contain(result.context)
        return value
    }

    static func decodeOffMain<T: PluginOutput>(_ type: T.Type, from result: PluginResult) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try decode(type, from: result) }.value
    }
}

/// A plugin's raw result together with the plugin it came from. It can only
/// be decoded into `PluginOutput` types (`PluginRuntime.decode`), which
/// contain the value for that plugin, so unchecked plugin data cannot reach
/// the UI by accident.
struct PluginResult: Sendable {
    let data: Data
    let context: PluginOutputContext

    var count: Int { data.count }
}

/// A media request after the plugin's request modifier, reduced to what a modifier may change.
struct ContainedRequest: Sendable, Equatable {
    let url: URL
    let headers: [String: String]

    static let forbiddenHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "proxy-authorization", "proxy-connection",
        "keep-alive", "upgrade", "te", "trailer", "expect",
    ]

    static func make(original: URL, originalHeaders: [String: String], modifiedURL: String?,
                     modifiedHeaders: [String: String]?, policy: PluginNetworkPolicy) throws -> ContainedRequest {
        var url = original
        if let text = modifiedURL, !text.isEmpty {
            guard text.utf8.count <= PluginLimits.maximumURLLength, let candidate = URL(string: text) else {
                throw PluginError.execution("The request modifier returned an invalid URL")
            }
            let scheme = candidate.scheme?.lowercased() ?? ""
            guard scheme == "http" || scheme == "https", let host = candidate.host(percentEncoded: false),
                  candidate.user == nil, candidate.password == nil else {
                throw NetworkDenial.scheme(scheme)
            }
            let sameHost = PluginNetworkPolicy.normalizedHost(host)
                == PluginNetworkPolicy.normalizedHost(original.host(percentEncoded: false) ?? "")
            guard sameHost || policy.allowListed(host: host, port: candidate.port ?? (scheme == "https" ? 443 : 80)) else {
                throw NetworkDenial.notAllowListed(host: host)
            }
            if let literal = IPAddress(literal: host), !literal.scope.isPublic,
               !policy.approvals.contains(where: { $0.permits(host: host, port: candidate.port ?? (scheme == "https" ? 443 : 80), address: literal) }) {
                throw NetworkDenial.localNotApproved(host: host, port: candidate.port ?? 0, address: literal.description)
            }
            let candidatePort = candidate.port ?? (scheme == "https" ? 443 : 80)
            if AddressClassifier.isLocalName(host),
               !policy.approvals.contains(where: { $0.host == PluginNetworkPolicy.normalizedHost(host) && $0.port == candidatePort }) {
                throw NetworkDenial.localNotApproved(host: host, port: candidate.port ?? 0, address: host)
            }
            url = candidate
        }
        var headers: [String: String] = [:]
        for (name, value) in (modifiedHeaders ?? originalHeaders).prefix(32) {
            guard name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$"#, options: .regularExpression) != nil,
                  !forbiddenHeaders.contains(name.lowercased()),
                  value.utf8.count <= 8 * 1024,
                  !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { continue }
            headers[name] = value
        }
        return ContainedRequest(url: url, headers: headers)
    }

    var urlRequest: URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

/// A plugin ID as logged: plugin IDs come from the plugin's config, so
/// control characters and runaway length are removed before they reach a log line.
func pluginLogID(_ id: String) -> String {
    String(id.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f && !(0x202a...0x202e).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
        .prefix(128).map(Character.init))
}

// MARK: - Worker

/// One JavaScript context of a plugin, with its own serial queue, DOM store,
/// timers and browser page. Everything that touches the context runs on `queue`.
final class PluginWorker: @unchecked Sendable {
    /// Handles are `serial << handleShift | local`; JavaScript numbers are exact to 2^53.
    static let handleShift = 32
    static func handleBase(serial: Int) -> Int { serial << handleShift }
    static func serial(ofHandle handle: Int) -> Int { handle >> handleShift }

    struct DeadlineMissed: Error {
        /// True when the script was running (the worker is stuck); false when
        /// the call was still waiting behind another one.
        let whileRunning: Bool
    }

    let serial: Int
    private weak var runtime: PluginRuntime?
    private let config: PluginConfig
    private let queue: DispatchQueue
    /// Calls routed here and not finished, and when it was last used (guarded by the runtime's lock).
    var inFlight = 0
    var lastUsed = Date()

    private var context: JSContextHost?
    /// The machine `context` lives in (queue only); returned to the runtime's pool when the context
    /// closes, unless `reusable` was cleared.
    private var machine: JSMachine?
    /// False once a call in this context threw, missed its deadline or was stopped.
    private let reusable = Mutex(true)
    private let dom = DOMStore()
    private var browser: PluginBrowserPackage?
    private var started = false
    private var enabled = false
    private var installedPackages = Set<String>()
    private var reportedUnsupportedCapabilities = Set<String>()
    private var pendingTimers = 0
    /// Identifies the JavaScript context that owns queued native callbacks.
    /// A callback created by a stopped context must never be delivered to its replacement.
    private var contextGeneration: UInt64 = 0
    /// The running call's deadline (queue only).
    private var deadline: Date?
    private var logBudget = TokenBucket(rate: Double(PluginLimits.logLinesPerSecond), burst: Double(PluginLimits.logLinesPerSecond))
    private let abandoned = Mutex(false)
    private let enabledFlag = Mutex(false)
    /// Whether `enable()` has run in this context (readable off the queue).
    var isEnabled: Bool { enabledFlag.withLock { $0 } }

    var isAbandoned: Bool { abandoned.withLock { $0 } }

    init(runtime: PluginRuntime, serial: Int) {
        self.runtime = runtime
        config = runtime.config
        self.serial = serial
        queue = DispatchQueue(label: "app.hummingbird.plugin.\(pluginLogID(config.id)).\(serial)", qos: .userInitiated)
    }

    // MARK: running work

    private final class Tripwire: Sendable {
        let state = Mutex(Job<Int>.State.running)
    }

    private final class Job<T: Sendable>: Sendable {
        enum State { case pending, running, finished }
        let state = Mutex(State.pending)
        let continuation: CheckedContinuation<T, Error>
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

        /// Moves to `finished` once; returns whether this caller did.
        func finish(_ result: Result<T, Error>) -> Bool {
            let won: Bool = state.withLock {
                guard $0 != .finished else { return false }
                $0 = .finished
                return true
            }
            if won { continuation.resume(with: result) }
            return won
        }
    }

    /// Runs `body` on the queue. A call still waiting when `timeout` passes
    /// fails without running; a running one that overruns fails at once and
    /// the worker is reported stuck (`DeadlineMissed(whileRunning: true)`).
    func perform<T: Sendable>(timeout: TimeInterval, _ body: @escaping @Sendable (PluginWorker) throws -> T) async throws -> T {
        let signposter = OSSignposter.plugin
        let pluginID = pluginLogID(config.id)
        let wait = signposter.beginInterval("PluginQueueWait", id: signposter.makeSignpostID(), "plugin=\(pluginID, privacy: .public)")
        return try await withCheckedThrowingContinuation { continuation in
            let job = Job<T>(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if job.state.withLock({ $0 == .pending }) { _ = job.finish(.failure(DeadlineMissed(whileRunning: false))) }
            }
            queue.async {
                signposter.endInterval("PluginQueueWait", wait)
                let proceed: Bool = job.state.withLock {
                    guard $0 == .pending else { return false }
                    $0 = .running
                    return true
                }
                guard proceed, !self.isAbandoned else {
                    _ = job.finish(.failure(PluginError.execution("The plugin session ended")))
                    return
                }
                let runDeadline = Date().addingTimeInterval(timeout)
                self.deadline = runDeadline
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + self.watchdogGrace(for: timeout)) {
                    // Atomically: the call fails, and the worker is taken out of service, before
                    // the script can return. So exactly one of the two sides cleans up.
                    let stuck: Bool = job.state.withLock {
                        guard $0 == .running else { return false }
                        $0 = .finished
                        self.markStuck()
                        return true
                    }
                    if stuck { job.continuation.resume(throwing: DeadlineMissed(whileRunning: true)) }
                }
                let work = signposter.beginInterval("PluginWork", id: signposter.makeSignpostID(), "plugin=\(pluginID, privacy: .public)")
                let result = Result { try body(self) }
                signposter.endInterval("PluginWork", work)
                self.deadline = nil
                // A call that only returned at or after its deadline (its host calls were cut short) is a
                // timeout too, but the context is fine: it returned.
                let outcome: Result<T, Error> = Date() >= runDeadline ? .failure(DeadlineMissed(whileRunning: false)) : result
                if !job.finish(outcome) {
                    // The watchdog gave up on this call; the script has now returned, so the context is done.
                    self.retireAfterStuck()
                }
            }
        }
    }

    /// Runs native-initiated script work (a timer, a browser callback) on the queue with the same
    /// watchdog as a call: if it overruns, the worker is taken out of service.
    private func guarded(timeout: TimeInterval, _ work: () -> Void) {
        let tripwire = Tripwire()
        deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + watchdogGrace(for: timeout)) {
            tripwire.state.withLock {
                guard $0 == .running else { return }
                $0 = .finished
                self.markStuck()
            }
        }
        work()
        deadline = nil
        let overran: Bool = tripwire.state.withLock {
            guard $0 == .running else { return true }
            $0 = .finished
            return false
        }
        if overran { retireAfterStuck() }
    }

    /// Takes this worker out of service (host calls fail from now on) and tells the runtime, which
    /// counts it as hung until `retireAfterStuck` runs.
    private func markStuck() {
        abandoned.withLock { $0 = true }
        markNotReusable()
        runtime?.abandon(self)
    }

    /// The stuck script finally returned: close the context and stop counting it as hung.
    private func retireAfterStuck() {
        stopLocked()
        runtime?.abandonedWorkerFinished(self)
    }

    /// Stops serving calls; host calls fail from now on so a script stuck in
    /// a loop of host calls returns quickly. The context closes when the
    /// script returns.
    func abandon() {
        abandoned.withLock { $0 = true }
        markNotReusable()
    }

    /// Keeps this context's machine out of the pool when the context closes.
    func markNotReusable() {
        reusable.withLock { $0 = false }
    }

    func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { self.stopLocked(); c.resume() }
        }
    }

    // MARK: lifecycle (queue only)

    func startLocked() throws {
        if started { return }
        guard !isAbandoned else { throw PluginError.execution("The plugin session ended") }
        contextGeneration &+= 1
        guard let runtime else { throw PluginError.execution("The plugin session ended") }
        let ctx: JSContextHost
        do {
            let began = Date()
            let hostCall: (String, String, String) -> String = { [weak self] name, a, b in self?.handleHostCall(name, a, b) ?? "" }
            if let pooled = runtime.takeMachine() {
                machine = pooled
                ctx = try runtime.engine.makeContext(in: pooled, hostCall: hostCall)
            } else {
                ctx = try runtime.engine.makeContext(hostCall: hostCall)
            }
            runtime.recordStartup { $0.context = Date().timeIntervalSince(began) }
        } catch let e as JSEngineError {
            markNotReusable()
            releaseMachine()
            throw PluginError.execution(e.message)
        }
        context = ctx

        do {
            let preludeBegan = Date()
            try eval(Self.loadPrelude(), name: "prelude.js")
            runtime.recordStartup { $0.prelude = Date().timeIntervalSince(preludeBegan) }
            try eval("bridge.buildPlatform = \(jsString(Self.buildPlatform)); __jb.setHandleBase(\(Self.handleBase(serial: serial)));", name: "host-platform")

            for p in config.packages {
                guard installPackage(p) else { throw PluginError.compilation("Unsupported plugin package \"\(p)\" on this platform") }
            }
            for p in config.packagesOptional { _ = installPackage(p) }

            // Browser-capable plugins may use their engine fallback when the optional
            // Browser package is unavailable. That fallback has to evaluate the same
            // remote scripts a browser page would execute (notably YouTube BotGuard).
            if !config.allowEval && !config.packagesOptional.contains("Browser") {
                try eval("""
                    (function () {
                      var nativeEval = globalThis.eval;
                      var NativeFunction = globalThis.Function;
                      var blockedEval = function () {
                        throw new ScriptImplementationException('eval is not allowed by this plugin');
                      };
                      globalThis.eval = blockedEval;
                      globalThis.Function = function () {
                        var args = arguments;
                        globalThis.eval = nativeEval;
                        try { return NativeFunction.apply(this, args); }
                        finally { globalThis.eval = blockedEval; }
                      };
                      globalThis.Function.prototype = NativeFunction.prototype;
                    })();
                    """, name: "eval-guard")
            }
            if let reloadData = runtime.currentReloadData {
                try eval("var __reloadData = \(jsString(reloadData));", name: "reload-data")
            }

            let cfgData = try JSONEncoder().encode(config)
            let settingsData = try JSONSerialization.data(withJSONObject: runtime.settingsWithDefaults())
            try eval("plugin.config = \(jsLiteral(cfgData)); plugin.settings = parseSettings(\(jsLiteral(settingsData)));", name: "plugin-config")
            let scriptBegan = Date()
            try eval(runtime.script, name: "\(pluginLogID(config.name)).js")
            runtime.recordStartup { $0.script = Date().timeIntervalSince(scriptBegan) }

            if let snap = try limited(ctx).evaluate("__jb.capabilitySnapshot()", name: "capabilities"),
               let d = snap.data(using: .utf8),
               let m = try? JSONDecoder().decode([String: Bool].self, from: d) { runtime.recordCapabilities(m) }
            started = true
        } catch {
            ctx.close()
            context = nil
            markNotReusable()
            releaseMachine()
            throw error
        }
    }

    /// Gives the closed context's machine back to the runtime (which pools it only if reusable).
    private func releaseMachine() {
        guard let machine else { return }
        self.machine = nil
        runtime?.returnMachine(machine, reusable: reusable.withLock { $0 })
    }

    func enableLocked() throws {
        try startLocked()
        if enabled { return }
        let state = runtime?.currentSavedState.map { jsString($0) } ?? "null"
        let js = "__jb.invoke('enable', JSON.stringify([plugin.config, plugin.settings, \(state)]), 'value')"
        let enableBegan = Date()
        _ = try Self.unwrap(try evalResult(js))
        runtime?.recordStartup { $0.enable = Date().timeIntervalSince(enableBegan) }
        enabled = true
        enabledFlag.withLock { $0 = true }
    }

    private func stopLocked() {
        contextGeneration &+= 1
        context?.close()
        context = nil
        releaseMachine()
        browser?.close()
        browser = nil
        dom.removeAll()
        started = false
        enabled = false
        pendingTimers = 0
    }

    /// What Grayjay plugins see as `bridge.buildPlatform`.
    private static var buildPlatform: String {
        switch HostPlatform.family {
        case .desktop: "desktop"
        case .android: "android"
        case .appleMobile: "ios"
        }
    }

    // MARK: host calls (queue only)

    /// The single native entry point plugin code can reach (`__hostCall` in the prelude). Runs on `queue`.
    /// Once the worker is abandoned, or its call's deadline has passed, every call that could keep the
    /// script busy (HTTP, sleep, timers, browser) returns at once.
    private func handleHostCall(_ name: String, _ a: String, _ b: String) -> String {
        runtime?.countHostCall()
        let expired = isAbandoned || (deadline.map { Date() >= $0 } ?? false)
        switch name {
        case "log":
            guard logBudget.tryTake() else { return "" }
            runtime?.onLog?(String(a.prefix(PluginLimits.maximumLogLineBytes)))
            return ""
        case "toast": if !expired { runtime?.onToast?(String(a.prefix(PluginLimits.maximumToastLength * 4))) }; return ""
        case "isLoggedIn": return (runtime?.isLoggedIn ?? false) ? "1" : "0"
        case "hasPackage":
            let supported = installedPackages.contains(a)
            if !supported { reportUnsupportedCapability(kind: "package", name: a) }
            return supported ? "1" : "0"
        case "unsupportedFeature":
            reportUnsupportedCapability(kind: "feature", name: a)
            return ""
        case "sleep":
            guard !expired else { return "" }
            var seconds = min(max(0, Double(a) ?? 0) / 1000, PluginLimits.maximumSleep)
            if let deadline { seconds = min(seconds, max(0, deadline.timeIntervalSinceNow)) }
            if seconds.isFinite, seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
            return ""
        case "http":
            guard !expired else {
                return #"[{"error":"The plugin call was cancelled or timed out"}]"#
            }
            guard let http = runtime?.sharedHTTP() else { return "[]" }
            return http.execute(json: a, parallel: b == "1", deadline: deadline ?? .distantFuture,
                                isCancelled: { [weak self] in self?.isAbandoned ?? true })
        case let operation where operation.hasPrefix("browser."):
            guard !expired else { return "" }
            return browser?.call(String(operation.dropFirst(8)), payload: a) ?? ""
        case "setTimeout":
            guard !expired, let id = Int(a), pendingTimers < PluginLimits.maximumTimers else { return "" }
            let ms = min(max(0, Double(b) ?? 0), 3_600_000)
            let generation = contextGeneration
            pendingTimers += 1
            queue.asyncAfter(deadline: .now() + ms / 1000) { [weak self] in
                guard let self else { return }
                self.pendingTimers = max(0, self.pendingTimers - 1)
                guard !self.isAbandoned, self.contextGeneration == generation, let ctx = self.context else { return }
                // A timer runs between calls, under its own watchdog.
                self.guarded(timeout: self.runtime?.timeouts.call ?? PluginLimits.callTimeout) {
                    do {
                        _ = try self.limited(ctx).evaluate("__jb.fireTimer(\(id))", name: "timer")
                    } catch {
                        self.runtime?.onLog?("Timer callback failed: \(error)")
                    }
                }
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

    private func reportUnsupportedCapability(kind: String, name: String) {
#if DEBUG
        let key = "\(kind):\(name)"
        guard reportedUnsupportedCapabilities.count < 64, reportedUnsupportedCapabilities.insert(key).inserted else { return }
        let message = "Plugin \(pluginLogID(config.id)) requested unsupported \(kind) \"\(pluginLogID(name))\""
        runtime?.onLog?("Warning: \(message)")
        Logger.plugin.notice("unsupported_capability plugin=\(pluginLogID(self.config.id), privacy: .public) kind=\(kind, privacy: .public) name=\(pluginLogID(name), privacy: .public)")
#endif
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
        case "Browser":
            guard PluginBrowserPackage.isSupported else { return false }
#if DEBUG
            guard ProcessInfo.processInfo.environment["HUMMINGBIRD_DISABLE_PLUGIN_BROWSER"] != "1" else {
                return false
            }
#endif
            let generation = contextGeneration
            guard let runtime else { return false }
            browser = PluginBrowserPackage(policy: runtime.policy, proxy: runtime.sharedHTTP().proxy) { [weak self] id, value in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, !self.isAbandoned, self.contextGeneration == generation, let context = self.context else { return }
                    self.guarded(timeout: self.runtime?.timeouts.call ?? PluginLimits.callTimeout) {
                    do {
                        _ = try self.limited(context).evaluate(
                            "__jb.browserCallback(\(jsString(id)), \(jsString(value)))",
                            name: "browser-callback"
                        )
                    } catch {
                        self.runtime?.onLog?("Browser callback failed: \(error)")
                    }
                    }
                }
            }
            script = "var browser = __makeBrowser();"
        default: return false
        }
        do { _ = try limited(ctx).evaluate(script, name: "package-\(name)") } catch { return false }
        installedPackages.insert(name)
        return true
    }

    // MARK: helpers (queue only)


    /// `context` with the running call's remaining time as its engine time limit. Builds with
    /// JavaScriptCore's time limit stop the script there themselves (`PluginExecutionLimits`).
    private func limited(_ context: JSContextHost) -> JSContextHost {
        context.setExecutionTimeLimit(deadline.map { max(0.001, $0.timeIntervalSinceNow - 0.05) })
        return context
    }

    /// How long the watchdog waits past a deadline of `timeout`. Where an in-process engine stops
    /// scripts itself (JavaScriptCore's time limit, set to the call's remaining time), the
    /// watchdog is only a backstop: it waits as long again, so the engine's limit wins by a whole
    /// timeout even on an overloaded machine and the context returns rather than being abandoned.
    /// Callers still get their timeout at the deadline, when the engine stops the script.
    private func watchdogGrace(for timeout: TimeInterval) -> TimeInterval {
        guard PluginExecutionLimits.engineTimeLimit != nil, !(runtime?.engine is RemoteJSEngine) else { return 0 }
        return timeout
    }
    private func eval(_ code: String, name: String) throws {
        guard let ctx = context else { throw PluginError.execution("Runtime is not running") }
        do { _ = try limited(ctx).evaluate(code, name: name.replacingOccurrences(of: " ", with: "_")) }
        catch let e as JSEngineError where e.message == JSEngineError.terminatedAtDeadline { throw DeadlineMissed(whileRunning: false) }
        catch let e as JSEngineError { throw PluginError.compilation("\(e.message) (\(name):\(e.line ?? "?"))") }
    }

    /// Evaluates host-generated glue code and returns its string result.
    func evalResult(_ code: String) throws -> String? {
        guard let ctx = context else { throw PluginError.execution("Runtime is not running") }
        do { return try limited(ctx).evaluate(code, name: "host") }
        catch let e as JSEngineError where e.message == JSEngineError.terminatedAtDeadline { throw DeadlineMissed(whileRunning: false) }
        catch let e as JSEngineError { throw PluginError.execution(e.message) }
    }

    /// Unwraps the `{ok, value | error}` envelope the prelude returns, yielding the JSON of `value`.
    /// The envelope is plugin-controlled text: its size is bounded before it is parsed.
    static func unwrap(_ result: String?) throws -> Data {
        guard let text = result else { throw PluginError.execution("The plugin returned an unreadable result") }
        guard text.utf8.count <= PluginLimits.maximumResultBytes else {
            throw PluginError.execution("The plugin returned too much data")
        }
        guard let data = text.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginError.execution("The plugin returned an unreadable result")
        }
        if (env["ok"] as? Bool) == true {
            let value = env["value"] ?? NSNull()
            return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        }
        if let err = env["error"], let ed = try? JSONSerialization.data(withJSONObject: err),
           let payload = try? JSONDecoder().decode(PluginError.Payload.self, from: ed) {
            throw PluginError(payload: payload.bounded)
        }
        throw PluginError.execution("The plugin failed")
    }

    static func pendingPromise(in result: String?) -> Int? {
        guard let text = result, text.utf8.count < 4_096, let data = text.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return env["pending"] as? Int
    }

    static func loadPrelude() throws -> String {
        guard let url = Bundle.module.url(forResource: "prelude", withExtension: "js"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            throw PluginError.execution("prelude.js is missing from the app bundle")
        }
        return src
    }

    static func argsJSON(_ args: [Any]) throws -> String {
        let d = try JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed])
        return String(decoding: d, as: UTF8.self)
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

/// Media bytes a plugin pointed playback at (segments, playlists, progressive
/// ranges), fetched through that plugin's contained content session
/// (`PluginRuntime.contentSession()`), never an app-wide session.
///
/// Plugin media moves to `BackgroundTransferSession` only where that keeps
/// the containment, and it never does today: on iOS, iPadOS, tvOS and
/// visionOS background transfers are carried by the system outside this
/// process, where the in-process egress proxy that pins every connection
/// cannot be used; on macOS and GTK the contained session itself keeps
/// running while the app is in the background. So plugin downloads pause
/// while a mobile app is suspended and continue at once when it returns.
struct PluginContentTransport: MediaTransport {
    let runtime: PluginRuntime

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let runtime = runtime
        // contentSession() may bind the egress proxy's socket: never on the caller's actor.
        let session = await Task.detached(priority: .userInitiated) { runtime.contentSession() }.value
        return try await session.data(for: request)
    }
}
