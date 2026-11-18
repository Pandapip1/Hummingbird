import Foundation
import Synchronization
import XCTest
@testable import HummingbirdKit

/// Hostile plugins (Tests/malicious-plugins/*.js) attempt each attack in Documentation/PluginSecurity.md;
/// every test asserts the attack is contained. Nothing here reaches the network: HTTP goes to an in-memory
/// stub, and names resolve through `TestResolver`.
final class MaliciousPluginTests: XCTestCase {
    // MARK: fixtures

    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("malicious-plugins")
    }

    /// What a hostile probe reports back.
    struct Probe: PluginOutput, Equatable {
        var code: Int?
        var body: String?
        var error: String?
        mutating func contain(_ context: PluginOutputContext) {}
    }

    /// Records every request that reached "the network" and answers it.
    final class Stub: URLProtocol {
        struct Seen: Sendable { let url: URL; let headers: [String: String] }
        typealias Responder = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data)
        private static let state = Mutex<(seen: [Seen], responder: Responder?)>(([], nil))

        static func reset(_ responder: Responder? = nil) { state.withLock { $0 = ([], responder) } }
        static var seen: [Seen] { state.withLock { $0.seen } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let responder: Responder? = Self.state.withLock {
                $0.seen.append(Seen(url: request.url!, headers: request.allHTTPHeaderFields ?? [:]))
                return $0.responder
            }
            let answer: (status: Int, headers: [String: String], body: Data) = responder?(request) ?? (200, [:], Data("ok".utf8))
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
            if (300..<400).contains(answer.status), let location = answer.headers["Location"], let next = URL(string: location) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static func session() -> URLSession {
            let configuration = HostHTTP.containedConfiguration()
            configuration.protocolClasses = [Stub.self]
            return URLSession(configuration: configuration)
        }
    }

    private static let fast = PluginRuntime.Timeouts(call: 1, enable: 5, requestModifier: 1)

    private func hostile(_ file: String, id: String = "hostile", allow: [String] = ["allowed.test"],
                         approvals: [LocalHostApproval] = [], resolver: TestResolver = .publicOnly,
                         auth: SourceAuth? = nil, timeouts: PluginRuntime.Timeouts = fast) throws -> PluginRuntime {
        let json = try JSONSerialization.data(withJSONObject: [
            "name": "Hostile \(id)", "id": id, "version": 1, "scriptUrl": "x.js", "allowUrls": allow, "packages": ["Http"],
        ] as [String: Any])
        let config = try JSONDecoder().decode(PluginConfig.self, from: json)
        let script = try String(contentsOf: Self.directory.appendingPathComponent(file), encoding: .utf8)
        let runtime = PluginRuntime(approval: testLoadApproval(config), config: config,
                                    script: try ScriptSignature.check(script, for: config), settings: [:], auth: auth, captcha: nil,
                                    approvals: approvals, resolver: resolver, httpSession: Stub.session(), timeouts: timeouts)
        addTeardownBlock { await runtime.stop() }
        return runtime
    }

    override func setUp() {
        super.setUp()
        Stub.reset()
    }

    private func elapsed<T>(_ body: () async throws -> T) async rethrows -> (T, TimeInterval) {
        let start = Date()
        let value = try await body()
        return (value, Date().timeIntervalSince(start))
    }

    // MARK: availability

    func testCPULoopTimesOutWhileOtherCallsOfThePluginKeepRunning() async throws {
        let rt = try hostile("availability.js")
        _ = try await rt.enable()
        let spinStarted = Date()
        let spinning = Task { try await rt.call("spin", [2_500], as: String.self) }
        try await Task.sleep(for: .milliseconds(100))
        // The stuck context does not hold up the plugin's other calls: they run in another context.
        let (quick, quickTime) = try await elapsed { try await rt.call("quick", as: Int.self) }
        XCTAssertEqual(quick, 42)
        XCTAssertLessThan(quickTime, 0.8)
        let (outcome, spinTime) = await elapsed { () -> Result<String, Error> in
            do { return .success(try await spinning.value) } catch { return .failure(error) }
        }
        guard case .failure(PluginError.timeout) = outcome else { return XCTFail("the loop must time out, got \(outcome)") }
        _ = spinTime
        XCTAssertLessThan(Date().timeIntervalSince(spinStarted), 1.5, "the caller is released at the deadline, not when the loop ends")
    }

    func testHungContextsSuspendThePluginUntilTheyReturn() async throws {
        // A fresh context's first call also gets the enable allowance; keep it short here.
        let rt = try hostile("availability.js", timeouts: .init(call: 1, enable: 1, requestModifier: 1))
        _ = try await rt.enable()
        async let first: String = rt.call("spin", [3_000])
        async let second: String = rt.call("spin", [3_000])
        _ = try? await first
        _ = try? await second
        do {
            _ = try await rt.call("quick", as: Int.self)
            XCTFail("a plugin with two stuck contexts is suspended")
        } catch PluginError.unresponsive(let message) {
            XCTAssertTrue(message.contains("stopped responding"), message)
        }
        XCTAssertTrue(rt.isSuspended)
        // The loops end; the plugin recovers by itself.
        try await Task.sleep(for: .milliseconds(1_800))
        XCTAssertFalse(rt.isSuspended)
        let quick = try await rt.call("quick", as: Int.self)
        XCTAssertEqual(quick, 42)
    }

    func testALoopOfHostCallsStopsReachingTheNetworkAtItsDeadline() async throws {
        let rt = try hostile("availability.js")
        _ = try await rt.enable()
        do {
            _ = try await rt.call("hostCallSpin", [2_000], as: Int.self)
            XCTFail("must time out")
        } catch PluginError.timeout {}
        let atDeadline = Stub.seen.count
        XCTAssertLessThanOrEqual(atDeadline, Int(PluginLimits.requestBurst) + Int(PluginLimits.requestsPerSecond) + 1,
                                 "the request budget bounds a burst")
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertLessThanOrEqual(Stub.seen.count - atDeadline, 1, "after its deadline no request leaves")
    }

    func testSleepsAndUnsettledPromisesEndAtTheDeadline() async throws {
        let rt = try hostile("availability.js")
        _ = try await rt.enable()
        let (sleepOutcome, sleepTime) = await elapsed { () -> Error? in
            do { _ = try await rt.call("sleepForever", as: String.self); return nil } catch { return error }
        }
        XCTAssertNotNil(sleepOutcome)
        XCTAssertLessThan(sleepTime, 1.6)
        let (promiseOutcome, promiseTime) = await elapsed { () -> Error? in
            do { _ = try await rt.call("neverSettles", as: String.self); return nil } catch { return error }
        }
        guard case PluginError.timeout? = promiseOutcome else { return XCTFail("a promise that never settles times out") }
        XCTAssertLessThan(promiseTime, 2)
    }

    func testTimersAndLogsAreBounded() async throws {
        let rt = try hostile("availability.js")
        let lines = Mutex(0)
        rt.onLog = { _ in lines.withLock { $0 += 1 } }
        _ = try await rt.call("timerFlood", as: Int.self)
        try await Task.sleep(for: .milliseconds(300))
        let fired = try await rt.call("timersFired", as: Int.self)
        XCTAssertLessThanOrEqual(fired, PluginLimits.maximumTimers)
        _ = try await rt.call("logFlood", as: Int.self)
        XCTAssertLessThanOrEqual(lines.withLock { $0 }, PluginLimits.logLinesPerSecond * 3)
    }

    func testContextsShareOnlyExplicitState() async throws {
        let rt = try hostile("availability.js", timeouts: .init(call: 5, enable: 5, requestModifier: 1))
        _ = try await rt.enable()
        // Keep the first context busy so the next call is served by a second, fresh one.
        async let busy: String = rt.call("spin", [600])
        try await Task.sleep(for: .milliseconds(100))
        let set = try await rt.call("setMarker", ["planted"], as: String.self)
        XCTAssertEqual(set, "planted")
        _ = try await busy
        // Globals planted in one context are not visible in the other.
        async let busyAgain: String = rt.call("spin", [600])
        try await Task.sleep(for: .milliseconds(100))
        let markers = Set([try await rt.call("getMarker", as: String.self)])
        _ = try await busyAgain
        XCTAssertTrue(markers.isSubset(of: ["planted", "unset"]))
        let other = try hostile("availability.js", id: "other")
        let otherMarker = try await other.call("getMarker", as: String.self)
        XCTAssertEqual(otherMarker, "unset", "plugins never share a context")
    }

    // MARK: confidentiality

    private func probe(_ rt: PluginRuntime, _ url: String, headers: [String: String] = [:]) async throws -> Probe {
        try await rt.call("probe", [url, headers], as: Probe.self)
    }

    func testOnlyAllowListedPublicHTTPDestinationsAreReachable() async throws {
        let resolver = TestResolver(answers: [
            "rebind.allowed.test": ["10.0.0.7"], "cgnat.allowed.test": ["100.64.3.4"],
            "mapped.allowed.test": ["::ffff:192.168.1.1"], "nat64.allowed.test": ["64:ff9b::c0a8:101"],
            "meta.allowed.test": ["169.254.169.254"], "nas.allowed.test": ["192.168.1.30"],
        ])
        let nasApproval = LocalHostApproval(host: "nas.allowed.test", port: 80, networks: [IPNetwork(cidr: "192.168.1.20")!])
        let rt = try hostile("network.js", allow: ["allowed.test", ".allowed.test"], approvals: [nasApproval], resolver: resolver)
        let everywhere = try hostile("network.js", id: "everywhere", allow: ["everywhere"], resolver: resolver)
        let cases: [(PluginRuntime, String, String)] = [
            (rt, "https://not-allowed.test/", "non-whitelisted"),
            (rt, "file:///etc/passwd", "only use http"),
            (rt, "ftp://allowed.test/x", "only use http"),
            (rt, "http://rebind.allowed.test/", "local network"),
            (rt, "http://cgnat.allowed.test/", "local network"),
            (rt, "http://mapped.allowed.test/", "local network"),
            (rt, "http://nat64.allowed.test/", "local network"),
            (rt, "http://meta.allowed.test/latest/meta-data", "metadata"),
            (rt, "http://nas.allowed.test/", "now points to 192.168.1.30"),
            (everywhere, "http://127.0.0.1:8080/", "local network"),
            (everywhere, "http://[::1]/", "local network"),
            (everywhere, "http://10.1.2.3/", "local network"),
            (everywhere, "http://[fd7a:115c:a1e0::5]/", "local network"),
            (everywhere, "http://169.254.169.254/", "metadata"),
            (everywhere, "http://[fd00:ec2::254]/", "metadata"),
            (everywhere, "http://router.local/", "local network"),
        ]
        for (runtime, url, expected) in cases {
            let result = try await probe(runtime, url)
            XCTAssertTrue(result.error?.contains(expected) == true, "\(url): \(result)")
        }
        XCTAssertTrue(Stub.seen.isEmpty, "no refused request reached the network: \(Stub.seen.map(\.url))")
        let allowed = try await probe(rt, "https://allowed.test/ok")
        XCTAssertEqual(allowed.code, 200)
    }

    func testRedirectsAreCheckedHopByHop() async throws {
        Stub.reset { request in
            switch request.url?.path {
            case "/to-metadata": (302, ["Location": "http://169.254.169.254/latest"], Data())
            case "/to-unlisted": (302, ["Location": "https://evil.test/"], Data())
            case "/to-file": (302, ["Location": "file:///etc/passwd"], Data())
            default: (200, [:], Data("ok".utf8))
            }
        }
        let rt = try hostile("network.js")
        // The metadata hop is not on the allow-list either; either refusal stops it.
        for (path, expected) in [("/to-metadata", "169.254.169.254"), ("/to-unlisted", "non-whitelisted"), ("/to-file", "")] {
            let result = try await probe(rt, "https://allowed.test\(path)")
            XCTAssertNotEqual(result.code, 200, path)
            if !expected.isEmpty { XCTAssertTrue(result.error?.contains(expected) == true, "\(path): \(result)") }
        }
        XCTAssertEqual(Set(Stub.seen.compactMap(\.url.host)), ["allowed.test"], "no hop past the refused redirect")
    }

    func testNoPluginSeesAnotherPluginsCredentialsOrInjectsHeaders() async throws {
        let victim = try hostile("network.js", id: "victim", allow: [".victim.test"],
                                 auth: SourceAuth(cookieMap: [".victim.test": ["SID": "victim-secret"]],
                                                  headers: ["victim.test": ["authorization": "Bearer victim-token"]]))
        let attacker = try hostile("network.js", id: "attacker", allow: [".victim.test", "allowed.test"])
        _ = try await attacker.call("probeAuth", ["https://victim.test/steal"], as: Probe.self)
        _ = try await victim.call("probeAuth", ["https://victim.test/own"], as: Probe.self)
        _ = try await probe(attacker, "https://allowed.test/h", headers: [
            "Host": "evil.test", "X-Smuggle": "a\r\nInjected: 1", "Proxy-Authorization": "x", "Transfer-Encoding": "chunked",
        ])
        let seen = Stub.seen
        let steal = try XCTUnwrap(seen.first { $0.url.path == "/steal" })
        XCTAssertNil(steal.headers["Cookie"], "the attacker's request carries no victim cookie")
        XCTAssertNil(steal.headers["Authorization"])
        let own = try XCTUnwrap(seen.first { $0.url.path == "/own" })
        XCTAssertEqual(own.headers["Cookie"], "SID=victim-secret")
        let injected = try XCTUnwrap(seen.first { $0.url.path == "/h" })
        XCTAssertNotEqual(injected.headers["Host"], "evil.test")
        XCTAssertNil(injected.headers["X-Smuggle"])
        XCTAssertNil(injected.headers["Proxy-Authorization"])
        XCTAssertNil(injected.headers["Transfer-Encoding"])
    }

    func testBatchesAndResponsesAreBounded() async throws {
        let rt = try hostile("network.js")
        let ok = try await rt.call("batchBomb", [PluginLimits.maximumBatchRequests + 1], as: Int.self)
        XCTAssertLessThanOrEqual(ok, 0)
        XCTAssertTrue(Stub.seen.isEmpty)
        Stub.reset { _ in (200, ["Content-Length": "\(PluginLimits.maximumResponseBodyBytes + 1)"], Data("small".utf8)) }
        let huge = try await probe(rt, "https://allowed.test/huge")
        XCTAssertTrue(huge.error?.contains("larger than plugins may receive") == true, "\(huge)")
    }

    func testPluginHTTPCarriesNoAmbientCredentials() {
        let configuration = HostHTTP.containedConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }

    // MARK: integrity

    func testReturnedDataIsContainedForThePluginThatMadeIt() async throws {
        let rt = try hostile("integrity.js")
        let pager = try await rt.pager("getHome", as: ContentItem.self)
        XCTAssertEqual(pager.initial.count, PluginLimits.maximumPageItems)
        for item in pager.initial.prefix(20) {
            XCTAssertEqual(item.platformID.pluginId, "hostile", "a plugin cannot claim another plugin's identity")
            XCTAssertEqual(item.author?.id.pluginId ?? "hostile", "hostile")
            XCTAssertTrue(item.thumbnails.isEmpty, "javascript: and LAN thumbnails are dropped: \(item.thumbnails)")
            XCTAssertFalse(item.name.unicodeScalars.contains { (0x202a...0x202e).contains($0.value) })
        }
        // An endless pager ends.
        var pages = 1
        while pager.hasMore, pages < PluginLimits.maximumPages + 10 {
            _ = try await pager.next()
            pages += 1
        }
        XCTAssertFalse(pager.hasMore)
        XCTAssertLessThanOrEqual(pages, PluginLimits.maximumPages)
    }

    func testOversizedResultsAndErrorsAreRefused() async throws {
        let rt = try hostile("integrity.js", timeouts: .init(call: 20, enable: 5, requestModifier: 1))
        do {
            _ = try await rt.call("huge", as: String.self)
            XCTFail("a result over the limit must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too much data"), error.localizedDescription)
        }
        do {
            _ = try await rt.call("throwHuge", as: String.self)
            XCTFail("must throw")
        } catch {
            XCTAssertLessThanOrEqual(error.localizedDescription.count, 2_000)
        }
    }

    func testRequestModifiersCanOnlyChangeWhatTheyMay() async throws {
        let rt = try hostile("integrity.js", allow: ["allowed.test"])
        let original = URL(string: "https://cdn.test/v.mp4")!
        for target in ["http://192.168.1.1/admin", "https://evil.test/v.mp4", "file:///etc/passwd", "http://router.local/"] {
            let found = try await rt.handleFromSource("getModifier", [target])
            let ref = try XCTUnwrap(found)
            do {
                _ = try await rt.modifyRequest(handle: ref.handle, url: original, headers: ["Range": "bytes=0-1"])
                XCTFail("\(target) must be refused")
            } catch {}
        }
        let signedRef = try await rt.handleFromSource("getModifier", ["https://cdn.test/v.mp4?sig=1"])
        let signed = try XCTUnwrap(signedRef)
        let request = try await rt.modifyRequest(handle: signed.handle, url: original, headers: ["Range": "bytes=0-1"])
        XCTAssertEqual(request.url.absoluteString, "https://cdn.test/v.mp4?sig=1")
        XCTAssertEqual(request.headers, ["Range": "bytes=0-1"], "Host and smuggled headers are dropped")
        let slowRef = try await rt.handleFromSource("getModifier", ["slow"])
        let slow = try XCTUnwrap(slowRef)
        do {
            _ = try await rt.modifyRequest(handle: slow.handle, url: original, headers: [:])
            XCTFail("a slow modifier times out")
        } catch PluginError.timeout {}
    }

    // MARK: install and sync

    private struct MemoryHost: Sendable {
        let files: [URL: Data]
        var fetch: PluginFetch {
            let files = files
            return { request in
                guard let url = request.url, let data = files[url] else { throw URLError(.fileDoesNotExist) }
                return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private static let validScript = """
    source.getHome = function () { return new ContentPager([], false); };
    source.search = function () { return new ContentPager([], false); };
    source.isChannelUrl = function () { return false; };
    source.getChannel = function () { return null; };
    source.getChannelContents = function () { return new ContentPager([], false); };
    source.isContentDetailsUrl = function () { return false; };
    source.getContentDetails = function () { return null; };
    """

    private func publish(_ id: String, at base: String, extra: [String: Any] = [:]) throws -> (URL, [URL: Data]) {
        let configURL = URL(string: "\(base)/config.json")!
        var config: [String: Any] = ["name": "Plugin \(id)", "id": id, "version": 1, "scriptUrl": "./script.js",
                                     "sourceUrl": configURL.absoluteString, "allowUrls": ["api.example.test"]]
        config.merge(extra) { _, new in new }
        return (configURL, [configURL: try JSONSerialization.data(withJSONObject: config),
                            URL(string: "\(base)/script.js")!: Data(Self.validScript.utf8)])
    }

    @MainActor
    func testAnotherPublisherClaimingAPluginsIDInheritsNothing() async throws {
        let (genuineURL, genuineFiles) = try publish("victim", at: "https://genuine.example.test/p")
        let (impostorURL, impostorFiles) = try publish("victim", at: "https://impostor.example.test/p")
        let stores = makeTestStores()
        let manager = PluginManager(storage: stores.storage, credentialStore: stores.credentialStore,
                                    policy: makeTestPolicy(), fetch: MemoryHost(files: genuineFiles.merging(impostorFiles) { a, _ in a }).fetch)
        manager.resolver = TestResolver.publicOnly
        manager.commit(try await manager.prepareInstall(from: genuineURL.absoluteString))
        manager.saveAuth(SourceAuth(cookieMap: [".example.test": ["SID": "secret"]]), pluginID: "victim")
        manager.setSetting(pluginID: "victim", key: "apiKey", value: "user-secret")
        XCTAssertNotNil(manager.auth(for: "victim"))

        let impostor = try await manager.prepareInstall(from: impostorURL.absoluteString)
        XCTAssertTrue(impostor.warnings.contains { $0.title == "Different author" })
        manager.commit(impostor)
        XCTAssertNil(manager.auth(for: "victim"), "the impostor does not get the sign-in")
        XCTAssertTrue(manager.plugin("victim")?.settings.isEmpty == true, "nor the settings")

        // The genuine publisher's own update keeps them.
        manager.commit(try await manager.prepareInstall(from: genuineURL.absoluteString))
        manager.saveAuth(SourceAuth(cookieMap: [".example.test": ["SID": "again"]]), pluginID: "victim")
        manager.commit(try await manager.prepareInstall(from: genuineURL.absoluteString))
        XCTAssertNotNil(manager.auth(for: "victim"))
    }

    @MainActor
    func testSyncedPluginsAskingForMoreWaitForTheUser() async throws {
        let (plainURL, plainFiles) = try publish("plain", at: "https://plain.example.test/p")
        let (wideURL, wideFiles) = try publish("wide", at: "https://wide.example.test/p",
                                               extra: ["allowUrls": ["everywhere"], "allowEval": true])
        let (lanURL, lanFiles) = try publish("lan", at: "https://lan.example.test/p", extra: ["allowUrls": ["nas.local:8096"]])
        let stores = makeTestStores()
        let manager = PluginManager(storage: stores.storage, credentialStore: stores.credentialStore,
                                    policy: makeTestPolicy(), fetch: MemoryHost(files: plainFiles.merging(wideFiles) { a, _ in a }.merging(lanFiles) { a, _ in a }).fetch)
        manager.resolver = TestResolver(answers: ["nas.local": ["192.168.1.20"]])
        func change(_ id: String, _ url: URL) throws -> PluginSyncChange {
            var installed = InstalledPlugin(config: try JSONDecoder().decode(PluginConfig.self, from: Data(#"{"name":"x"}"#.utf8)), script: "")
            installed.config.id = id
            installed.config.sourceUrl = url.absoluteString
            return PluginSyncChange(key: HummingbirdProfileSchema.key(for: id), plugin: try XCTUnwrap(SyncedPlugin(installed)))
        }
        _ = await manager.applySynced([try change("plain", plainURL), try change("wide", wideURL), try change("lan", lanURL)])
        XCTAssertNotNil(manager.plugin("plain"), "an ordinary plugin installs as on the other device")
        XCTAssertNil(manager.plugin("wide"))
        XCTAssertNil(manager.plugin("lan"))
        XCTAssertNotNil(manager.syncInstalls["wide"]?.confirmation)
        XCTAssertTrue(manager.syncInstalls["lan"]?.confirmation?.warnings.contains { $0.contains("nas.local:8096 → 192.168.1.20") } == true)

        manager.confirmSyncedReplacement("lan")
        XCTAssertEqual(manager.approvals(for: "lan").map(\.summary), ["nas.local:8096 → 192.168.1.20"],
                       "approving shows and binds the address it resolved to")
        manager.keepLocalPlugin("wide")
        _ = await manager.applySynced([try change("wide", wideURL)])
        XCTAssertNil(manager.plugin("wide"))
        XCTAssertNil(manager.syncInstalls["wide"], "a declined install is not asked again this session")
    }

    @MainActor
    func testLocalNetworkApprovalsAreExactAndRevocable() async throws {
        let (url, files) = try publish("lan", at: "https://lan.example.test/p", extra: ["allowUrls": ["jellyfin.tailnet.ts.net:8096"]])
        let stores = makeTestStores()
        let manager = PluginManager(storage: stores.storage, credentialStore: stores.credentialStore, policy: makeTestPolicy(), fetch: MemoryHost(files: files).fetch)
        manager.resolver = TestResolver(answers: ["jellyfin.tailnet.ts.net": ["100.101.102.103"]])
        let preview = try await manager.prepareInstall(from: url.absoluteString)
        XCTAssertTrue(preview.warnings.contains { $0.detail.contains("jellyfin.tailnet.ts.net:8096 → 100.101.102.103") })
        manager.commit(preview)
        XCTAssertEqual(manager.approvals(for: "lan").first?.networks.map(\.description), ["100.101.102.103"])

        XCTAssertThrowsError(try manager.approveLocalAddress(pluginID: "lan", host: "jellyfin.tailnet.ts.net", port: 8096, cidr: "0.0.0.0/0"))
        XCTAssertThrowsError(try manager.approveLocalAddress(pluginID: "lan", host: "jellyfin.tailnet.ts.net", port: 8096, cidr: "169.254.169.254"))
        XCTAssertThrowsError(try manager.approveLocalAddress(pluginID: "lan", host: "elsewhere.test", port: 80, cidr: "10.0.0.1"),
                             "only hosts the source names")
        try manager.approveLocalAddress(pluginID: "lan", host: "jellyfin.tailnet.ts.net", port: 8096, cidr: "100.101.102.104/32")
        XCTAssertEqual(manager.approvals(for: "lan").first?.networks.count, 2)

        manager.revokeLocalHost(pluginID: "lan", approvalID: "jellyfin.tailnet.ts.net:8096")
        XCTAssertTrue(manager.approvals(for: "lan").isEmpty)
        XCTAssertNil(SyncedPlugin(try XCTUnwrap(manager.plugin("lan"))).map { String(describing: $0) }?.range(of: "100.101"),
                     "approvals never sync")
    }
}
