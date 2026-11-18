import Foundation
import Synchronization
import XCTest
import PluginEngine
#if canImport(WebKit) && !os(tvOS)
import WebKit
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
@testable import HummingbirdKit

/// Measures what one fresh JavaScript realm per plugin call costs, three ways:
///   (a) a fresh JavaScriptCore context in the app (today's runtime),
///   (b) a fresh WKContentWorld in one hidden web page per plugin (WebKit's WebContent process),
///   (c) a fresh context in the plugin's own host process (macOS/Linux process isolation).
/// Reports per-call latency (p50/p95) for search, getContentDetails and nextPage, startup phases,
/// host-call round trips, and memory. Opt-in: HUMMINGBIRD_BENCHMARK=1. The real YouTube plugin is
/// used when HUMMINGBIRD_YOUTUBE_PLUGIN_DIR names a checkout (network allowed; nothing persisted);
/// the synthetic plugin in Tests/bench-plugin needs no network. Results are printed as `BENCH {json}`
/// lines and appended to HUMMINGBIRD_BENCHMARK_OUT when set.
final class PluginCallCostBenchmarks: XCTestCase {
    static let iterations = Int(ProcessInfo.processInfo.environment["HUMMINGBIRD_BENCHMARK_ITERATIONS"] ?? "") ?? 15

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["HUMMINGBIRD_BENCHMARK"] == "1" || env["SIMCTL_CHILD_HUMMINGBIRD_BENCHMARK"] == "1" else {
            throw XCTSkip("Set HUMMINGBIRD_BENCHMARK=1 to measure plugin call costs")
        }
    }

    // MARK: plugins

    struct Plugin: Sendable {
        let label: String
        let config: PluginConfig
        let script: String
        let query: String
        let settings: [String: String]
    }

    static var synthetic: Plugin {
        get throws {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("bench-plugin")
            let config = try JSONDecoder().decode(PluginConfig.self, from: Data(contentsOf: directory.appendingPathComponent("BenchConfig.json")))
            let script = try String(contentsOf: directory.appendingPathComponent("bench.js"), encoding: .utf8)
            return Plugin(label: "synthetic", config: config, script: script, query: "anything", settings: [:])
        }
    }

    static var youtube: Plugin? {
        get throws {
            guard let path = ProcessInfo.processInfo.environment["HUMMINGBIRD_YOUTUBE_PLUGIN_DIR"]
                    ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_HUMMINGBIRD_YOUTUBE_PLUGIN_DIR"] else { return nil }
            let root = URL(fileURLWithPath: path)
            // A working checkout's script need not match its published signature; signature
            // checks are not what is measured here.
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("YoutubeConfig.json"))) as? [String: Any])
            fields["scriptSignature"] = nil
            fields["scriptPublicKey"] = nil
            let config = try JSONDecoder().decode(PluginConfig.self, from: JSONSerialization.data(withJSONObject: fields))
            let script = try String(contentsOf: root.appendingPathComponent("YoutubeScript.js"), encoding: .utf8)
            return Plugin(label: "youtube", config: config, script: script, query: "lofi music", settings: [:])
        }
    }

    var plugins: [Plugin] {
        get throws { [try Self.synthetic] + [try Self.youtube].compactMap { $0 } }
    }

    // MARK: reporting

    struct Stats: Encodable {
        let n: Int, p50: Double, p95: Double, mean: Double
        init(_ seconds: [Double]) {
            let ms = seconds.map { $0 * 1000 }.sorted()
            n = ms.count
            p50 = ms.isEmpty ? 0 : ms[ms.count / 2]
            p95 = ms.isEmpty ? 0 : ms[min(ms.count - 1, Int((Double(ms.count) * 0.95).rounded(.up)) - 1)]
            mean = ms.isEmpty ? 0 : ms.reduce(0, +) / Double(ms.count)
        }
    }

    func report(_ record: [String: Any]) {
        var record = record
        record["platform"] = Self.platformName
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print("BENCH \(line)")
        if let out = ProcessInfo.processInfo.environment["HUMMINGBIRD_BENCHMARK_OUT"],
           let handle = FileHandle(forWritingAtPath: out) ?? (FileManager.default.createFile(atPath: out, contents: nil) ? FileHandle(forWritingAtPath: out) : nil) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    static var platformName: String {
        let info = ProcessInfo.processInfo
        let env = info.environment
        let simulator = env["SIMULATOR_DEVICE_NAME"].map { " simulator: \($0)" } ?? ""
        return "\(info.operatingSystemVersionString)\(simulator)"
    }

    func stats(_ samples: [Double]) -> [String: Any] {
        let s = Stats(samples)
        return ["n": s.n, "p50_ms": round(s.p50 * 10) / 10, "p95_ms": round(s.p95 * 10) / 10, "mean_ms": round(s.mean * 10) / 10]
    }

    static func time<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = Date()
        let value = try await body()
        return (value, Date().timeIntervalSince(start))
    }

    /// Physical memory footprint of a process, in MB (Darwin), or nil.
    static func footprintMB(pid: Int32 = getpid()) -> Double? {
        #if canImport(Darwin)
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return Double(info.ri_phys_footprint) / 1_048_576
        #else
        return nil
        #endif
    }

    // MARK: (a) and (c): PluginRuntime, one fresh context per call

    func measureRuntime(_ plugin: Plugin, engineLabel: String, engine: () throws -> (any JSEngine, Int32?)) async throws {
        var search: [Double] = [], details: [Double] = [], next: [Double] = []
        var startups: [PluginRuntime.StartupTimings] = []
        var hostCalls: [String: Int] = [:]
        let (made, _) = try engine()
        let rt = PluginRuntime(approval: testLoadApproval(plugin.config), config: plugin.config,
                               script: try ScriptSignature.check(plugin.script, for: plugin.config),
                               settings: plugin.settings, auth: nil, captcha: nil, engine: made)
        defer { Task { await rt.stop() } }
        let before = Self.footprintMB()
        var keep: [PluginPager<ContentItem>] = []
        for i in 0..<Self.iterations {
            let callsBefore = rt.hostCallCount
            let (pager, searchTime) = try await Self.time {
                try await rt.pager("search", [plugin.query, NSNull(), NSNull(), NSNull()], as: ContentItem.self)
            }
            search.append(searchTime)
            startups.append(rt.lastStartupTimings)
            hostCalls["search", default: 0] += rt.hostCallCount - callsBefore
            if let url = pager.initial.first(where: { $0.kind == .video })?.url ?? pager.initial.first?.url {
                let callsBeforeDetails = rt.hostCallCount
                let (_, detailsTime) = try await Self.time { try await rt.callRaw("getContentDetails", [url], kind: "details") }
                details.append(detailsTime)
                hostCalls["getContentDetails", default: 0] += rt.hostCallCount - callsBeforeDetails
            }
            if pager.hasMore {
                let callsBeforeNext = rt.hostCallCount
                let (_, nextTime) = try await Self.time { try await pager.next() }
                next.append(nextTime)
                hostCalls["nextPage", default: 0] += rt.hostCallCount - callsBeforeNext
            }
            if i < PluginRuntime.maximumRetainedSessions { keep.append(pager) }
        }
        let after = Self.footprintMB()
        let hostPid = (rt.engine as? RemoteJSEngine)?.processIdentifier
        var record: [String: Any] = [
            "kind": "runtime", "engine": engineLabel, "plugin": plugin.label,
            "search": stats(search), "getContentDetails": stats(details), "nextPage": stats(next),
            "startup_context": stats(startups.map(\.context)), "startup_prelude": stats(startups.map(\.prelude)),
            "startup_script": stats(startups.map(\.script)), "startup_enable": stats(startups.map(\.enable)),
            "host_calls_per_call": hostCalls.mapValues { Double($0) / Double(Self.iterations) },
            "retained_sessions": keep.count, "live_contexts": rt.liveContextCountForTesting,
            "script_bytes": plugin.script.utf8.count,
        ]
        if let before, let after { record["app_footprint_mb"] = ["before": before, "after": after, "delta": after - before] }
        if let hostPid, let host = Self.footprintMB(pid: hostPid) { record["host_process_footprint_mb"] = host }
        report(record)
        keep.removeAll()
    }

    func testInProcessFreshContextPerCall() async throws {
        for plugin in try plugins {
            try await measureRuntime(plugin, engineLabel: "in-process JavaScriptCore") { (JSEngines.default, nil) }
        }
    }

    #if os(macOS) || os(Linux)
    func testHostProcessFreshContextPerCall() async throws {
        let executable = try XCTUnwrap(MaliciousPluginTests.hostExecutable, "build hummingbird-plugin-host")
        for plugin in try plugins {
            let started = Date()
            let engine = RemoteJSEngine(launcher: SubprocessPluginHostLauncher(executable: executable))
            let probe = try engine.makeContext { _, _, _ in "" }
            let launch = Date().timeIntervalSince(started)
            probe.close()
            report(["kind": "host_process_launch", "plugin": plugin.label, "launch_ms": launch * 1000,
                    "host_footprint_mb": engine.processIdentifier.flatMap { Self.footprintMB(pid: $0) } ?? -1])
            try await measureRuntime(plugin, engineLabel: "host process (subprocess; XPC uses the same protocol)") { (engine, engine.processIdentifier) }
            engine.terminate()
        }
    }
    #endif

    // MARK: host-call round trips

    @MainActor
    func testHostCallRoundTrip() async throws {
        let calls = 2_000
        let script = "var t = 0; for (var i = 0; i < \(calls); i++) { t += __hostCall('ping', 'a', 'b').length; } t"
        let inProcess = try JSEngines.default.makeContext { _, _, _ in "pong" }
        let (_, local) = try await Self.time { try inProcess.evaluate(script, name: "ping") }
        inProcess.close()
        var record: [String: Any] = ["kind": "host_call_round_trip", "calls": calls,
                                     "in_process_us": local / Double(calls) * 1_000_000]
        #if os(macOS) || os(Linux)
        if let executable = MaliciousPluginTests.hostExecutable {
            let engine = RemoteJSEngine(launcher: SubprocessPluginHostLauncher(executable: executable))
            let remote = try engine.makeContext { _, _, _ in "pong" }
            let (_, time) = try await Self.time { try remote.evaluate(script, name: "ping") }
            record["host_process_us"] = time / Double(calls) * 1_000_000
            remote.close()
            engine.terminate()
        }
        #endif
        #if canImport(WebKit) && !os(tvOS)
        let web = try await WebRealmHost.make { _, _, _ in "pong" }
        let world = WKContentWorld.world(name: UUID().uuidString)
        try await web.evaluate(WebRealmHost.bridge, in: world)
        let (_, webTime) = try await Self.time { try await web.evaluate(script, in: world) }
        record["webkit_sync_xhr_us"] = webTime / Double(calls) * 1_000_000
        web.close()
        #endif
        report(record)
    }

    // MARK: (b) WebKit: one hidden page per plugin, a fresh content world per call

    #if canImport(WebKit) && !os(tvOS)
    @MainActor
    func testWebKitFreshRealmPerCall() async throws {
        let prelude = try PluginWorker.loadPrelude()
        for plugin in try plugins {
            let http = HostHTTP(config: plugin.config, auth: nil, captcha: nil)
            defer { http.close() }
            let dom = DOMStoreBox()
            let calls = HostCallCounter()
            let host = try await WebRealmHost.make { name, a, b in
                calls.increment()
                switch name {
                case "http": return http.execute(json: a, parallel: b == "1")
                case "isLoggedIn": return "0"
                case "hasPackage": return plugin.config.packages.contains(a) ? "1" : "0"
                case "dom.parse": return dom.store.withLock { $0.parse(a) }
                case "dom.get": return dom.store.withLock { $0.get(handle: Int(a) ?? 0, property: b) }
                case "dom.call": return dom.store.withLock { $0.call(handle: Int(a) ?? 0, argsJSON: b) }
                default:
                    if name.hasPrefix("util.") { return UtilityPackage.call(String(name.dropFirst(5)), a) }
                    return ""
                }
            }
            defer { host.close() }
            let webBefore = WebContentProcesses.footprints()
            let config = String(decoding: try JSONEncoder().encode(plugin.config), as: UTF8.self)
            let packages = plugin.config.packages.compactMap { name -> String? in
                switch name {
                case "Http": "var http = __makeHttp();"
                case "DOMParser": "var domParser = __makeDomParser();"
                case "Utilities": "var utility = __makeUtility();"
                default: nil
                }
            }.joined(separator: "\n")
            var search: [Double] = [], details: [Double] = [], next: [Double] = []
            var startup: [Double] = [], scriptTimes: [Double] = [], enableTimes: [Double] = []
            var hostCalls: [String: Int] = [:]
            for _ in 0..<Self.iterations {
                // One call: a fresh realm, the plugin set up in it, then the call. A pager's next page
                // reuses the realm that made it, as in the runtime.
                func freshRealm() async throws -> WKContentWorld {
                    let world = WKContentWorld.world(name: UUID().uuidString)
                    let (_, setup) = try await Self.time {
                        try await host.evaluate(WebRealmHost.bridge, in: world)
                        try await host.evaluate(prelude, in: world)
                        try await host.evaluate("bridge.buildPlatform = 'ios'; __jb.setHandleBase(4294967296);\n\(packages)\nplugin.config = \(config); plugin.settings = parseSettings('{}'); 0", in: world)
                    }
                    let (_, scriptTime) = try await Self.time { try await host.evaluate(plugin.script + "\n;0", in: world) }
                    let (_, enableTime) = try await Self.time {
                        try await host.evaluate("__jb.invoke('enable', JSON.stringify([plugin.config, plugin.settings, null]), 'value')", in: world)
                    }
                    startup.append(setup)
                    scriptTimes.append(scriptTime)
                    enableTimes.append(enableTime)
                    return world
                }
                let args = String(decoding: try JSONSerialization.data(withJSONObject: [plugin.query, NSNull(), NSNull(), NSNull()]), as: UTF8.self)
                var callsBefore = calls.value
                let (searchWorld, searchTime) = try await Self.time { () -> WKContentWorld in
                    let world = try await freshRealm()
                    _ = try await host.evaluate("__jb.invoke('search', \(jsString(args)), 'pager')", in: world)
                    return world
                }
                search.append(searchTime)
                hostCalls["search", default: 0] += calls.value - callsBefore
                let page = try await host.evaluate("__jb.invoke('search', \(jsString(args)), 'pager')", in: searchWorld) as? String ?? ""
                let firstURL = (try? JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any])
                    .flatMap { ($0["value"] as? [String: Any])?["results"] as? [[String: Any]] }?.first?["url"] as? String
                if let firstURL {
                    callsBefore = calls.value
                    let detailArgs = String(decoding: try JSONSerialization.data(withJSONObject: [firstURL]), as: UTF8.self)
                    let (_, detailsTime) = try await Self.time {
                        let world = try await freshRealm()
                        _ = try await host.evaluate("__jb.invoke('getContentDetails', \(jsString(detailArgs)), 'details')", in: world)
                    }
                    details.append(detailsTime)
                    hostCalls["getContentDetails", default: 0] += calls.value - callsBefore
                }
                callsBefore = calls.value
                let (_, nextTime) = try await Self.time {
                    try await host.evaluate("__jb.nextPage(4294967297)", in: searchWorld)
                }
                next.append(nextTime)
                hostCalls["nextPage", default: 0] += calls.value - callsBefore
            }
            let webAfter = WebContentProcesses.footprints()
            report([
                "kind": "runtime", "engine": "WebKit: hidden page per plugin, fresh WKContentWorld per call, sync XHR host bridge",
                "plugin": plugin.label, "search": stats(search), "getContentDetails": stats(details), "nextPage": stats(next),
                "startup_bridge_prelude_config": stats(startup), "startup_script": stats(scriptTimes), "startup_enable": stats(enableTimes),
                "host_calls_per_call": hostCalls.mapValues { Double($0) / Double(Self.iterations) },
                "webcontent_footprint_mb": ["before": webBefore, "after": webAfter],
                "app_footprint_mb": Self.footprintMB() ?? -1,
            ])
        }
    }

    /// Whether a hung realm can be stopped: start an endless loop in a content world, then try to
    /// recover by discarding the page and making a new one. Reports whether the old WebContent
    /// process keeps burning CPU.
    @MainActor
    func testWebKitHungRealmRecovery() async throws {
        let before = Set(WebContentProcesses.pids())
        let host = try await WebRealmHost.make { _, _, _ in "" }
        let pages = Set(WebContentProcesses.pids()).subtracting(before)
        let world = WKContentWorld.world(name: "hang")
        host.evaluateDetached("while (true) {}", in: world)
        try await Task.sleep(for: .milliseconds(500))
        let cpuAtHang = pages.compactMap { WebContentProcesses.cpuSeconds(pid: $0) }.reduce(0, +)
        let started = Date()
        host.close()
        let replacement = try await WebRealmHost.make { _, _, _ in "" }
        let ok = try await replacement.evaluate("1 + 1", in: .world(name: "after")) as? Int
        let recovery = Date().timeIntervalSince(started)
        try await Task.sleep(for: .seconds(2))
        let alive = pages.filter { kill($0, 0) == 0 }
        let cpuLater = pages.compactMap { WebContentProcesses.cpuSeconds(pid: $0) }.reduce(0, +)
        report([
            "kind": "webkit_hung_realm", "new_page_ms": recovery * 1000, "new_page_works": ok == 2,
            "old_webcontent_pids": Array(pages), "old_webcontent_still_alive": Array(alive),
            "old_webcontent_cpu_seconds_during_2s_after_discard": cpuLater - cpuAtHang,
        ])
        replacement.close()
    }

    /// Whether WebKit realms keep containment: content worlds of one page share its DOM, storage
    /// and cookies, and a page reaches the network directly (not through the egress proxy) unless
    /// content rules refuse it. Probes both, with and without `blockAllButBridge`; the "network"
    /// is a loopback server here, so nothing leaves the machine.
    @MainActor
    func testWebKitRealmContainment() async throws {
        let server = try LoopbackHTTPServer()
        defer { server.stop() }
        let ruleStore = FileManager.default.temporaryDirectory.appendingPathComponent("hb-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ruleStore) }
        let probe = "http://127.0.0.1:\(server.port)/probe"
        var record: [String: Any] = ["kind": "webkit_containment"]
        for rules in [nil, ruleStore] {
            let host = try await WebRealmHost.make(ruleStore: rules) { _, _, _ in "" }
            let first = WKContentWorld.world(name: UUID().uuidString), second = WKContentWorld.world(name: UUID().uuidString)
            _ = try? await host.evaluate("""
                document.documentElement.setAttribute('data-secret', 'A');
                try { localStorage.setItem('secret', 'A'); } catch (e) {}
                try { sessionStorage.setItem('secret', 'A'); } catch (e) {}
                try { document.cookie = 'secret=A'; } catch (e) {}
                globalThis.secret = 'A'; 0
                """, in: first)
            let seen = try await host.evaluate("""
                JSON.stringify({
                  dom: document.documentElement.getAttribute('data-secret'),
                  localStorage: (function () { try { return localStorage.getItem('secret'); } catch (e) { return 'unavailable'; } })(),
                  sessionStorage: (function () { try { return sessionStorage.getItem('secret'); } catch (e) { return 'unavailable'; } })(),
                  cookie: document.cookie, global: typeof globalThis.secret
                })
                """, in: second) as? String ?? ""
            let before = server.requests.count
            _ = try? await host.evaluate("fetch('\(probe)?fetch').then(function () {}, function () {}); new Image().src = '\(probe)?image'; 0", in: second)
            try await Task.sleep(for: .milliseconds(800))
            record[rules == nil ? "default_configuration" : "block_all_but_bridge_rules"] = [
                "seen_by_another_world": seen, "direct_requests_reaching_loopback": server.requests.count - before,
            ]
            host.close()
        }
        report(record)
    }

    /// The cost of a fresh page per call (the only WebKit arrangement where calls share no DOM or
    /// storage): page creation and load, then the plugin's setup.
    @MainActor
    func testWebKitFreshPagePerCall() async throws {
        let prelude = try PluginWorker.loadPrelude()
        for plugin in try plugins {
            let config = String(decoding: try JSONEncoder().encode(plugin.config), as: UTF8.self)
            var page: [Double] = [], setup: [Double] = []
            for _ in 0..<Self.iterations {
                let (host, pageTime) = try await Self.time { try await WebRealmHost.make { _, _, _ in "" } }
                let world = WKContentWorld.page
                let (_, setupTime) = try await Self.time {
                    try await host.evaluate(WebRealmHost.bridge, in: world)
                    try await host.evaluate(prelude + "\n;0", in: world)
                    try await host.evaluate("bridge.buildPlatform = 'ios'; __jb.setHandleBase(4294967296); plugin.config = \(config); plugin.settings = parseSettings('{}'); 0", in: world)
                    try await host.evaluate(plugin.script + "\n;0", in: world)
                }
                page.append(pageTime)
                setup.append(setupTime)
                host.close()
            }
            report(["kind": "webkit_fresh_page", "plugin": plugin.label, "page_create_load": stats(page),
                    "prelude_and_script": stats(setup), "webcontent_footprint_mb": WebContentProcesses.footprints()])
        }
    }
    #endif

    #if canImport(JavaScriptCore)
    /// Script caching for fresh contexts. JavaScriptCore has no public bytecode cache (JSScript is
    /// not public API), but each virtual machine keeps an in-memory code cache keyed by source: a
    /// fresh JSContext (its own global object, nothing of the last call's) in a virtual machine that
    /// already ran the plugin skips parsing and bytecode generation. Compares a fresh virtual
    /// machine per call (today) with a fresh context in a reused one, and checks that nothing a
    /// call leaves on its global is visible to the next.
    func testScriptCachingInAReusedVirtualMachine() async throws {
        let prelude = try PluginWorker.loadPrelude()
        for plugin in try plugins {
            let config = String(decoding: try JSONEncoder().encode(plugin.config), as: UTF8.self)
            let setup = "bridge.buildPlatform = 'ios'; __jb.setHandleBase(4294967296); plugin.config = \(config); plugin.settings = parseSettings('{}'); 0"
            var leaks = 0
            func startup(in machine: JSVirtualMachine?) throws -> (context: Double, prelude: Double, script: Double) {
                let began = Date()
                let context: JSContext = machine.map { JSContext(virtualMachine: $0) } ?? JSContext()
                let host: @convention(block) (String, String, String) -> String = { _, _, _ in "" }
                context.setObject(host, forKeyedSubscript: "__hostCall" as NSString)
                let made = Date()
                context.evaluateScript(prelude)
                context.evaluateScript(setup)
                let preludeDone = Date()
                context.evaluateScript(plugin.script)
                let scriptDone = Date()
                if let exception = context.exception { throw JSEngineError(message: exception.toString() ?? "script error") }
                if context.evaluateScript("typeof globalThis.__benchMarker")?.toString() != "undefined" { leaks += 1 }
                context.evaluateScript("globalThis.__benchMarker = 'left by an earlier call'")
                return (made.timeIntervalSince(began), preludeDone.timeIntervalSince(made), scriptDone.timeIntervalSince(preludeDone))
            }
            let before = Self.footprintMB()
            let fresh = try (0..<Self.iterations).map { _ in try startup(in: nil) }
            let machine = JSVirtualMachine()
            _ = try startup(in: machine)  // the first call fills the cache
            let cached = try (0..<Self.iterations).map { _ in try startup(in: machine) }
            report([
                "kind": "script_caching", "plugin": plugin.label, "script_bytes": plugin.script.utf8.count,
                "fresh_vm_context": stats(fresh.map(\.context)), "fresh_vm_prelude": stats(fresh.map(\.prelude)),
                "fresh_vm_script": stats(fresh.map(\.script)),
                "reused_vm_context": stats(cached.map(\.context)), "reused_vm_prelude": stats(cached.map(\.prelude)),
                "reused_vm_script": stats(cached.map(\.script)),
                "globals_seen_by_a_later_context": leaks,
                "app_footprint_mb": ["before": before ?? -1, "after": Self.footprintMB() ?? -1],
            ])
            XCTAssertEqual(leaks, 0, "a fresh context never sees an earlier context's globals")
        }
    }
    #endif
}

