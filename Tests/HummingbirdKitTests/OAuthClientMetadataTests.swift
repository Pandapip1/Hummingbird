import ATProtoKit
import Foundation
import XCTest
@testable import HummingbirdKit

/// The OAuth client the app asks for must be the one Web/ publishes: an
/// authorization server fetches the client ID URL and checks the app's
/// request against what it finds there.
final class OAuthClientMetadataTests: XCTestCase {
    private struct Metadata: Decodable {
        let clientID: URL
        let clientURI: URL
        let redirectURIs: [URL]
        let scope: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientURI = "client_uri"
            case redirectURIs = "redirect_uris"
            case scope
        }
    }

    private static var metadataFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HummingbirdKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Web/hummingbird/oauth-client-metadata.json")
    }

    private func metadata() throws -> Metadata {
        try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: Self.metadataFile))
    }

    func testAppRequestsThePublishedClient() throws {
        let configuration = ProfileAccountService.configuration
        let published = try metadata()

        XCTAssertEqual(configuration.clientID, published.clientID)
        XCTAssertTrue(published.redirectURIs.contains(configuration.redirectURI))
        XCTAssertEqual(configuration.scopes.joined(separator: " "), published.scope)
    }

    /// Hummingbird's client lives on its own subdomain, not the 80bps apex or
    /// AppSync's: each project gets its own (sub)domain.
    func testClientIsHostedOnHummingbirdsSubdomain() throws {
        let published = try metadata()

        XCTAssertEqual(published.clientID.scheme, "https")
        XCTAssertEqual(published.clientID.host, "hummingbird.eightybps.com")
        XCTAssertEqual(published.clientURI.host, published.clientID.host)
    }

    /// atproto OAuth only accepts a native app's custom-scheme redirect when
    /// the scheme is the client ID's hostname in reverse-domain order.
    func testRedirectSchemeIsTheClientHostReversed() throws {
        let configuration = ProfileAccountService.configuration
        let host = try XCTUnwrap(configuration.clientID.host)

        XCTAssertEqual(
            configuration.redirectURI.scheme,
            host.split(separator: ".").reversed().joined(separator: ".")
        )
    }
}
