import XCTest
@testable import ATProtoKit

final class ATProtoTypesTests: XCTestCase {
    func testNSIDValidation() {
        XCTAssertEqual(NSID(rawValue: "com.eightybps.hummingbird.profile")?.rawValue,
                       "com.eightybps.hummingbird.profile")
        XCTAssertNil(NSID(rawValue: "com.8bps.hummingbird"))
        XCTAssertNil(NSID(rawValue: "not-an-nsid"))
    }

    func testProfileSpaceRoundTrip() throws {
        let did = try XCTUnwrap(DID(rawValue: "did:plc:example"))
        let type = try XCTUnwrap(NSID(rawValue: "com.eightybps.hummingbird.profile"))
        let key = try XCTUnwrap(RecordKey(rawValue: "self"))
        let space = SpaceReference(authority: did, type: type, key: key)
        XCTAssertEqual(SpaceReference(string: space.description), space)
    }

    func testDPoPNoncesAreScopedToIssuerOrigin() {
        let issuer = URL(string: "https://auth.example.com")!
        let pds = URL(string: "https://pds.example.com")!
        var session = ATProtoOAuthSession(
            account: DID(rawValue: "did:plc:example")!, handle: "alice.example.com", pds: pds,
            authorizationServer: issuer, accessToken: "access", refreshToken: "refresh",
            scope: "atproto", tokenType: "DPoP", expiresAt: nil
        )
        session.setDPoPNonce("authorization-nonce", for: issuer.appendingPathComponent("oauth/token"))
        XCTAssertEqual(session.dpopNonce(for: issuer.appendingPathComponent("oauth/par")), "authorization-nonce")
        XCTAssertNil(session.dpopNonce(for: pds.appendingPathComponent("xrpc/example.method")))
    }
}
