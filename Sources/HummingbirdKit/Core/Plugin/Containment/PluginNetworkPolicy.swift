import Foundation

// MARK: - Address networks and approvals

/// An address or CIDR block (`192.168.1.20`, `100.101.102.103/32`, `fd7a:115c:a1e0::/48`).
struct IPNetwork: Hashable, Sendable, Codable, CustomStringConvertible {
    let address: IPAddress
    let prefixLength: Int

    init(_ address: IPAddress) {
        self.address = address
        prefixLength = address.bytes.count * 8
    }

    init?(cidr text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first, let address = IPAddress(literal: first) else { return nil }
        let maximum = address.bytes.count * 8
        let length = parts.count == 2 ? Int(parts[1]) : maximum
        guard let length, (0...maximum).contains(length) else { return nil }
        self.address = address
        prefixLength = length
    }

    func contains(_ other: IPAddress) -> Bool {
        guard other.bytes.count == address.bytes.count else { return false }
        var remaining = prefixLength
        for (a, b) in zip(address.bytes, other.bytes) {
            guard remaining > 0 else { return true }
            let bits = min(8, remaining)
            let mask: UInt8 = bits == 8 ? 0xff : ~(0xff >> UInt8(bits))
            if a & mask != b & mask { return false }
            remaining -= bits
        }
        return true
    }

    var description: String {
        prefixLength == address.bytes.count * 8 ? address.description : "\(address)/\(prefixLength)"
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = IPNetwork(cidr: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an address or CIDR"))
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// A non-public destination (LAN, loopback, tailnet, ...) the user approved
/// for one plugin: an exact host and port, bound to the addresses it resolved
/// to when the user approved it, or to addresses the user typed. A later
/// resolution to any other non-public address needs a fresh approval.
/// Stored per plugin on this device only; never synced.
struct LocalHostApproval: Codable, Hashable, Sendable, Identifiable {
    var host: String
    var port: Int
    var networks: [IPNetwork]
    var approvedAt: Date = Date()

    var id: String { "\(host):\(port)" }

    init(host: String, port: Int, networks: [IPNetwork], approvedAt: Date = Date()) {
        self.host = PluginNetworkPolicy.normalizedHost(host)
        self.port = port
        self.networks = networks
        self.approvedAt = approvedAt
    }

    func permits(host: String, port: Int, address: IPAddress) -> Bool {
        self.host == PluginNetworkPolicy.normalizedHost(host) && self.port == port
            && networks.contains { $0.contains(address) }
    }

    /// How the install preview and settings show it: "nas.local:8096 → 192.168.1.20".
    var summary: String { "\(host):\(port) → \(networks.map(\.description).joined(separator: ", "))" }
}

/// A non-public destination a plugin's config names, waiting for the user.
struct LocalHostRequest: Hashable, Sendable, Identifiable {
    var host: String
    var port: Int
    /// What it resolves to now (empty when it did not resolve).
    var resolved: [IPAddress]
    var id: String { "\(host):\(port)" }

    var summary: String {
        resolved.isEmpty ? "\(host):\(port) (not found on this network)"
            : "\(host):\(port) → \(resolved.map(\.description).joined(separator: ", "))"
    }

    /// The approval it becomes when the user accepts it as shown.
    var approval: LocalHostApproval? {
        let local = resolved.filter { if case .nonPublic = $0.scope { return true } else { return false } }
        guard !local.isEmpty else { return nil }
        return LocalHostApproval(host: host, port: port, networks: local.map(IPNetwork.init))
    }
}

// MARK: - Resolution

/// Turns a host name into addresses. Resolution happens exactly once per
/// connection, and the connection goes to the address that was checked
/// (`PluginEgressProxy`), so a DNS answer that changes between check and
/// connect cannot redirect it.
protocol HostResolving: Sendable {
    func resolve(host: String, port: Int) throws -> [IPAddress]
}

struct SystemHostResolver: HostResolving {
    struct Failure: LocalizedError {
        let host: String
        var errorDescription: String? { "Could not find \(host)" }
    }

    func resolve(host: String, port: Int) throws -> [IPAddress] {
        if let literal = IPAddress(literal: host) { return [literal] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { throw Failure(host: host) }
        defer { freeaddrinfo(first) }
        var out: [IPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let sa = info.pointee.ai_addr {
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    let bytes = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        withUnsafeBytes(of: sin.pointee.sin_addr) { Array($0) }
                    }
                    if let a = IPAddress(bytes: bytes), !out.contains(a) { out.append(a) }
                case AF_INET6:
                    let bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                        withUnsafeBytes(of: sin6.pointee.sin6_addr) { Array($0) }
                    }
                    if let a = IPAddress(bytes: bytes), !out.contains(a) { out.append(a) }
                default: break
                }
            }
            cursor = info.pointee.ai_next
        }
        guard !out.isEmpty else { throw Failure(host: host) }
        return out
    }
}

// MARK: - Policy

/// Why a plugin may not reach a destination. Its message is what the plugin
/// call fails with, so the failure is visible where the user looks.
enum NetworkDenial: Error, LocalizedError, Equatable, Sendable {
    case scheme(String)
    case notAllowListed(host: String)
    case metadata(host: String)
    case localNotApproved(host: String, port: Int, address: String)
    case localAddressChanged(host: String, port: Int, address: String)
    case unresolvable(host: String)
    case invalid

