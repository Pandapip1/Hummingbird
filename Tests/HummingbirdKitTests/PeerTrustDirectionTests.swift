import ATAppSync
import Foundation
import XCTest
@testable import HummingbirdKit

/// Trust is directed. Sync settings explains when it only goes one way,
/// which otherwise just looks like a device that never answers.
final class PeerTrustDirectionTests: XCTestCase {
    func testInboundTrustFollowsThePeersOwnLatestFact() throws {
        let a = try makePeer("a"), b = try makePeer("b")
        let bID = b.peer.publicIdentity.stableID
        _ = try a.trust(b.peer.publicIdentity)
        XCTAssertEqual(a.trustStore.inbound(from: bID), .unknown)

        _ = try b.trust(a.peer.publicIdentity)
        _ = try a.trustStore.merge(b.trustStore.facts())
        XCTAssertEqual(a.trustStore.inbound(from: bID), .trustsThisInstance)

        _ = try b.revokeTrust(with: a.peer.publicIdentity)
        _ = try a.trustStore.merge(b.trustStore.facts())
        XCTAssertEqual(a.trustStore.inbound(from: bID), .distrustsThisInstance)

        // A peer known only because it trusts this instance is listed.
        let c = try makePeer("c")
        _ = try c.trust(a.peer.publicIdentity)
        _ = try a.trustStore.merge(c.trustStore.facts())
        let known = a.trustStore.knownPeers(among: [], localAppIDs: [])
        XCTAssertEqual(known.first { $0.id == c.peer.publicIdentity.stableID }?.inbound, .trustsThisInstance)
    }

    func testOneWayTrustIsExplainedWithWhatSyncsAndTheFix() {
        let since = AppSyncTrustVersion(timestamp: HybridLogicalTimestamp(milliseconds: 1, counter: 0, deviceID: UUID()))
        let trusted = AppSyncPeerTrustState.directlyTrusted(since: since)

        XCTAssertNil(PeerTrustExplanation(state: trusted, inbound: .trustsThisInstance, accountSync: false))
        XCTAssertNil(PeerTrustExplanation(state: .unknown, inbound: .unknown, accountSync: false))
        XCTAssertNil(PeerTrustExplanation(state: .local, inbound: .unknown, accountSync: false))

        let waiting = PeerTrustExplanation(state: trusted, inbound: .unknown, accountSync: false)
        XCTAssertEqual(waiting?.direction, .onlyThisInstanceTrusts)
        XCTAssertTrue(waiting?.detail.contains("local network") == true)
        XCTAssertFalse(waiting?.detail.contains("account") == true)
        XCTAssertTrue(waiting?.fix.contains("Verify") == true)

        let refused = PeerTrustExplanation(state: trusted, inbound: .distrustsThisInstance, accountSync: true)
        XCTAssertEqual(refused?.direction, .peerDistrustsThisInstance)
        XCTAssertTrue(refused?.detail.contains("through your account") == true)

        let theirs = PeerTrustExplanation(state: .unknown, inbound: .trustsThisInstance, accountSync: false)
        XCTAssertEqual(theirs?.direction, .onlyPeerTrusts)
        XCTAssertTrue(theirs?.fix.contains("distrust") == true)
    }

    private func makePeer(_ name: String) throws -> AppSyncPeerService {
        try AppSyncPeerService(
            credentialStore: TestCredentialStore(),
            storageDirectory: makeTestDirectory("PeerTrust-\(name)")
        )
    }
}
