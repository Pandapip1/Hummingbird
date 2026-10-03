import XCTest
@testable import JaybirdKit

/// Runs a small plugin inside a real JavaScriptCore host context (no network involved).
final class RuntimeTests: XCTestCase {
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
    source.hashes = function() { return [utility.md5String('a'), utility.sha256String('a'), utility.toBase64('hi')]; };
    source.dom = function() { var d = domParser.parseFromString('<div><p class="x">hi</p><a href="/l">go</a></div>', 'text/html'); return [d.querySelector('p').textContent, d.querySelector('a').getAttribute('href'), String(d.querySelectorAll('p').length)]; };
    """

    private func runtime(settings: [String: String] = [:]) throws -> PluginRuntime {
        let json = #"{"name":"Demo","id":"demo-id","scriptUrl":"x.js","version":1,"packages":["Http","DOMParser","Utilities"],"allowUrls":["demo.test"],"settings":[{"variable":"flag","name":"Flag","type":"Boolean","default":"true"},{"variable":"greeting","name":"G","type":"Input","default":"\"hello\""}]}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(json.utf8))
        return PluginRuntime(config: config, script: script, settings: settings, auth: nil, captcha: nil)
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
