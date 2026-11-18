import Foundation

/// Where an IP address leads, as far as plugin containment cares. This is the
/// one classifier every plugin-reachable connection is checked with (plugin
/// HTTP and its redirects, the plugin browser, media fetched for a plugin):
/// see `PluginNetworkPolicy`. It works on resolved addresses, never on host
/// names, so a public name that resolves into a private range is caught.
enum AddressScope: Equatable, Sendable {
    /// Routable on the public internet.
    case `public`
    /// Loopback, private, shared/CGNAT (Tailscale), link-local, ULA,
    /// documentation, benchmarking, multicast, reserved or otherwise not a
    /// public destination. A plugin reaches these only for a host the user
    /// approved by exact name (`PluginLocalHostApproval`).
    case nonPublic(NonPublicKind)
    /// A cloud instance-metadata endpoint. Never reachable from a plugin,
    /// approved or not.
    case metadata

    enum NonPublicKind: String, Sendable {
        case unspecified, loopback, privateNetwork, sharedAddressSpace, linkLocal, uniqueLocal, siteLocal
        case documentation, benchmarking, ietfProtocol, multicast, reserved, broadcast, nat64Local
    }

    var isPublic: Bool { self == .public }
}

/// A resolved IPv4 or IPv6 address, as raw bytes.
struct IPAddress: Hashable, Sendable, CustomStringConvertible {
    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// Parses a literal (dotted quad, or IPv6 with or without brackets and zone).
    init?(literal raw: String) {
        var host = raw
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            self.bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        let unscoped = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var v6 = in6_addr()
        if inet_pton(AF_INET6, unscoped, &v6) == 1 {
            self.bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }

    var isIPv4: Bool { bytes.count == 4 }

    var description: String {
        if isIPv4 { return bytes.map(String.init).joined(separator: ".") }
        var groups: [String] = []
        for i in stride(from: 0, to: 16, by: 2) { groups.append(String(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]), radix: 16)) }
        return groups.joined(separator: ":")
    }

    var scope: AddressScope { AddressClassifier.classify(self) }
}

enum AddressClassifier {
    /// Instance-metadata services (AWS/GCP/Azure/OpenStack 169.254.169.254,
    /// AWS IPv6 fd00:ec2::254, ECS task metadata 169.254.170.2, Alibaba
    /// 100.100.100.200). Always blocked.
    static let metadataAddresses: Set<IPAddress> = [
        IPAddress(literal: "169.254.169.254")!,
        IPAddress(literal: "169.254.170.2")!,
        IPAddress(literal: "100.100.100.200")!,
        IPAddress(literal: "fd00:ec2::254")!,
    ]

    static func classify(_ address: IPAddress) -> AddressScope {
        if metadataAddresses.contains(address) { return .metadata }
        return address.isIPv4 ? classify(ipv4: address.bytes) : classify(ipv6: address.bytes)
    }

    static func classify(ipv4 o: [UInt8]) -> AddressScope {
        if let v4 = IPAddress(bytes: o), metadataAddresses.contains(v4) { return .metadata }
        let a = o[0], b = o[1], c = o[2]
        switch a {
        case 0: return .nonPublic(.unspecified)                                  // 0.0.0.0/8
        case 10: return .nonPublic(.privateNetwork)                              // 10/8
        case 100 where b & 0xc0 == 64: return .nonPublic(.sharedAddressSpace)    // 100.64/10 (CGNAT, Tailscale)
        case 127: return .nonPublic(.loopback)                                   // 127/8
        case 169 where b == 254: return .nonPublic(.linkLocal)                   // 169.254/16
        case 172 where b & 0xf0 == 16: return .nonPublic(.privateNetwork)        // 172.16/12
        case 192 where b == 0 && c == 0: return .nonPublic(.ietfProtocol)        // 192.0.0/24
        case 192 where b == 0 && c == 2: return .nonPublic(.documentation)       // 192.0.2/24
        case 192 where b == 168: return .nonPublic(.privateNetwork)              // 192.168/16
        case 198 where b & 0xfe == 18: return .nonPublic(.benchmarking)          // 198.18/15
        case 198 where b == 51 && c == 100: return .nonPublic(.documentation)    // 198.51.100/24
        case 203 where b == 0 && c == 113: return .nonPublic(.documentation)     // 203.0.113/24
        default: break
        }
        if o == [255, 255, 255, 255] { return .nonPublic(.broadcast) }
        if a & 0xf0 == 224 { return .nonPublic(.multicast) }                      // 224/4
        if a & 0xf0 == 240 { return .nonPublic(.reserved) }                       // 240/4
        return .public
    }

