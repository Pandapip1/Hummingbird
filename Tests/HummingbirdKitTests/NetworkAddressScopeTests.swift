import XCTest
@testable import HummingbirdKit

/// The one address classifier and the plugin network policy built on it. No DNS: `TestResolver`.
final class NetworkAddressScopeTests: XCTestCase {
    private func scope(_ literal: String) -> AddressScope {
        guard let address = IPAddress(literal: literal) else {
            XCTFail("\(literal) is not an address")
            return .public
        }
        return address.scope
    }

    private func assertNonPublic(_ literals: [String], file: StaticString = #filePath, line: UInt = #line) {
        for literal in literals {
            if case .nonPublic = scope(literal) { continue }
            XCTFail("\(literal) should be non-public, got \(scope(literal))", file: file, line: line)
        }
    }

    func testEveryNonPublicIPv4RangeIsClassified() {
        assertNonPublic([
            "0.0.0.0", "0.255.1.2", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.100.1.1", "100.127.255.254",
            "127.0.0.1", "127.8.9.10", "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.0.0.8", "192.0.2.55",
            "192.168.1.20", "198.18.0.1", "198.19.255.255", "198.51.100.7", "203.0.113.9", "224.0.0.1",
            "239.255.255.250", "240.0.0.1", "255.255.255.255",
        ])
        for literal in ["1.1.1.1", "8.8.8.8", "100.63.255.255", "100.128.0.1", "172.15.0.1", "172.32.0.1",
                        "192.169.0.1", "198.17.0.1", "198.20.0.1", "93.184.215.14"] {
            XCTAssertEqual(scope(literal), .public, literal)
        }
    }

    func testEveryNonPublicIPv6RangeIsClassified() {
        assertNonPublic([
            "::", "::1", "fe80::1", "fec0::1", "fc00::1", "fd12:3456::1", "fd7a:115c:a1e0::1", "ff02::1",
            "2001:db8::1", "100::1", "64:ff9b:1::a00:1",
        ])
        XCTAssertEqual(scope("2606:4700:4700::1111"), .public)
        XCTAssertEqual(scope("2a00:1450:4009:81f::200e"), .public)
    }

    func testEmbeddedIPv4AddressesAreJudgedByTheEmbeddedAddress() {
        // Mapped, compatible, NAT64, 6to4 and Teredo all carry an IPv4 destination.
        assertNonPublic(["::ffff:192.168.1.1", "::ffff:127.0.0.1", "::10.0.0.1", "64:ff9b::a00:5", "64:ff9b::c0a8:101",
                         "2002:c0a8:0101::1", "2002:7f00:1::1"])
        XCTAssertEqual(scope("::ffff:8.8.8.8"), .public)
        XCTAssertEqual(scope("64:ff9b::808:808"), .public)
        XCTAssertEqual(scope("2002:0808:0808::1"), .public)
        // Teredo: server 65.54.227.120, client 192.168.1.1 obfuscated (bitwise inverted).
        assertNonPublic(["2001:0:4136:e378:8000:63bf:3f57:fefe"])
    }

    func testMetadataAddressesAreTheirOwnClass() {
        for literal in ["169.254.169.254", "fd00:ec2::254", "::ffff:169.254.169.254", "100.100.100.200", "169.254.170.2"] {
            XCTAssertEqual(scope(literal), .metadata, literal)
        }
    }

    func testLocalNamesByForm() {
        for name in ["localhost", "foo.localhost", "nas.local", "router.home.arpa", "db.internal", "printer", "nas.lan."] {
            XCTAssertTrue(AddressClassifier.isLocalName(name), name)
        }
        for name in ["example.com", "jellyfin.tail1234.ts.net", "8.8.8.8"] {
            XCTAssertFalse(AddressClassifier.isLocalName(name), name)
        }
    }

    func testCIDRMatching() throws {
        let tailnet = try XCTUnwrap(IPNetwork(cidr: "100.101.102.103/32"))
        XCTAssertTrue(tailnet.contains(IPAddress(literal: "100.101.102.103")!))
        XCTAssertFalse(tailnet.contains(IPAddress(literal: "100.101.102.104")!))
        let lan = try XCTUnwrap(IPNetwork(cidr: "192.168.1.0/24"))
        XCTAssertTrue(lan.contains(IPAddress(literal: "192.168.1.200")!))
        XCTAssertFalse(lan.contains(IPAddress(literal: "192.168.2.1")!))
        let ula = try XCTUnwrap(IPNetwork(cidr: "fd7a:115c:a1e0::/48"))
        XCTAssertTrue(ula.contains(IPAddress(literal: "fd7a:115c:a1e0:ab12::1")!))
        XCTAssertFalse(ula.contains(IPAddress(literal: "fd7a:115c:a1e1::1")!))
        XCTAssertNil(IPNetwork(cidr: "10.0.0.0/33"))
        XCTAssertNil(IPNetwork(cidr: "not an address"))
    }

