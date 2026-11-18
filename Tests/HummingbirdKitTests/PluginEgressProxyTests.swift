import XCTest
@testable import HummingbirdKit

/// The egress proxy resolves each connection once, checks that address and connects to exactly it.
/// Everything here stays on 127.0.0.1: names resolve through `TestResolver` / `SequenceResolver`,
/// never DNS, and the "origin" is a `LoopbackHTTPServer`.
final class PluginEgressProxyTests: XCTestCase {
    /// Answers with the next list each time it is asked (the last one repeats): a DNS answer that changes.
    final class SequenceResolver: HostResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [[String]]
        private(set) var lookups = 0
        init(_ answers: [[String]]) { self.answers = answers }
        func resolve(host: String, port: Int) throws -> [IPAddress] {
            let next: [String] = lock.withLock {
                lookups += 1
                return answers.count > 1 ? answers.removeFirst() : answers[0]
            }
            return next.compactMap(IPAddress.init(literal:))
        }
    }

    private func config(_ allow: [String]) throws -> PluginConfig {
        let json = try JSONSerialization.data(withJSONObject: ["name": "Proxy", "id": "proxy-test", "allowUrls": allow])
        return try JSONDecoder().decode(PluginConfig.self, from: json)
    }

    private func session(through proxy: PluginEgressProxy) -> URLSession {
        let configuration = HostHTTP.containedConfiguration()
        configuration.timeoutIntervalForRequest = 5
        proxy.apply(to: configuration)
        return URLSession(configuration: configuration)
    }

    private func requirePinning() throws {
        try XCTSkipUnless(PluginEgressProxy.pinsURLSessionConnections, "URL loading on this platform ignores proxies")
    }

    func testConnectionUsesTheProxysOwnResolution() async throws {
        try requirePinning()
        let server = try LoopbackHTTPServer(body: "hello")
        defer { server.stop() }
        let host = "jellyfin.invalid"
        let policy = PluginNetworkPolicy(
            config: try config(["\(host):\(server.port)"]),
            approvals: [loopbackApproval(port: server.port, host: host)],
            resolver: TestResolver(answers: [host: ["127.0.0.1"]])
        )
        let proxy = try PluginEgressProxy.start(policy: policy)
        defer { proxy.close() }
        // "jellyfin.invalid" does not exist in DNS: the request can only arrive through the proxy's resolution.
        let (data, response) = try await session(through: proxy).data(from: URL(string: "http://\(host):\(server.port)/x")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello")
        XCTAssertEqual(proxy.connectedDestinations.last?.address, IPAddress(literal: "127.0.0.1"))
        XCTAssertEqual(server.requests.count, 1)
    }

    func testDNSAnswerChangingAfterTheCheckCannotRedirectTheConnection() async throws {
        try requirePinning()
        let server = try LoopbackHTTPServer()
        defer { server.stop() }
        let host = "rebind.invalid"
        // First lookup: the approved loopback address. Every later lookup: another private address.
        let resolver = SequenceResolver([["127.0.0.1"], ["10.9.9.9"]])
        let policy = PluginNetworkPolicy(config: try config([host]),
                                         approvals: [loopbackApproval(port: server.port, host: host)], resolver: resolver)
        let proxy = try PluginEgressProxy.start(policy: policy)
        defer { proxy.close() }
        let session = session(through: proxy)
        let url = URL(string: "http://\(host):\(server.port)/")!

        _ = try await session.data(from: url)
        XCTAssertEqual(resolver.lookups, 1, "one resolution per connection")
        XCTAssertEqual(proxy.connectedDestinations.map(\.address), [IPAddress(literal: "127.0.0.1")!],
                       "the connection went to the address that was checked")

        // The next connection resolves anew, to an address nobody approved: refused, and nothing is sent.
        do {
            _ = try await session.data(from: url)
            XCTFail("a rebound name must not connect")
        } catch {}
        XCTAssertEqual(proxy.denial(host: host, port: server.port),
                       .localAddressChanged(host: host, port: server.port, address: "10.9.9.9"))
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(proxy.connectedDestinations.count, 1)
    }

    func testUnapprovedLoopbackAndMetadataAreRefusedEvenForEverywhere() async throws {
        try requirePinning()
        let server = try LoopbackHTTPServer()
        defer { server.stop() }
        let policy = PluginNetworkPolicy(config: try config(["everywhere"]), approvals: [],
                                         resolver: TestResolver(answers: ["public-looking.invalid": ["127.0.0.1"],
                                                                         "meta.invalid": ["169.254.169.254"]]))
        let proxy = try PluginEgressProxy.start(policy: policy)
        defer { proxy.close() }
        let session = session(through: proxy)
        // Names only: Network.framework connects loopback address literals directly, without the proxy;
        // HostHTTP refuses unapproved literals before connecting (MaliciousPluginTests).
        for url in ["http://public-looking.invalid:\(server.port)/", "http://meta.invalid/"] {
            do {
                _ = try await session.data(from: URL(string: url)!)
                XCTFail("\(url) must be refused")
            } catch {}
        }
        XCTAssertEqual(server.requests.count, 0)
        XCTAssertEqual(proxy.denial(host: "meta.invalid", port: 80), .metadata(host: "meta.invalid"))
        XCTAssertTrue(proxy.connectedDestinations.isEmpty)
    }

    func testPluginHTTPGoesThroughTheProxyAndReportsWhyItWasRefused() throws {
        try requirePinning()
        let server = try LoopbackHTTPServer(body: "from-loopback")
        defer { server.stop() }
        let host = "nas.invalid"
        let config = try config(["\(host):\(server.port)"])
        let resolver = TestResolver(answers: [host: ["127.0.0.1"]])

        let approved = HostHTTP(config: config, auth: nil, captcha: nil,
                                policy: PluginNetworkPolicy(config: config, approvals: [loopbackApproval(port: server.port, host: host)],
                                                            resolver: resolver))
        defer { approved.close() }
        let ok = approved.execute(json: #"[{"method":"GET","url":"http://\#(host):\#(server.port)/a"}]"#, parallel: false)
        XCTAssertTrue(ok.contains("from-loopback"), ok)

        let unapproved = HostHTTP(config: config, auth: nil, captcha: nil,
                                  policy: PluginNetworkPolicy(config: config, approvals: [], resolver: resolver))
        defer { unapproved.close() }
        let refused = unapproved.execute(json: #"[{"method":"GET","url":"http://\#(host):\#(server.port)/a"}]"#, parallel: false)
        XCTAssertTrue(refused.contains("is on your local network"), refused)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testProxySpeaksOnlyConnect() throws {
        let policy = PluginNetworkPolicy(config: try config(["everywhere"]), approvals: [], resolver: TestResolver.publicOnly)
        let proxy = try PluginEgressProxy.start(policy: policy)
        defer { proxy.close() }
        let reply = try rawExchange(port: proxy.port, "GET http://example.invalid/ HTTP/1.1\r\nHost: example.invalid\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 405"), reply)
    }

    private func rawExchange(port: Int, _ text: String) throws -> String {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw URLError(.cannotConnectToHost) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = text.withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buffer, buffer.count)
        return n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
    }
}