    static func classify(ipv6 b: [UInt8]) -> AddressScope {
        if let v6 = IPAddress(bytes: b), metadataAddresses.contains(v6) { return .metadata }
        let first10Zero = b[0..<10].allSatisfy { $0 == 0 }
        // :: and ::1
        if b.allSatisfy({ $0 == 0 }) { return .nonPublic(.unspecified) }
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return .nonPublic(.loopback) }
        // IPv4-mapped ::ffff:a.b.c.d and IPv4-compatible ::a.b.c.d: the embedded address decides.
        if first10Zero, b[10] == 0xff, b[11] == 0xff { return classify(ipv4: Array(b[12..<16])) }
        if first10Zero, b[10] == 0, b[11] == 0 { return classify(ipv4: Array(b[12..<16])) }
        // NAT64 well-known prefix 64:ff9b::/96 embeds the IPv4 destination.
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
            return classify(ipv4: Array(b[12..<16]))
        }
        // Local-use NAT64 64:ff9b:1::/48 only ever leads into a local network.
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4] == 0x00, b[5] == 0x01 {
            return .nonPublic(.nat64Local)
        }
        // 6to4 2002::/16 embeds the IPv4 address in bits 16-47.
        if b[0] == 0x20, b[1] == 0x02 {
            let embedded = classify(ipv4: Array(b[2..<6]))
            return embedded.isPublic ? .public : embedded
        }
        // Teredo 2001:0::/32: server IPv4 in bits 32-63, client IPv4 inverted in the last 32 bits.
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x00, b[3] == 0x00 {
            let server = classify(ipv4: Array(b[4..<8]))
            if !server.isPublic { return server }
            let client = classify(ipv4: b[12..<16].map { ~$0 })
            return client.isPublic ? .public : client
        }
        // Documentation 2001:db8::/32.
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return .nonPublic(.documentation) }
        // Discard-only 100::/64.
        if b[0] == 0x01, b[1] == 0x00, b[2..<8].allSatisfy({ $0 == 0 }) { return .nonPublic(.reserved) }
        if b[0] == 0xff { return .nonPublic(.multicast) }                               // ff00::/8
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return .nonPublic(.linkLocal) }          // fe80::/10
        if b[0] == 0xfe, b[1] & 0xc0 == 0xc0 { return .nonPublic(.siteLocal) }          // fec0::/10
        if b[0] & 0xfe == 0xfc { return .nonPublic(.uniqueLocal) }                      // fc00::/7 (Tailscale fd7a:115c:a1e0::/48)
        // Only global unicast 2000::/3 is public; everything else is reserved.
        if b[0] & 0xe0 != 0x20 { return .nonPublic(.reserved) }
        return .public
    }

    /// Host names that never lead to the public internet by their form alone:
    /// `localhost`, mDNS `.local`, `.home.arpa`, `.internal`, `.lan`,
    /// single-label names. (Resolution decides for everything else.)
    static func isLocalName(_ host: String) -> Bool {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        for suffix in [".local", ".home.arpa", ".internal", ".lan", ".intranet", ".corp", ".private"] where h.hasSuffix(suffix) {
            return true
        }
        return !h.contains(".") && IPAddress(literal: h) == nil
    }
}
