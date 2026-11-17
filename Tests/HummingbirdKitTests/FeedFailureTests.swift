import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import XCTest
@testable import HummingbirdKit

/// Answers plugin HTTP from a handler, so no request leaves the process.
private final class StubHTTP: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    static let handler = Mutex<Handler?>(nil)
    static let requests = Mutex<[String]>([])

    static func session(_ respond: @escaping Handler) -> URLSession {
        handler.withLock { $0 = respond }
        requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request.url?.path ?? "") }
        let (status, body) = Self.handler.withLock { $0 }?(request) ?? (599, "no stub")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A source that fails must show up in the feed, above the other sources'
/// results, and be retryable; it must never just be missing.
final class FeedFailureTests: XCTestCase {
    // MARK: fixtures

    private func config(_ id: String, name: String, allow: [String] = [], packages: [String] = []) throws -> PluginConfig {
        let json: [String: Any] = ["name": name, "id": id, "scriptUrl": "\(id).js", "version": 1,
                                   "allowUrls": allow, "packages": packages]
        return try JSONDecoder().decode(PluginConfig.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The parts of the Twitch plugin (v38) that decide the outcome: integrity on
    /// enable, `callGQL` throwing on any `errors` entry, and search mapping live
    /// channels to videos.
    private let twitchShapedScript = #"""
    const GQL_URL = 'https://gql.twitch.tv/gql#origin=twilight';
    let state = { integrity: '' };
    source.enable = function () {
        const resp = http.POST('https://gql.twitch.tv/integrity', '', { 'Client-Id': 'fixture' });
        if (!resp.isOk) throw new ScriptException('Integrity fetch returned ' + resp.code);
        state.integrity = JSON.parse(resp.body).token;
    };
    function callGQL(gql) {
        const resp = http.POST(GQL_URL, JSON.stringify(gql), { 'Client-Integrity': state.integrity });
        if (!resp.isOk) throw new ScriptException('GQL returned ' + resp.code);
        const json = JSON.parse(resp.body);
        if (json.errors) throw new ScriptException('GQL returned errors: ' + JSON.stringify(json.errors));
        return json;
    }
    source.search = function (query, type, order, filters) {
        const json = callGQL({ operationName: 'SearchResultsPage_SearchResults', variables: { query: query } });
        const results = [];
        for (const edge of json.data.searchFor.channels.edges) {
            if (edge.item.stream !== null) {
                results.push(new PlatformVideo({
                    id: new PlatformID('Twitch', edge.item.stream.id, 'twitch-fixture'),
                    name: edge.item.broadcastSettings.title,
                    url: 'https://www.twitch.tv/' + edge.item.login,
                    uploadDate: 1700000000,
                    isLive: true
                }));
            }
        }
        return new VideoPager(results, false, {});
    };
    """#

    private let otherSourceScript = #"""
    source.enable = function () {};
    source.search = function (query) {
        return new VideoPager([1, 2, 3].map(function (n) {
            return new PlatformVideo({ id: new PlatformID('Other', 'v' + n, 'other-fixture'),
                                       name: query + ' ' + n, url: 'https://other.test/' + n, uploadDate: 1700000000 + n });
        }), false, {});
    };
    """#

    /// Two content types that page independently, newest first. Item URLs do
    /// not include the type, so the item at 50 appears in both and must show once.
    private let channelScript = #"""
    const PAGES = { VIDEOS: [[100, 80, 60], [50, 20]], STREAMS: [[90], [50, 10]] };
    const calls = [];
    source.enable = function () {};
    class TypePager extends VideoPager {
        constructor(type, order, page) {
            const pages = PAGES[type] || [[]];
            super(pages[page].map(function (t) {
                return new PlatformVideo({ id: new PlatformID('Fake', type + t, 'fake-fixture'),
                                           name: type + '/' + order + '/' + t,
                                           url: 'https://fake.test/' + t, uploadDate: t });
            }), page + 1 < pages.length, {});
            this.type = type; this.order = order; this.page = page;
        }
        nextPage() { return new TypePager(this.type, this.order, this.page + 1); }
    }
    source.getChannelContents = function (url, type, order, filters) {
        calls.push(String(type) + ':' + String(order));
        if (type === 'FAIL') throw new ScriptException('channel tab failed');
        return new TypePager(type, order, 0);
    };
    source.getCalls = function () { return calls; };
    """#

    private let partialErrorBody = #"""
    {"errors":[{"message":"service error","path":["searchFor","channels","edges",10,"item","topClip"]}],
     "data":{"searchFor":{"channels":{"edges":[{"item":{"login":"streamer","broadcastSettings":{"title":"Live now"},
       "stream":{"id":"s1"},"topClip":null}}]},"channelsWithTag":{"edges":[]},"videos":{"edges":[]},
       "relatedLiveChannels":{"edges":[]}}}}
    """#

    private let cleanBody = #"""
    {"data":{"searchFor":{"channels":{"edges":[{"item":{"login":"streamer","broadcastSettings":{"title":"Live now"},
      "stream":{"id":"s1"},"topClip":null}}]},"channelsWithTag":{"edges":[]},"videos":{"edges":[]},
      "relatedLiveChannels":{"edges":[]}}}}
    """#

    private func searchSource(_ rt: PluginRuntime, label: String) -> FeedSource {
        FeedSource(runtime: rt, label: label) {
            try await rt.pager("search", ["query", NSNull(), NSNull(), NSNull()], as: ContentItem.self)
        }
    }

    private func channelSource(_ rt: PluginRuntime, type: String, order: String? = nil,
                               delay: Duration? = nil) -> FeedSource {
        FeedSource(runtime: rt, label: "Fake (\(type))", key: "fake|\(type)") {
            if let delay { try await Task.sleep(for: delay) }
            return try await rt.pager("getChannelContents",
                                      ["https://fake.test/channel", type, order ?? NSNull(), NSNull()],
                                      as: ContentItem.self)
        }
    }

    @MainActor
    private func makeFeed() -> FeedModel {
        FeedModel { error, _ in error.localizedDescription }
    }

    private func channelRuntime() throws -> PluginRuntime {
        PluginRuntime(config: try config("fake-fixture", name: "Fake"), script: channelScript,
                      settings: [:], auth: nil, captcha: nil)
    }

    // MARK: the Twitch regression

    @MainActor
    func testPartialGraphQLErrorShowsAsFailureAboveOtherSourcesResults() async throws {
        let body = Locked(partialErrorBody)
        let session = StubHTTP.session { request in
            if request.url?.path == "/integrity" { return (200, #"{"token":"fixture-token"}"#) }
            return (200, body.value)
        }
        let twitch = PluginRuntime(
            config: try config("twitch-fixture", name: "Twitch", allow: ["gql.twitch.tv"], packages: ["Http"]),
            script: twitchShapedScript, settings: [:], auth: nil, captcha: nil, httpSession: session
        )
        let other = PluginRuntime(config: try config("other-fixture", name: "Other"), script: otherSourceScript,
                                  settings: [:], auth: nil, captcha: nil)
        let feed = makeFeed()

        let outcome = await feed.reload(sources: [searchSource(other, label: "Other"), searchSource(twitch, label: "Twitch")])

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(feed.content.items.map(\.url), ["https://other.test/1", "https://other.test/2", "https://other.test/3"])
        let failure = try XCTUnwrap(feed.content.failures.first, "Twitch's failure must be part of the feed")
        XCTAssertEqual(feed.content.failures.count, 1)
        XCTAssertEqual(failure.pluginID, "twitch-fixture")
        XCTAssertEqual(failure.label, "Twitch")
        XCTAssertEqual(failure.stage, .firstPage)
        XCTAssertTrue(failure.message.contains("service error"), failure.message)
        XCTAssertEqual(StubHTTP.requests.withLock { $0 }, ["/integrity", "/gql"])

        // Twitch recovers: retrying just that source adds its results and clears the failure.
        body.value = cleanBody
        await feed.retry(failure)
        XCTAssertTrue(feed.content.failures.isEmpty)
        XCTAssertEqual(feed.content.items.last?.url, "https://www.twitch.tv/streamer")
        XCTAssertEqual(feed.content.items.last?.isLive, true)
        XCTAssertEqual(feed.content.items.count, 4)

        await twitch.stop()
        await other.stop()
    }

    @MainActor
    func testFailureFromBesideTheFeedIsShownAndRetried() async throws {
        let rt = try channelRuntime()
        let feed = makeFeed()
        await feed.reload(sources: [channelSource(rt, type: "VIDEOS")])
        let failure = SourceFailure.record(pluginID: "twitch-fixture", label: "Twitch", message: "service error", stage: .channels)
        let attempts = Locked(0)
        feed.record(failure) {
            attempts.value += 1
            let n = attempts.value
            return n == 1 ? SourceFailure.record(pluginID: "twitch-fixture", label: "Twitch", message: "still failing", stage: .channels) : nil
        }
        XCTAssertEqual(feed.content.failures, [failure])

        await feed.retry(failure)
        XCTAssertEqual(feed.content.failures.map(\.message), ["still failing"])
        await feed.retry(feed.content.failures[0])
        XCTAssertTrue(feed.content.failures.isEmpty)
        await rt.stop()
    }

    // MARK: channel feeds

    @MainActor
    func testChannelTypesMergeNewestFirstWithIndependentPagingAndDedup() async throws {
        let rt = try channelRuntime()
        let feed = makeFeed()
        let outcome = await feed.reload(sources: [channelSource(rt, type: "VIDEOS"), channelSource(rt, type: "STREAMS")],
                                        order: .newestFirst)
        XCTAssertEqual(outcome, .refreshed)
        // Streams' first page ends at 90; nothing older can be placed before its next page.
        XCTAssertEqual(feed.content.items.compactMap(\.datetime), [100, 90])
        while feed.hasMore { await feed.loadMore() }
        XCTAssertEqual(feed.content.items.compactMap(\.datetime), [100, 90, 80, 60, 50, 20, 10])
        XCTAssertTrue(feed.content.failures.isEmpty)
        await rt.stop()
    }

    @MainActor
    func testSortReachesEveryMergedSource() async throws {
        let rt = try channelRuntime()
        let feed = makeFeed()
        await feed.reload(sources: [channelSource(rt, type: "VIDEOS", order: "Popular"),
                                    channelSource(rt, type: "STREAMS", order: "Popular")],
                          order: ChannelFeedPlan.feedOrder(sourceCount: 2, sort: "Popular"))
        let calls = try await rt.call("getCalls", [], as: [String].self)
        XCTAssertEqual(Set(calls), ["VIDEOS:Popular", "STREAMS:Popular"])
        XCTAssertTrue(feed.content.items.allSatisfy { $0.name.contains("/Popular/") })
        await rt.stop()
    }

    @MainActor
    func testFailedReloadKeepsWhatWasShownAndReportsIt() async throws {
        let rt = try channelRuntime()
        let feed = makeFeed()
        await feed.reload(sources: [channelSource(rt, type: "VIDEOS")])
        let shown = feed.content.items

        let outcome = await feed.reload(sources: [channelSource(rt, type: "FAIL", order: "Popular")])

        XCTAssertEqual(outcome, .failed, "a control must not show the new sort as applied")
        XCTAssertEqual(feed.content.items, shown)
        let failure = try XCTUnwrap(feed.content.failures.first)
        XCTAssertEqual(failure.sourceKey, "fake|FAIL")
        XCTAssertTrue(failure.message.contains("channel tab failed"))

        await feed.retry(failure)
        XCTAssertEqual(feed.content.failures.map(\.sourceKey), ["fake|FAIL"], "the retry failed again and says so")
        await rt.stop()
    }

    @MainActor
    func testStaleReloadCannotOverwriteANewerOne() async throws {
        let rt = try channelRuntime()
        let feed = makeFeed()
        let slowSource = channelSource(rt, type: "VIDEOS", delay: .milliseconds(300))
        let slow = Task { await feed.reload(sources: [slowSource]) }
        try await Task.sleep(for: .milliseconds(50))
        let newer = await feed.reload(sources: [channelSource(rt, type: "STREAMS")])
        let stale = await slow.value

        XCTAssertEqual(newer, .refreshed)
        XCTAssertEqual(stale, .superseded)
        XCTAssertTrue(feed.content.items.allSatisfy { $0.name.hasPrefix("STREAMS/") })
        await rt.stop()
    }

    func testChannelFeedPlanDefaultsToVideosAndStreams() {
        XCTAssertEqual(ChannelFeedPlan.types(advertised: ["VIDEOS", "STREAMS", "SHORTS"], selection: ChannelFeedPlan.all),
                       ["VIDEOS", "STREAMS"])
        XCTAssertEqual(ChannelFeedPlan.types(advertised: ["MIXED"], selection: ChannelFeedPlan.all), [nil])
        XCTAssertEqual(ChannelFeedPlan.types(advertised: ["VIDEOS", "LIVE"], selection: ChannelFeedPlan.all), ["VIDEOS", "LIVE"])
        XCTAssertEqual(ChannelFeedPlan.types(advertised: ["POSTS", "SHORTS"], selection: ChannelFeedPlan.all), ["POSTS"])
        XCTAssertEqual(ChannelFeedPlan.types(advertised: [], selection: ChannelFeedPlan.all), [nil])
        XCTAssertEqual(ChannelFeedPlan.types(advertised: ["VIDEOS", "STREAMS", "SHORTS"], selection: "SHORTS"), ["SHORTS"])
        XCTAssertEqual(ChannelFeedPlan.pickerTypes(advertised: ["MIXED", "VIDEOS", "STREAMS"]),
                       [ChannelFeedPlan.all, "VIDEOS", "STREAMS"])
        XCTAssertEqual(ChannelFeedPlan.feedOrder(sourceCount: 2, sort: nil), .newestFirst)
        XCTAssertEqual(ChannelFeedPlan.feedOrder(sourceCount: 2, sort: "CHRONOLOGICAL"), .newestFirst)
        XCTAssertEqual(ChannelFeedPlan.feedOrder(sourceCount: 2, sort: "Popular"), .interleaved)
        XCTAssertEqual(ChannelFeedPlan.feedOrder(sourceCount: 1, sort: nil), .interleaved)
    }

    // MARK: log redaction

    func testLogRedactionKeepsTheErrorButNotSecretsOrAddresses() {
        let twitch = #"GQL returned errors: [{"message":"service error","path":["searchFor","channels","edges",10,"item","topClip"]}]"#
        XCTAssertEqual(LogRedaction.redact(twitch), twitch)

        let redacted = LogRedaction.redact(
            #"GET https://gql.twitch.tv/gql?token=abc&sig=def from 192.168.1.20 and 2001:db8:0:0:1:0:0:1 / fe80::1 "#
            + #"Authorization: Bearer abc.def-ghi "Client-Integrity":"v4.public.eyJhbGciOiJ" "#
            + #"device 0123456789abcdef0123456789abcdef mail me@example.com at 12:30:45"#
        )
        for secret in ["token=abc", "sig=def", "192.168.1.20", "2001:db8", "fe80::1", "abc.def-ghi", "v4.public",
                       "0123456789abcdef0123456789abcdef", "me@example.com"] {
            XCTAssertFalse(redacted.contains(secret), "\(secret) leaked: \(redacted)")
        }
        XCTAssertTrue(redacted.contains("https://gql.twitch.tv/gql?<redacted>"), redacted)
        XCTAssertTrue(redacted.contains("12:30:45"), "clock times are not addresses: \(redacted)")
        XCTAssertLessThanOrEqual(LogRedaction.redact(String(repeating: "word ", count: 500)).count, 501)
    }
}

/// A value shared with escaping, concurrently called closures in these tests.
private final class Locked<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