    var errorDescription: String? {
        switch self {
        case .scheme(let s): "Plugins may only use http and https, not \(s.isEmpty ? "this address" : s + ":")."
        case .notAllowListed(let host):
            "Attempted to access non-whitelisted url: \(host). Add the host to allowUrls in the plugin config."
        case .metadata(let host): "\(host) leads to a cloud metadata service, which plugins can never reach."
        case .localNotApproved(let host, let port, let address):
            "\(host):\(port) is on your local network (\(address)). Approve it in this source’s settings to let the source reach it."
        case .localAddressChanged(let host, let port, let address):
            "\(host):\(port) now points to \(address), which you haven’t approved. Approve the new address in this source’s settings."
        case .unresolvable(let host): "Could not find \(host)."
        case .invalid: "Invalid request URL"
        }
    }
}

/// The address a connection was checked for and must go to.
struct CheckedDestination: Equatable, Sendable {
    let host: String
    let port: Int
    let address: IPAddress
    let scope: AddressScope
}

/// Everything that decides where one plugin may connect: its config's
/// allow-list (public destinations), and the user's exact-host approvals
/// (non-public destinations). Cloud metadata endpoints are never reachable.
/// Every plugin connection is checked with `check(host:port:)` on the
/// address it actually connects to (`PluginEgressProxy`), and also before
/// the request is made (`authorize(_:)`), which is the only way to obtain an
/// `AuthorizedRequest`.
struct PluginNetworkPolicy: Sendable {
    struct Entry: Hashable, Sendable {
        enum Kind: Hashable, Sendable { case everywhere, exact(String), domain(String) }
        let kind: Kind
        let port: Int?
    }

    let pluginID: String
    let entries: [Entry]
    let approvals: [LocalHostApproval]
    let resolver: any HostResolving
    /// False for content a plugin only points at (media, subtitles, images): any public
    /// host, but non-public addresses still need the user's approval.
    private(set) var requiresAllowList = true

    /// The policy for fetching content this plugin references (`requiresAllowList` false).
    var forReferencedContent: PluginNetworkPolicy {
        var copy = self
        copy.requiresAllowList = false
        return copy
    }

    init(config: PluginConfig, approvals: [LocalHostApproval], resolver: any HostResolving = SystemHostResolver()) {
        pluginID = config.id
        entries = Self.parse(config.allowUrls)
        self.approvals = approvals
        self.resolver = resolver
    }

    static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// Parses `allowUrls`: "everywhere", "host", "host:port", ".domain", "*.domain",
    /// and full URLs, which some configs use.
    static func parse(_ raw: [String]) -> [Entry] {
        raw.compactMap { item in
            var s = item.trimmingCharacters(in: .whitespaces).lowercased()
            guard !s.isEmpty else { return nil }
            if s == "everywhere" { return Entry(kind: .everywhere, port: nil) }
            if s.contains("://"), let u = URL(string: s), let h = u.host { s = h + (u.port.map { ":\($0)" } ?? "") }
            var port: Int?
            if s.hasPrefix("[") {
                // [v6]:port
                if let close = s.firstIndex(of: "]") {
                    let rest = s[s.index(after: close)...]
                    if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
                    s = String(s[...close])
                }
            } else if s.filter({ $0 == ":" }).count == 1, let colon = s.lastIndex(of: ":") {
                port = Int(s[s.index(after: colon)...])
                s = String(s[..<colon])
            }
            s = normalizedHost(s)
            if s.hasPrefix("*.") { return Entry(kind: .domain(String(s.dropFirst(2))), port: port) }
            if s.hasPrefix(".") { return Entry(kind: .domain(String(s.dropFirst())), port: port) }
            return Entry(kind: .exact(s), port: port)
        }
    }

    /// Whether the allow-list names `host` (and `port`, when an entry gives one).
    func allowListed(host: String, port: Int) -> Bool {
        let h = Self.normalizedHost(host)
        return entries.contains { entry in
            if let p = entry.port, p != port { return false }
            switch entry.kind {
            case .everywhere: return true
            case .exact(let e): return e == h
            case .domain(let d): return h == d || h.hasSuffix("." + d)
            }
        }
    }

    /// The exact (non-wildcard) hosts and ports the config names that need a
    /// local-network approval: by their form, or because they resolve now to
    /// a non-public address. Wildcards and "everywhere" never qualify.
    func localHostRequests() -> [LocalHostRequest] {
        var out: [LocalHostRequest] = []
        for entry in entries {
            guard case .exact(let host) = entry.kind else { continue }
            let ports = entry.port.map { [$0] } ?? [443, 80]
            let resolved = (try? resolver.resolve(host: host, port: ports[0])) ?? []
            let local = AddressClassifier.isLocalName(host)
                || resolved.contains { if case .nonPublic = $0.scope { return true } else { return false } }
            guard local else { continue }
            for port in ports where !out.contains(where: { $0.host == host && $0.port == port }) {
                out.append(LocalHostRequest(host: host, port: port, resolved: resolved))
            }
        }
        return out
    }

