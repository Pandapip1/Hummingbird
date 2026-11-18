import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import XCTest
@testable import HummingbirdKit

final class HostHTTPRateLimitTests: XCTestCase {
    private final class Locked<Value: Sendable>: Sendable {
        private let storage: Mutex<Value>

        init(_ value: Value) { storage = Mutex(value) }
        func read() -> Value { storage.withLock { $0 } }
        func withValue<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
            storage.withLock { body(&$0) }
        }
    }

    private final class Clock: Sendable {
        private struct State { var now: Date; var sleeps: [TimeInterval] = [] }
        private let state: Mutex<State>

        init(_ value: Date) { state = Mutex(State(now: value)) }

        var sleeps: [TimeInterval] { state.withLock { $0.sleeps } }

        func now() -> Date { state.withLock { $0.now } }

        func sleep(_ interval: TimeInterval) {
            state.withLock {
                $0.sleeps.append(interval)
                $0.now.addTimeInterval(interval)
            }
        }
    }

    /// Answers requests synchronously from queued responses or a handler. It has
    /// no state of its own (URLProtocol is not Sendable); the shared state lives
    /// in a Mutex.
    private final class StubProtocol: URLProtocol {
        typealias Response = (Int, [String: String], String)
        typealias Handler = @Sendable (URLRequest) -> Response
        private struct State {
            var responses: [Response] = []
            var handler: Handler?
            var requestCount = 0
        }

        private static let state = Mutex(State())
        static var requestCount: Int { state.withLock { $0.requestCount } }

        static func reset(_ newResponses: [Response]) {
            state.withLock { $0 = State(responses: newResponses) }
        }

        static func reset(handler newHandler: @escaping Handler) {
            state.withLock { $0 = State(handler: newHandler) }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let (handler, queued): (Handler?, Response?) = Self.state.withLock {
                $0.requestCount += 1
                return ($0.handler, $0.handler == nil && !$0.responses.isEmpty ? $0.responses.removeFirst() : nil)
            }
            guard let response = handler?(request) ?? queued,
                  let url = request.url,
                  let http = HTTPURLResponse(url: url, statusCode: response.0, httpVersion: "HTTP/1.1",
                                             headerFields: response.1) else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.2.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeHost(clock: Clock) throws -> HostHTTP {
        let data = Data(#"{"name":"Test","id":"test","scriptUrl":"test.js","version":1,"allowUrls":["example.test"]}"#.utf8)
        let config = try JSONDecoder().decode(PluginConfig.self, from: data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HostHTTP(
            config: config,
            auth: nil,
            captcha: nil,
            policy: PluginNetworkPolicy(config: config, approvals: [], resolver: TestResolver.publicOnly),
            session: URLSession(configuration: configuration),
            now: clock.now,
            sleep: clock.sleep
        )
    }

    private func request(method: String = "GET") -> String {
        #"[{"method":"\#(method)","url":"https://example.test/resource"}]"#
    }

    func testStringBodyDefaultsToTextPlain() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let contentType = Locked<String?>(nil)
        StubProtocol.reset(handler: { request in
            contentType.withValue { $0 = request.value(forHTTPHeaderField: "Content-Type") }
            return (200, [:], "ok")
        })
        let bodyRequest = #"[{"method":"POST","url":"https://example.test/resource","body":{"text":"{}"}}]"#

        _ = try makeHost(clock: clock).execute(json: bodyRequest, parallel: false)

        XCTAssertEqual(contentType.read(), "text/plain")
    }

    func testExpiredSetCookieRemovesStoredCookie() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let observedCookies = Locked<[String?]>([])
        StubProtocol.reset(handler: { request in
            let count = observedCookies.withValue {
                $0.append(request.value(forHTTPHeaderField: "Cookie"))
                return $0.count
            }
            switch count {
            case 1:
                return (200, ["Set-Cookie": "session=present; Domain=.example.test; Path=/"], "ok")
            case 2:
                return (200, ["Set-Cookie": "session=; Max-Age=0; Domain=.example.test; Path=/"], "ok")
            default:
                return (200, [:], "ok")
            }
        })
        let host = try makeHost(clock: clock)

        _ = host.execute(json: request(), parallel: false)
        _ = host.execute(json: request(), parallel: false)
        _ = host.execute(json: request(), parallel: false)

        let cookies = observedCookies.read()
        XCTAssertNil(cookies[0])
        XCTAssertEqual(cookies[1], "session=present")
        XCTAssertNil(cookies[2])
    }

    func testRetryAfterSecondsDelaysAndRetriesSafeRequestOnce() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        StubProtocol.reset([
            (429, ["Retry-After": "2"], "slow down"),
            (200, [:], "ok"),
        ])
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(makeHost(clock: clock).execute(json: request(), parallel: false).utf8))
                as? [[String: Any]]
        )

        XCTAssertEqual(StubProtocol.requestCount, 2)
        XCTAssertEqual(clock.sleeps, [2])
        XCTAssertEqual(output.first?["code"] as? Int, 200)
        XCTAssertEqual(output.first?["body"] as? String, "ok")
    }

    func testUnsafeRequestIsNotAutomaticallyRepeated() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        StubProtocol.reset([(429, ["Retry-After": "2"], "slow down")])
        let output = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(makeHost(clock: clock).execute(json: request(method: "POST"), parallel: false).utf8))
                as? [[String: Any]]
        )

        XCTAssertEqual(StubProtocol.requestCount, 1)
        XCTAssertTrue(clock.sleeps.isEmpty)
        XCTAssertEqual(output.first?["code"] as? Int, 429)
        let headers = output.first?["headers"] as? [String: [String]]
        XCTAssertEqual(headers?["retry-after"], ["2"])
    }

    func testLongCooldownSuppressesFollowupNetworkRequests() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        StubProtocol.reset([(429, ["Retry-After": "120"], "slow down")])
        let host = try makeHost(clock: clock)
        _ = host.execute(json: request(), parallel: false)
        let second = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(host.execute(json: request(), parallel: false).utf8))
                as? [[String: Any]]
        )

        XCTAssertEqual(StubProtocol.requestCount, 1)
        XCTAssertTrue(clock.sleeps.isEmpty)
        XCTAssertEqual(second.first?["code"] as? Int, 429)
        let headers = second.first?["headers"] as? [String: [String]]
        XCTAssertEqual(headers?["retry-after"], ["120"])
    }

    func testSyntheticCooldownPreservesByteResponseShape() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        StubProtocol.reset([(429, ["Retry-After": "120"], "slow down")])
        let host = try makeHost(clock: clock)
        let byteRequest = #"[{"method":"GET","url":"https://example.test/resource","bytes":true}]"#
        _ = host.execute(json: byteRequest, parallel: false)
        let second = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(host.execute(json: byteRequest, parallel: false).utf8))
                as? [[String: Any]]
        )

        XCTAssertNil(second.first?["body"])
        let encoded = try XCTUnwrap(second.first?["bodyBase64"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), Data("Too Many Requests".utf8))
    }

    func testOlderConcurrentSuccessDoesNotClearNewerCooldown() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let hostRef = Locked<HostHTTP?>(nil)
        // While the slow request is in flight, a concurrent request to the same host
        // is rate limited (recorded directly: a second stubbed request could not be
        // answered while this one holds the URL loading thread).
        StubProtocol.reset(handler: { _ in
            _ = hostRef.read()?.recordRateLimit(for: "example.test", headers: ["retry-after": ["120"]])
            return (200, [:], "ok")
        })
        let host = try makeHost(clock: clock)
        hostRef.withValue { $0 = host }

        _ = host.execute(json: #"[{"method":"GET","url":"https://example.test/slow"}]"#, parallel: false)

        let third = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(host.execute(json: request(), parallel: false).utf8))
                as? [[String: Any]]
        )
        XCTAssertEqual(StubProtocol.requestCount, 1, "the older success must not clear the newer cooldown")
        XCTAssertEqual(third.first?["code"] as? Int, 429)
    }

    func testRetryAfterHTTPDateIsParsed() {
        let now = Date(timeIntervalSince1970: 784_111_757)
        XCTAssertEqual(
            HostHTTP.retryDelay(from: "Sun, 06 Nov 1994 08:49:47 GMT", now: now),
            30
        )
    }

    func testMalformedAndHugeRetryAfterValuesAreRejected() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(HostHTTP.retryDelay(from: "1.5", now: now))
        XCTAssertNil(HostHTTP.retryDelay(from: "nan", now: now))
        XCTAssertNil(HostHTTP.retryDelay(from: "1e9", now: now))
        XCTAssertNil(HostHTTP.retryDelay(from: String(repeating: "9", count: 400), now: now))
    }

    private func runOffMain(_ host: HostHTTP, url: String) -> String {
        let output = Locked("")
        let finished = expectation(description: "request finished")
        DispatchQueue.global().async {
            let result = host.execute(json: #"[{"method":"GET","url":"\#(url)"}]"#, parallel: false)
            output.withValue { $0 = result }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        return output.read()
    }

    private func makeLANHost(allowed: Bool, asked: Locked<[URL]>) throws -> HostHTTP {
        let data = Data(#"{"name":"Test","id":"test","scriptUrl":"test.js","version":1,"allowUrls":["192.168.1.20","example.test"]}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HostHTTP(
            config: try JSONDecoder().decode(PluginConfig.self, from: data), auth: nil, captcha: nil,
            policy: PluginNetworkPolicy(
                config: try JSONDecoder().decode(PluginConfig.self, from: data),
                approvals: [LocalHostApproval(host: "192.168.1.20", port: 80, networks: [IPNetwork(cidr: "192.168.1.20")!])],
                resolver: TestResolver.publicOnly
            ),
            session: URLSession(configuration: configuration),
            localNetworkAccess: { url in
                asked.withValue { $0.append(url) }
                return allowed
            }
        )
    }

    func testDeclinedLocalNetworkRequestNeverReachesTheNetwork() throws {
        StubProtocol.reset([(200, [:], "ok")])
        let asked = Locked<[URL]>([])
        let output = runOffMain(try makeLANHost(allowed: false, asked: asked), url: "http://192.168.1.20/items")
        XCTAssertEqual(asked.read().map(\.host), ["192.168.1.20"])
        XCTAssertEqual(StubProtocol.requestCount, 0)
        XCTAssertTrue(output.contains("is on your local network"), output)
    }

    func testAllowedLocalNetworkRequestProceedsAndPublicHostsAreNotAsked() throws {
        StubProtocol.reset([(200, [:], "ok"), (200, [:], "ok")])
        let asked = Locked<[URL]>([])
        let host = try makeLANHost(allowed: true, asked: asked)
        XCTAssertTrue(runOffMain(host, url: "http://192.168.1.20/items").contains("\"code\":200"))
        XCTAssertTrue(runOffMain(host, url: "https://example.test/resource").contains("\"code\":200"))
        XCTAssertEqual(asked.read().count, 1)
        XCTAssertEqual(StubProtocol.requestCount, 2)
    }
}
