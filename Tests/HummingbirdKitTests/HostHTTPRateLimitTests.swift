import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HummingbirdKit

final class HostHTTPRateLimitTests: XCTestCase {
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }
        func read() -> Value { lock.withLock { value } }
        func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.withLock { body(&value) }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        private(set) var sleeps: [TimeInterval] = []

        init(_ value: Date) { self.value = value }

        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func sleep(_ interval: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            sleeps.append(interval)
            value.addTimeInterval(interval)
        }
    }

    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        private final class State: @unchecked Sendable {
            let lock = NSLock()
            var responses: [(Int, [String: String], String)] = []
            var handler: (@Sendable (URLRequest) -> (Int, [String: String], String))?
            var beforeDelivery: (@Sendable (URLRequest) -> Void)?
            var requestCount = 0
        }

        private static let state = State()
        static var requestCount: Int { state.lock.withLock { state.requestCount } }

        static func reset(_ newResponses: [(Int, [String: String], String)]) {
            state.lock.withLock {
                state.responses = newResponses
                state.handler = nil
                state.beforeDelivery = nil
                state.requestCount = 0
            }
        }

        static func reset(
            handler newHandler: @escaping @Sendable (URLRequest) -> (Int, [String: String], String),
            beforeDelivery newBeforeDelivery: (@Sendable (URLRequest) -> Void)? = nil
        ) {
            state.lock.withLock {
                state.responses = []
                state.handler = newHandler
                state.beforeDelivery = newBeforeDelivery
                state.requestCount = 0
            }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let (handler, beforeDelivery, queued) = Self.state.lock.withLock {
                Self.state.requestCount += 1
                let handler = Self.state.handler
                return (handler, Self.state.beforeDelivery, handler == nil ? Self.state.responses.removeFirst() : nil)
            }
            let response = handler?(request) ?? queued!
            let deliver: @Sendable () -> Void = { [self, response] in
                let http = HTTPURLResponse(
                    url: self.request.url!, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: response.1
                )!
                self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: Data(response.2.utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
            if let beforeDelivery {
                DispatchQueue.global().async {
                    beforeDelivery(self.request)
                    deliver()
                }
            } else {
                deliver()
            }
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
        let slowStarted = DispatchSemaphore(value: 0)
        let releaseSlow = DispatchSemaphore(value: 0)
        StubProtocol.reset(handler: { request in
            if request.url?.path == "/slow" { return (200, [:], "ok") }
            return (429, ["Retry-After": "120"], "slow down")
        }, beforeDelivery: { request in
            if request.url?.path == "/slow" {
                slowStarted.signal()
                releaseSlow.wait()
            }
        })
        let host = try makeHost(clock: clock)
        let slowFinished = expectation(description: "slow request finished")
        DispatchQueue.global().async {
            _ = host.execute(json: #"[{"method":"GET","url":"https://example.test/slow"}]"#, parallel: false)
            slowFinished.fulfill()
        }
        XCTAssertEqual(slowStarted.wait(timeout: .now() + 2), .success)
        _ = host.execute(json: #"[{"method":"POST","url":"https://example.test/limited"}]"#, parallel: false)
        releaseSlow.signal()
        wait(for: [slowFinished], timeout: 2)

        let third = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(host.execute(json: request(), parallel: false).utf8))
                as? [[String: Any]]
        )
        XCTAssertEqual(StubProtocol.requestCount, 2, "active cooldown should suppress a third network request")
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
}