final class HostCallCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

final class DOMStoreBox: Sendable {
    let store = Mutex(DOMStore())
}

#if canImport(WebKit) && !os(tvOS)
/// One hidden page per plugin; each call runs in a fresh content world. Host calls go to the app
/// synchronously, as plugin code expects, through a synchronous XHR to a custom scheme.
@MainActor
final class WebRealmHost: NSObject, WKURLSchemeHandler {
    typealias HostCall = @Sendable (String, String, String) -> String

    static let bridge = """
        globalThis.__hostCall = function (name, a, b) {
          var x = new XMLHttpRequest();
          x.open('POST', 'hbhost://plugin/call/' + encodeURIComponent(name), false);
          x.send(JSON.stringify([String(a), String(b)]));
          return x.responseText;
        }; 0
        """

    private let hostCall: HostCall
    private(set) var webView: WKWebView?

    private init(hostCall: @escaping HostCall) {
        self.hostCall = hostCall
    }

    /// Content rules that refuse every load except the host bridge, so a realm's only way out is
    /// `__hostCall` (and so the app's egress proxy).
    static let blockAllButBridge = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^hbhost:"},"action":{"type":"ignore-previous-rules"}}]
        """

    /// `ruleStore`: where to compile `blockAllButBridge` (a temporary directory: never the
    /// default store); nil applies no content rules.
    static func make(ruleStore: URL? = nil, _ hostCall: @escaping HostCall) async throws -> WebRealmHost {
        let host = WebRealmHost(hostCall: hostCall)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(host, forURLScheme: "hbhost")
        if let ruleStore, let store = WKContentRuleListStore(url: ruleStore) {
            let rules = try await store.compileContentRuleList(forIdentifier: "block-all-but-bridge", encodedContentRuleList: blockAllButBridge)
            if let rules { configuration.userContentController.add(rules) }
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        host.webView = webView
        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: URL(string: "hbhost://plugin/"))
        for _ in 0..<500 where webView.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        return host
    }

    @discardableResult
    func evaluate(_ script: String, in world: WKContentWorld) async throws -> Any? {
        guard let webView else { throw URLError(.cancelled) }
        return try await webView.evaluateJavaScript(script, in: nil, contentWorld: world)
    }

    func evaluateDetached(_ script: String, in world: WKContentWorld) {
        webView?.evaluateJavaScript(script, in: nil, in: world) { _ in }
    }

    func close() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
    }

    /// Answers a host call. The page's script waits (synchronous XHR) while this runs; the main
    /// actor is free meanwhile, since the measuring task awaits the evaluation.
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let request = task.request
        guard let url = request.url else { return }
        let reply: (String, Data)
        if url.path.hasPrefix("/call/") {
            let name = String(url.path.dropFirst("/call/".count)).removingPercentEncoding ?? ""
            let args = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }) ?? ["", ""]
            reply = ("text/plain", Data(hostCall(name, args.first ?? "", args.count > 1 ? args[1] : "").utf8))
        } else {
            reply = ("text/html", Data("<!doctype html><html><body></body></html>".utf8))
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": reply.0])!)
        task.didReceive(reply.1)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// WebKit's content processes, found by name (the measurement runs unsandboxed).
enum WebContentProcesses {
    static func pids() -> [Int32] {
        #if canImport(Darwin)
        var pids = [Int32](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(Int(max(0, count))).filter { pid in
            var name = [CChar](repeating: 0, count: 256)
            return proc_name(pid, &name, 256) > 0 && String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("WebContent")
        }
        #else
        return []
        #endif
    }

    static func footprints() -> [String: Double] {
        Dictionary(uniqueKeysWithValues: pids().compactMap { pid in
            PluginCallCostBenchmarks.footprintMB(pid: pid).map { (String(pid), $0) }
        })
    }

    static func cpuSeconds(pid: Int32) -> Double? {
        #if canImport(Darwin)
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000
        #else
        return nil
        #endif
    }
}
#endif