    /// Checks a destination: allow-list, then one resolution, then the
    /// classification of the address that will be connected to.
    func check(host rawHost: String, port: Int) -> Result<CheckedDestination, NetworkDenial> {
        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty, (1...65_535).contains(port) else { return .failure(.invalid) }
        guard !requiresAllowList || allowListed(host: host, port: port) else { return .failure(.notAllowListed(host: host)) }
        // A name that is local by its form (localhost, .local, single label) needs an approval
        // whatever it resolves to.
        if AddressClassifier.isLocalName(host), IPAddress(literal: host) == nil,
           !approvals.contains(where: { $0.host == host && $0.port == port }) {
            return .failure(.localNotApproved(host: host, port: port, address: host))
        }
        let addresses: [IPAddress]
        do { addresses = try resolver.resolve(host: host, port: port) } catch { return .failure(.unresolvable(host: host)) }
        guard !addresses.isEmpty else { return .failure(.unresolvable(host: host)) }
        // A name that answers with a metadata address is hostile: refuse it whole.
        if addresses.contains(where: { $0.scope == .metadata }) { return .failure(.metadata(host: host)) }
        // Every answer must be acceptable: a name that answers with a public address and an
        // unapproved private one is refused whole, so no client (a resolver-racing connection on a
        // platform without the egress proxy, say) can end up on the private one.
        var chosen: CheckedDestination?
        for address in addresses {
            switch address.scope {
            case .public:
                if chosen == nil { chosen = CheckedDestination(host: host, port: port, address: address, scope: .public) }
            case .nonPublic:
                let forHost = approvals.filter { $0.host == host && $0.port == port }
                guard forHost.contains(where: { $0.permits(host: host, port: port, address: address) }) else {
                    return .failure(forHost.isEmpty
                        ? .localNotApproved(host: host, port: port, address: address.description)
                        : .localAddressChanged(host: host, port: port, address: address.description))
                }
                if chosen == nil { chosen = CheckedDestination(host: host, port: port, address: address, scope: address.scope) }
            case .metadata:
                return .failure(.metadata(host: host))
            }
        }
        return chosen.map { .success($0) } ?? .failure(.unresolvable(host: host))
    }

    /// The checks that need no DNS: scheme, allow-list, and for an address literal or a local name,
    /// an approval. Used where blocking on DNS would stall other work (redirect callbacks) and the
    /// egress proxy checks the resolved address anyway.
    func precheck(url: URL) -> Result<Void, NetworkDenial> {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .failure(.scheme(scheme)) }
        guard let rawHost = url.host(percentEncoded: false), !rawHost.isEmpty else { return .failure(.invalid) }
        let host = Self.normalizedHost(rawHost)
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard !requiresAllowList || allowListed(host: host, port: port) else { return .failure(.notAllowListed(host: host)) }
        if let literal = IPAddress(literal: host) {
            switch literal.scope {
            case .public: return .success(())
            case .metadata: return .failure(.metadata(host: host))
            case .nonPublic:
                return approvals.contains { $0.permits(host: host, port: port, address: literal) }
                    ? .success(()) : .failure(.localNotApproved(host: host, port: port, address: literal.description))
            }
        }
        if AddressClassifier.isLocalName(host), !approvals.contains(where: { $0.host == host && $0.port == port }) {
            return .failure(.localNotApproved(host: host, port: port, address: host))
        }
        return .success(())
    }

    /// The scheme and destination check for a URL a plugin wants fetched.
    func check(url: URL) -> Result<CheckedDestination, NetworkDenial> {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .failure(.scheme(scheme)) }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return .failure(.invalid) }
        return check(host: host, port: url.port ?? (scheme == "https" ? 443 : 80))
    }

    /// The only way to make a request for plugin traffic (`AuthorizedRequest`).
    func authorize(_ url: URL) -> Result<AuthorizedRequest, NetworkDenial> {
        check(url: url).map { AuthorizedRequest(url: url, destination: $0) }
    }

    /// Whether a URL is one this plugin may hand the app to open or fetch
    /// without connecting now: http(s), allow-listed, not a non-public
    /// address by its form. (Fetches still go through `check`.)
    func mayReference(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https", let host = url.host(percentEncoded: false) else { return false }
        if let literal = IPAddress(literal: host), !literal.scope.isPublic { return false }
        if AddressClassifier.isLocalName(host) { return false }
        return allowListed(host: host, port: url.port ?? (scheme == "https" ? 443 : 80))
    }
}

/// A plugin request whose URL passed `PluginNetworkPolicy`. Its initializer
/// is private to this file, so plugin HTTP cannot be built from an unchecked
/// URL: `HostHTTP` only sends `AuthorizedRequest.urlRequest`.
struct AuthorizedRequest: Sendable {
    let url: URL
    let destination: CheckedDestination

    fileprivate init(url: URL, destination: CheckedDestination) {
        self.url = url
        self.destination = destination
    }

    var urlRequest: URLRequest { URLRequest(url: url) }
}