    // MARK: policy

    private func config(_ allow: [String]) throws -> PluginConfig {
        let json = try JSONSerialization.data(withJSONObject: ["name": "P", "id": "p", "allowUrls": allow])
        return try JSONDecoder().decode(PluginConfig.self, from: json)
    }

    func testAllowListIncludingPortsAndWildcards() throws {
        let policy = PluginNetworkPolicy(config: try config(["api.example.com", ".media.example.org", "*.cdn.test", "host.test:8443"]),
                                         approvals: [], resolver: TestResolver.publicOnly)
        XCTAssertTrue(policy.allowListed(host: "API.Example.com", port: 443))
        XCTAssertTrue(policy.allowListed(host: "a.b.media.example.org", port: 443))
        XCTAssertTrue(policy.allowListed(host: "x.cdn.test", port: 80))
        XCTAssertFalse(policy.allowListed(host: "evilmedia.example.org", port: 443))
        XCTAssertTrue(policy.allowListed(host: "host.test", port: 8443))
        XCTAssertFalse(policy.allowListed(host: "host.test", port: 443))
        XCTAssertFalse(policy.allowListed(host: "example.com", port: 443))
    }

    func testOnlyHTTPAndHTTPSAreReachable() throws {
        let policy = PluginNetworkPolicy(config: try config(["everywhere"]), approvals: [], resolver: TestResolver.publicOnly)
        for url in ["file:///etc/passwd", "ftp://example.com/x", "data:text/plain,hi", "javascript:alert(1)", "gopher://example.com/"] {
            guard case .failure = policy.check(url: URL(string: url)!) else { return XCTFail("\(url) must be refused") }
        }
        guard case .success = policy.check(url: URL(string: "https://example.com/")!) else { return XCTFail("https must pass") }
    }

    func testPublicNameResolvingIntoAnyNonPublicRangeIsBlocked() throws {
        let resolver = TestResolver(answers: [
            "cgnat.example": ["100.64.1.1"], "lan.example": ["10.0.0.5"], "mapped.example": ["::ffff:192.168.1.9"],
            "nat64.example": ["64:ff9b::c0a8:109"], "meta.example": ["169.254.169.254"], "loop.example": ["127.0.0.1"],
        ])
        let policy = PluginNetworkPolicy(config: try config(["everywhere"]), approvals: [], resolver: resolver)
        for host in ["cgnat.example", "lan.example", "mapped.example", "nat64.example", "loop.example"] {
            guard case .failure(.localNotApproved) = policy.check(host: host, port: 443) else {
                return XCTFail("\(host) must need an approval")
            }
        }
        XCTAssertEqual(policy.check(host: "meta.example", port: 80), .failure(.metadata(host: "meta.example")))
    }

    func testApprovalBindsExactHostPortAndAddress() throws {
        let approval = LocalHostApproval(host: "jellyfin.example.ts.net", port: 8096, networks: [IPNetwork(cidr: "100.101.102.103")!])
        let config = try config(["jellyfin.example.ts.net:8096", "everywhere"])
        let good = PluginNetworkPolicy(config: config, approvals: [approval],
                                       resolver: TestResolver(answers: ["jellyfin.example.ts.net": ["100.101.102.103"]]))
        guard case .success(let destination) = good.check(host: "jellyfin.example.ts.net", port: 8096) else { return XCTFail("approved") }
        XCTAssertEqual(destination.address, IPAddress(literal: "100.101.102.103"))
        // Another port of the same host is not approved.
        guard case .failure(.localNotApproved) = good.check(host: "jellyfin.example.ts.net", port: 8097) else { return XCTFail("port") }
        // Re-resolving to another private address needs a fresh approval.
        let moved = PluginNetworkPolicy(config: config, approvals: [approval],
                                        resolver: TestResolver(answers: ["jellyfin.example.ts.net": ["192.168.1.30"]]))
        XCTAssertEqual(moved.check(host: "jellyfin.example.ts.net", port: 8096),
                       .failure(.localAddressChanged(host: "jellyfin.example.ts.net", port: 8096, address: "192.168.1.30")))
        // Any other name resolving to the approved address is still blocked.
        let other = PluginNetworkPolicy(config: config, approvals: [approval],
                                        resolver: TestResolver(answers: ["attacker.example": ["100.101.102.103"]]))
        guard case .failure(.localNotApproved) = other.check(host: "attacker.example", port: 8096) else { return XCTFail("other name") }
    }

