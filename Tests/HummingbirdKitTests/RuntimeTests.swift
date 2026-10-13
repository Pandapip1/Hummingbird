import XCTest
@testable import HummingbirdKit

/// Runs a small plugin inside a real JavaScriptCore host context (no network involved).
final class RuntimeTests: XCTestCase {
    private final class WarningStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) { lock.withLock { values.append(value) } }
        func snapshot() -> [String] { lock.withLock { values } }
    }

    func testDetailsCacheFingerprintTracksRuntimeInputs() throws {
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(#"{"name":"Cache","id":"cache-test","scriptUrl":"x.js","version":1}"#.utf8)
        )
        let baseline = PluginRuntime(config: config, script: "one", settings: ["mode": "a"], auth: nil, captcha: nil)
        let identical = PluginRuntime(config: config, script: "one", settings: ["mode": "a"], auth: nil, captcha: nil)
        let changedScript = PluginRuntime(config: config, script: "two", settings: ["mode": "a"], auth: nil, captcha: nil)
        let changedSetting = PluginRuntime(config: config, script: "one", settings: ["mode": "b"], auth: nil, captcha: nil)
        let changedAuth = PluginRuntime(
            config: config,
            script: "one",
            settings: ["mode": "a"],
            auth: SourceAuth(cookieMap: ["example.com": ["SID": "value"]]),
            captcha: nil
        )

        XCTAssertEqual(baseline.detailsCacheFingerprint, identical.detailsCacheFingerprint)
        XCTAssertNotEqual(baseline.detailsCacheFingerprint, changedScript.detailsCacheFingerprint)
        XCTAssertNotEqual(baseline.detailsCacheFingerprint, changedSetting.detailsCacheFingerprint)
        XCTAssertNotEqual(baseline.detailsCacheFingerprint, changedAuth.detailsCacheFingerprint)
    }

    func testReloadDoesNotDeliverOldTimerIntoNewContext() async throws {
        let script = """
        source.enable = function () {
            source.marker = "clean";
            if (typeof __reloadData === "undefined") {
                setTimeout(function () { source.marker = "stale"; }, 50);
            } else {
                setTimeout(function () { source.marker = "new timer fired early"; }, 10000);
            }
        };
        source.readMarker = function () { return source.marker; };
        source.getHome = function () { return new ContentPager([], false); };
        source.search = function () { return new ContentPager([], false); };
        source.isChannelUrl = function () { return false; };
        source.getChannel = function () { return null; };
        source.getChannelContents = function () { return new ContentPager([], false); };
        source.isContentDetailsUrl = function () { return false; };
        source.getContentDetails = function () { return null; };
        """
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(#"{"name":"Timer isolation","id":"timer-isolation","scriptUrl":"x.js","version":1}"#.utf8)
        )
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        defer { Task { await runtime.stop() } }

        _ = try await runtime.enable()
        await runtime.reload(reloadData: "new")
        let initialMarker = try await runtime.call("readMarker", as: String.self)
        XCTAssertEqual(initialMarker, "clean")
        try await Task.sleep(for: .milliseconds(150))
        let markerAfterOldTimer = try await runtime.call("readMarker", as: String.self)
        XCTAssertEqual(markerAfterOldTimer, "clean")
    }

    func testReloadDoesNotLetOldPromisePollNewContext() async throws {
        let script = """
        source.enable = function () {};
        source.delayed = function () {
            var value = typeof __reloadData === "undefined" ? "old" : "new";
            return new Promise(function (resolve) { setTimeout(function () { resolve(value); }, 50); });
        };
        source.getHome = function () { return new ContentPager([], false); };
        source.search = function () { return new ContentPager([], false); };
        source.isChannelUrl = function () { return false; };
        source.getChannel = function () { return null; };
        source.getChannelContents = function () { return new ContentPager([], false); };
        source.isContentDetailsUrl = function () { return false; };
        source.getContentDetails = function () { return null; };
        """
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(#"{"name":"Promise isolation","id":"promise-isolation","scriptUrl":"x.js","version":1}"#.utf8)
        )
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        defer { Task { await runtime.stop() } }

        let oldCall = Task { try await runtime.call("delayed", as: String.self) }
        try await Task.sleep(for: .milliseconds(10))
        await runtime.reload(reloadData: "new")
        let newValue = try await runtime.call("delayed", as: String.self)
        XCTAssertEqual(newValue, "new")
        do {
            _ = try await oldCall.value
            XCTFail("The old context's promise should be cancelled by reload")
        } catch is CancellationError {}
    }

    func testUnifiedDiffPreservesCRLF() throws {
        let diff = "--- old\n+++ new\n@@ -1,2 +1,2 @@\n alpha\n-beta\n+bravo"
        XCTAssertEqual(try UnifiedDiff.apply(diff, to: "alpha\r\nbeta"), "alpha\r\nbravo")
    }

    func testUnifiedDiffAppliesMultipleHunks() throws {
        let diff = """
        --- old
        +++ new
        @@ -1,2 +1,2 @@
         alpha
        -beta
        +bravo
        @@ -4,1 +4,2 @@
         delta
        +echo
        """
        XCTAssertEqual(
            try UnifiedDiff.apply(diff, to: "alpha\nbeta\ngamma\ndelta"),
            "alpha\nbravo\ngamma\ndelta\necho"
        )
    }

    func testAsyncFeatureAndBrowserFallbackEvaluation() async throws {
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(#"{"name":"Browser fallback","packagesOptional":["Browser"]}"#.utf8)
        )
        let script = """
        source.features = function() { return bridge.supportedFeatures; };
        source.dynamic = function() { return eval("40 + 2"); };
        """
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        defer { Task { await runtime.stop() } }
        let features: [String] = try await runtime.call("features")
        XCTAssertTrue(features.contains("Async"))
        let value: Int = try await runtime.call("dynamic")
        XCTAssertEqual(value, 42)
    }

    func testUnsupportedCapabilityProbesWarnOnce() async throws {
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(#"{"name":"Capability warnings","id":"capability-warnings"}"#.utf8)
        )
        let script = """
        source.probe = function() {
            bridge.supportedFeatures.includes("MissingFeature");
            bridge.supportedFeatures.indexOf("MissingFeature");
            bridge.hasPackage("MissingPackage");
            bridge.hasPackage("MissingPackage");
            return true;
        };
        """
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        defer { Task { await runtime.stop() } }
        let warningStore = WarningStore()
        runtime.onLog = { warningStore.append($0) }

        let probed: Bool = try await runtime.call("probe")
        XCTAssertTrue(probed)
        let warnings = warningStore.snapshot()

#if DEBUG
        XCTAssertEqual(warnings.filter { $0.contains("MissingFeature") }.count, 1)
        XCTAssertEqual(warnings.filter { $0.contains("MissingPackage") }.count, 1)
#else
        XCTAssertTrue(warnings.isEmpty)
#endif
    }

    func testHTTPBatchDummyPreservesResultPositions() async throws {
        let config = try JSONDecoder().decode(
            PluginConfig.self,
            from: Data(#"{"name":"HTTP batch","packages":["Http"]}"#.utf8)
        )
        let script = """
        source.batchDummy = function() {
            const batch = http.batch();
            const supported = typeof batch.DUMMY === "function";
            const chained = batch.DUMMY().DUMMY();
            return { supported: supported, chained: chained === batch, positions: batch.execute() };
        };
        """
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        defer { Task { await runtime.stop() } }

        struct Result: Decodable {
            let supported: Bool
            let chained: Bool
            let positions: [String?]
        }
        let value: Result = try await runtime.call("batchDummy")
        XCTAssertTrue(value.supported)
        XCTAssertTrue(value.chained)
        XCTAssertEqual(value.positions.count, 2)
        XCTAssertTrue(value.positions.allSatisfy { $0 == nil })
    }

    func testDirectEvalRemainsUnavailableWithoutPermissionOrBrowserFallback() async throws {
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(#"{"name":"No eval"}"#.utf8))
        let runtime = PluginRuntime(
            config: config,
            script: "source.dynamic = function() { return eval('42'); };",
            settings: [:], auth: nil, captcha: nil
        )
        defer { Task { await runtime.stop() } }
        do {
            let _: Int = try await runtime.call("dynamic")
            XCTFail("eval should require permission or a Browser-package fallback")
        } catch {
            XCTAssertTrue(String(describing: error).contains("eval is not allowed"))
        }
    }

    func testRequestExecutorAcceptsJavaScriptBufferTypes() async throws {
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(#"{"name":"Byte executor"}"#.utf8))
        let script = """
        class Generated extends DashManifestRawSource {
          generate() { return "<MPD/>"; }
          getRequestExecutor() {
            return {
              typed: function() { return new Uint8Array([0, 1, 127, 255]); },
              buffer: function() { return new Uint8Array([2, 3, 128, 254]).buffer; },
              view: function() { return new DataView(new Uint8Array([9, 8, 7, 6]).buffer, 1, 2); },
              promised: function() { return Promise.resolve(new Uint8Array([4, 5, 6])); }
            };
          }
        }
        source.getContentDetails = function(url) {
          return new PlatformVideoDetails({ name: "Bytes", url: url,
            video: new VideoSourceDescriptor([new Generated({ container: "video/mp4" })]) });
        };
        """
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        defer { Task { await runtime.stop() } }
        let data = try await runtime.callRaw("getContentDetails", ["https://example.test/video"], kind: "details")
        guard case .video(let details) = try PluginRuntime.decode(ContentDetails.self, from: data),
              let sourceHandle = details.videoSources.first?.handle,
              let executor = try await runtime.handleFromCall(sourceHandle, "getRequestExecutor") else {
            return XCTFail("Expected generated source and request executor handles")
        }
        let typed = try await runtime.callHandleBytes(executor.handle, "typed")
        let buffer = try await runtime.callHandleBytes(executor.handle, "buffer")
        let view = try await runtime.callHandleBytes(executor.handle, "view")
        let promised = try await runtime.callHandleBytes(executor.handle, "promised")
        XCTAssertEqual(typed, Data([0, 1, 127, 255]))
        XCTAssertEqual(buffer, Data([2, 3, 128, 254]))
        XCTAssertEqual(view, Data([8, 7]))
        XCTAssertEqual(promised, Data([4, 5, 6]))
    }

    func testCurrentRawDashPrimitivesCanBeSubclassed() async throws {
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(#"{"name":"Raw DASH"}"#.utf8))
        let script = """
        class GeneratedVideo extends DashManifestRawSource { generate() { return "<MPD/>"; } }
        class GeneratedAudio extends DashManifestRawAudioSource { generate() { return "<MPD/>"; } }
        source.search = function() { return new VideoPager([], false); };
        source.getChannel = function() { return new PlatformChannel({ name: "Channel", url: "u" }); };
        source.getChannelContents = function() { return new VideoPager([], false); };
        source.getContentDetails = function() { return null; };
        source.rawTypes = function() { return [new GeneratedVideo({}).plugin_type, new GeneratedAudio({}).plugin_type]; };
        """
        let runtime = PluginRuntime(config: config, script: script, settings: [:], auth: nil, captcha: nil)
        defer { Task { await runtime.stop() } }
        try await runtime.validate()
        let types: [String] = try await runtime.call("rawTypes")
        XCTAssertEqual(types, ["DashManifestRawSource", "DashManifestRawAudioSource"])
    }

    private let script = """
    class P extends VideoPager {
      constructor(n) { super([new PlatformVideo({ id: new PlatformID('Demo', 'v' + n, plugin.config.id), name: 'Video ' + n + ' ' + plugin.settings.greeting,
        url: 'https://demo.test/v/' + n, duration: 60, viewCount: 5, isLive: false, datetime: 1700000000,
        author: new PlatformAuthorLink(new PlatformID('Demo','c',plugin.config.id), 'Chan', 'https://demo.test/c', null) })], n < 2, {}); this.n = n; }
      nextPage() { return new P(this.n + 1); }
    }
    let enabledWith = null;
    source.enable = function(config, settings, savedState) { enabledWith = { name: config.name, flag: settings.flag, state: savedState }; };
    source.saveState = function() { return JSON.stringify({ ok: 1 }); };
    source.getHome = function() { return new P(0); };
    source.search = function(q) { return new P(0); };
    source.isChannelUrl = function(u) { return u.indexOf('/c') >= 0; };
    source.getChannel = function(u) { return new PlatformChannel({ id: new PlatformID('Demo','c',plugin.config.id), name: 'Chan', url: u, subscribers: 3 }); };
    source.getChannelContents = function(u, type, order, filters) { return new P(0); };
    source.isContentDetailsUrl = function(u) { return u.indexOf('/v/') >= 0; };
    source.getContentDetails = function(u) {
      if (u.indexOf('/v/boom') >= 0) throw new UnavailableException('gone');
      return new PlatformVideoDetails({ id: new PlatformID('Demo','v','x'), name: 'D', url: u, description: 'desc', viewCount: 1, isLive: false,
        video: new VideoSourceDescriptor([ new VideoUrlSource({ url: 'https://demo.test/v.mp4', height: 480, container: 'video/mp4' }) ]) });
    };
    source.getEnabledWith = function() { return enabledWith; };
    source.asyncValue = function() { return Promise.resolve(42); };
    source.asyncTimerValue = function() { return new Promise(function(resolve) { setTimeout(function() { resolve(43); }, 5); }); };
    source.hashes = function() { return [utility.md5String('a'), utility.sha256String('a'), utility.toBase64('hi')]; };
    source.dom = function() { var d = domParser.parseFromString('<div><p class="x">hi</p><a href="/l">go</a></div>', 'text/html'); return [d.querySelector('p').textContent, d.querySelector('a').getAttribute('href'), String(d.querySelectorAll('p').length)]; };
    """

    private func runtime(settings: [String: String] = [:]) throws -> PluginRuntime {
        let json = #"{"name":"Demo","id":"demo-id","scriptUrl":"x.js","version":1,"packages":["Http","DOMParser","Utilities"],"allowUrls":["demo.test"],"settings":[{"variable":"flag","name":"Flag","type":"Boolean","default":"true"},{"variable":"greeting","name":"G","type":"Input","default":"\"hello\""}]}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        return PluginRuntime(config: config, script: script, settings: settings, auth: nil, captcha: nil)
    }

    #if os(Linux)
    func testLinuxDefaultsToJavaScriptCoreGTK() {
        XCTAssertTrue(JSEngines.default is JavaScriptCoreGTKEngine)
    }
    #endif

    func testJavaScriptCoreAllowsDeepPluginCallGraphs() throws {
        let context = try JSEngines.default.makeContext { _, _, _ in "" }
        defer { context.close() }
        let value = try context.evaluate(
            "function descend(n) { return n === 0 ? 42 : descend(n - 1); } descend(1000)",
            name: "deep-stack"
        )
        XCTAssertEqual(value, "42")
    }

    func testValidateAndCapabilities() async throws {
        let rt = try runtime()
        try await rt.validate()
        let caps = try await rt.enable()
        XCTAssertEqual(caps["saveState"], true)
        XCTAssertEqual(caps["getComments"], false)
    }

    func testEnableReceivesConfigSettingsAndDefaults() async throws {
        let rt = try runtime()
        try await rt.enable()
        struct E: Decodable { var name: String; var flag: Bool }
        let e = try await rt.call("getEnabledWith", as: E.self)
        XCTAssertEqual(e.name, "Demo")
        XCTAssertTrue(e.flag, "declared default \"true\" is parsed to a boolean")
    }

    func testPromiseReturningPluginMethod() async throws {
        let rt = try runtime()
        let value = try await rt.call("asyncValue", as: Int.self)
        XCTAssertEqual(value, 42)
        let timerValue = try await rt.call("asyncTimerValue", as: Int.self)
        XCTAssertEqual(timerValue, 43)
    }

    func testStoredSettingOverridesDefault() async throws {
        let rt = try runtime(settings: ["flag": "false", "greeting": "\"yo\""])
        let pager = try await rt.pager("getHome", as: ContentItem.self)
        XCTAssertEqual(pager.initial.first?.name, "Video 0 yo")
    }

    func testPagerPagingAndTermination() async throws {
        let rt = try runtime()
        let pager = try await rt.pager("getHome", as: ContentItem.self)
        XCTAssertEqual(pager.initial.count, 1)
        XCTAssertTrue(pager.hasMore)
        let p1 = try await pager.next()
        XCTAssertEqual(p1.first?.url, "https://demo.test/v/1")
        let p2 = try await pager.next()
        XCTAssertEqual(p2.first?.url, "https://demo.test/v/2")
        XCTAssertFalse(pager.hasMore)
        let none = try await pager.next()
        XCTAssertTrue(none.isEmpty)
    }

    func testRoutingChannelAndDetails() async throws {
        let rt = try runtime()
        let isChannel = try await rt.call("isChannelUrl", ["https://demo.test/c"], as: Bool.self)
        XCTAssertTrue(isChannel)
        let channel = try await rt.call("getChannel", ["https://demo.test/c"], as: ChannelInfo.self)
        XCTAssertEqual(channel.name, "Chan")
        XCTAssertEqual(channel.subscribers, 3)
        let data = try await rt.callRaw("getContentDetails", ["https://demo.test/v/1"], kind: "details")
        guard case .video(let d) = try PluginRuntime.decode(ContentDetails.self, from: data) else { return XCTFail("expected video") }
        XCTAssertEqual(d.videoSources.first?.height, 480)
    }

    func testPluginExceptionsSurfaceAsTypedErrors() async throws {
        let rt = try runtime()
        do {
            _ = try await rt.callRaw("getContentDetails", ["https://demo.test/v/boom"], kind: "details")
            XCTFail("expected an error")
        } catch PluginError.unavailable(let message) {
            XCTAssertEqual(message, "gone")
        }
    }

    func testSaveStateAndHostPackages() async throws {
        let rt = try runtime()
        try await rt.enable()
        let state = await rt.saveState()
        XCTAssertEqual(state, #"{"ok":1}"#)
        let hashes = try await rt.call("hashes", as: [String].self)
        XCTAssertEqual(hashes[0], "0cc175b9c0f1b6a831c399e269772661")
        XCTAssertEqual(hashes[1], "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
        XCTAssertEqual(hashes[2], "aGk=")
        let dom = try await rt.call("dom", as: [String].self)
        XCTAssertEqual(dom, ["hi", "/l", "1"])
    }
}
