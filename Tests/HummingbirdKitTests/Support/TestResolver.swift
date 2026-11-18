import Foundation
@testable import HummingbirdKit

/// A resolver for tests: never touches DNS. Names map to fixed addresses;
/// anything unlisted resolves to `fallback` (a public documentation-free
/// address that nothing ever connects to, since tests stub the transport).
struct TestResolver: HostResolving {
    var answers: [String: [String]] = [:]
    var fallback: [String] = ["93.184.215.14"]

    func resolve(host: String, port: Int) throws -> [IPAddress] {
        if let literal = IPAddress(literal: host) { return [literal] }
        let list = answers[PluginNetworkPolicy.normalizedHost(host)] ?? fallback
        let addresses = list.compactMap(IPAddress.init(literal:))
        guard !addresses.isEmpty else { throw SystemHostResolver.Failure(host: host) }
        return addresses
    }

    /// Every name resolves to a public address.
    static let publicOnly = TestResolver()
}

/// Approves loopback `port` for a test fixture plugin, as the user would at install.
func loopbackApproval(port: Int, host: String = "127.0.0.1") -> LocalHostApproval {
    LocalHostApproval(host: host, port: port, networks: [IPNetwork(cidr: "127.0.0.1")!])
}