    func testMetadataIsNeverApprovable() throws {
        let approval = LocalHostApproval(host: "169.254.169.254", port: 80, networks: [IPNetwork(cidr: "169.254.0.0/16")!])
        let policy = PluginNetworkPolicy(config: try config(["169.254.169.254"]), approvals: [approval], resolver: TestResolver())
        XCTAssertEqual(policy.check(host: "169.254.169.254", port: 80), .failure(.metadata(host: "169.254.169.254")))
    }

    func testMixedAnswersWithAnUnapprovedPrivateAddressAreRefused() throws {
        let policy = PluginNetworkPolicy(config: try config(["mixed.example"]), approvals: [],
                                         resolver: TestResolver(answers: ["mixed.example": ["10.0.0.1", "93.184.215.14"]]))
        guard case .failure(.localNotApproved) = policy.check(host: "mixed.example", port: 443) else { return XCTFail("mixed answer must be refused") }
    }

    func testLocalHostRequestsComeOnlyFromExactEntries() throws {
        let resolver = TestResolver(answers: ["nas.example.com": ["192.168.1.20"], "public.example.com": ["93.184.215.14"]])
        let policy = PluginNetworkPolicy(config: try config(["nas.example.com:8096", "public.example.com", ".wild.example", "everywhere", "127.0.0.1:8742"]),
                                         approvals: [], resolver: resolver)
        let requests = policy.localHostRequests()
        XCTAssertEqual(Set(requests.map(\.id)), ["nas.example.com:8096", "127.0.0.1:8742"])
        let nas = try XCTUnwrap(requests.first { $0.host == "nas.example.com" })
        XCTAssertEqual(nas.summary, "nas.example.com:8096 → 192.168.1.20")
        XCTAssertEqual(nas.approval?.networks.map(\.description), ["192.168.1.20"])
    }

    func testRequestModifierResultIsContained() throws {
        let policy = PluginNetworkPolicy(config: try config(["api.example.com"]), approvals: [], resolver: TestResolver.publicOnly)
        let original = URL(string: "https://media.cdn.test/v.mp4")!
        // Same host: allowed. Headers: CRLF, Host and oversize dropped.
        let ok = try ContainedRequest.make(original: original, originalHeaders: [:],
                                           modifiedURL: "https://media.cdn.test/v.mp4?sig=1",
                                           modifiedHeaders: ["Range": "bytes=0-1", "Host": "evil", "X-Bad": "a\r\nInjected: 1"],
                                           policy: policy)
        XCTAssertEqual(ok.url.query, "sig=1")
        XCTAssertEqual(ok.headers, ["Range": "bytes=0-1"])
        // Another host that is not allow-listed, a LAN literal, a local name and other schemes are refused.
        for target in ["https://evil.test/x", "http://192.168.1.1/admin", "http://router.local/", "file:///etc/hosts", "https://user:pw@media.cdn.test/"] {
            XCTAssertThrowsError(try ContainedRequest.make(original: original, originalHeaders: [:], modifiedURL: target,
                                                           modifiedHeaders: nil, policy: policy), target)
        }
        // An allow-listed host is fine.
        XCTAssertNoThrow(try ContainedRequest.make(original: original, originalHeaders: [:],
                                                   modifiedURL: "https://api.example.com/x", modifiedHeaders: nil, policy: policy))
    }

    func testTokenBucket() {
        let start = Date(timeIntervalSince1970: 0)
        var bucket = TokenBucket(rate: 10, burst: 2, now: start)
        XCTAssertEqual(bucket.take(now: start), 0)
        XCTAssertEqual(bucket.take(now: start), 0)
        XCTAssertEqual(bucket.take(now: start), 0.1, accuracy: 0.0001)
        XCTAssertFalse(bucket.tryTake(now: start))
        XCTAssertTrue(bucket.tryTake(now: start.addingTimeInterval(1)))
    }
}
