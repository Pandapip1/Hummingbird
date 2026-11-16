import ATAppSync
import Foundation
import XCTest

/// Apple's local network privacy refuses DNS-SD registration and browsing for
/// service types the app doesn't declare, which surfaced only as "The local
/// inbox server is unavailable."
final class LocalNetworkDeclarationTests: XCTestCase {
    private static var infoPlist: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HummingbirdKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Apps/iOS/Info.plist")
    }

    func testInfoPlistDeclaresAppSyncBonjourService() throws {
        let data = try Data(contentsOf: Self.infoPlist)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let services = try XCTUnwrap(plist["NSBonjourServices"] as? [String])
        XCTAssertTrue(services.contains(AppSyncAuthority.bonjourServiceType))
        XCTAssertNotNil(plist["NSLocalNetworkUsageDescription"] as? String)
    }

    func testPolicyDeniedExplainsLocalNetworkPermission() {
        let error = InstanceMessagingError.localNetworkDiscoveryFailed(operation: .advertise, code: -65570)
        XCTAssertTrue(error.errorDescription?.contains("Local Network") == true)
    }
}
