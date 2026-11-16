import Foundation

/// Recognizes URLs whose host the system treats as local network, so plugin
/// traffic to them goes through the permission gate. Loopback is excluded: it
/// never prompts. Host names are judged by form alone (".local", single-label
/// names); a public-looking name that resolves to a LAN address isn't caught.
enum LocalNetworkAddress {
    static func isLocalNetwork(_ url: URL) -> Bool {
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if let octets = ipv4(host) { return isLocal(ipv4: octets) }
        if let bytes = ipv6(host) {
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return isLocal(ipv4: Array(bytes[12..<16]))
            }
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return false }
            return (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)   // fe80::/10 link-local
                || bytes[0] & 0xfe == 0xfc                          // fc00::/7 unique local
        }
        return host.hasSuffix(".local") || !host.contains(".")
    }

    private static func isLocal(ipv4 o: [UInt8]) -> Bool {
        switch (o[0], o[1]) {
        case (10, _), (192, 168), (169, 254): true
        case (172, let b) where (16...31).contains(b): true
        default: false
        }
    }

    private static func ipv4(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func ipv6(_ host: String) -> [UInt8]? {
        let unscoped = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var address = in6_addr()
        guard inet_pton(AF_INET6, unscoped, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }
}

/// Puts plugin traffic to local-network hosts behind the permission gate.
/// Declines are kept per host, so turning one LAN-hosted source off on this
/// device leaves other sources and Local Network Sync alone.
struct PluginLocalNetworkAccess: Sendable {
    let gate: PermissionGate

    static func feature(host: String) -> String { "local-network-host:\(host)" }

    /// Whether `url` may be fetched for `source` (a plugin name or the host).
    @MainActor
    func authorize(_ url: URL, source: String?, origin: PermissionOrigin) async -> Bool {
        guard LocalNetworkAddress.isLocalNetwork(url), let host = url.host(percentEncoded: false) else {
            return true
        }
        let decision = await gate.authorize(
            .localNetwork, for: Self.feature(host: host.lowercased()), origin: origin,
            explanation: .pluginLocalNetwork(source: source ?? host, host: host)
        )
        guard decision == .allowed else { return false }
        // The request follows at once; it is what lets the system prompt.
        gate.recordUse(of: .localNetwork)
        return true
    }

    /// The check a plugin runtime runs before each request. Plugin requests
    /// are never a direct user action on this instance, so they explain first.
    func runtimeCheck(source: String) -> @Sendable (URL) async -> Bool {
        { url in await authorize(url, source: source, origin: .settings) }
    }
}

struct LocalNetworkAccessDeclined: LocalizedError {
    let host: String
    var errorDescription: String? {
        "Local network access to \(host) isn’t allowed on this device. Turn it on by adding or updating the source again."
    }
}
