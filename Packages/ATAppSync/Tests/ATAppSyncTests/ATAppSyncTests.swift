import XCTest
import Crypto
@testable import ATAppSync
import ATProtoKit

final class ATAppSyncTests: XCTestCase {
    func testAuthorityUsesStablePLCDIDAndAppSyncDomain() {
        XCTAssertEqual(AppSyncAuthority.did.rawValue, "did:plc:ku5k2fkivxead2a3h46pht7x")
        XCTAssertEqual(AppSyncAuthority.domain, "appsync.eightybps.com")
    }

    func testSignedInstanceRegistrationAuthenticatesRecognizedAppIDs() throws {
        let key = P256.Signing.PrivateKey()
        let instanceID = UUID()
        let signer = try JournalEventSigner(
            instanceID: instanceID, privateKeyRepresentation: key.rawRepresentation
        )
        let hummingbird = AppSyncAppID(rawValue: "com.eightybps.hummingbird")!
        let registration = try AppSyncInstanceRegistration(
            instanceID: instanceID,
            encryptionKey: P256.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            appIDs: [hummingbird], lanEndpoint: nil, lanAppendCapability: nil, signer: signer
        )

        XCTAssertTrue(registration.recognizes(hummingbird))
        XCTAssertNoThrow(try registration.verify())
        XCTAssertFalse(registration.recognizes(AppSyncAppID(rawValue: "com.example.other")!))
    }

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

    func testOfflineJournalSurvivesRestartAndAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ATProtoKitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("journal.json")
        let collection = try XCTUnwrap(NSID(rawValue: "com.eightybps.hummingbird.subscription"))
        let key = try XCTUnwrap(RecordKey(rawValue: "channel"))
        let device = UUID()
        let first = try OfflineMutationJournal(fileURL: file, deviceID: device)
        let mutation = try first.appendPut(collection: collection, key: key, value: .string("saved"))

        let reopened = try OfflineMutationJournal(fileURL: file)
        let pendingBeforeAcknowledgement = reopened.pending()
        XCTAssertEqual(pendingBeforeAcknowledgement, [mutation])
        try reopened.acknowledge([mutation.id])
        let pendingAfterAcknowledgement = reopened.pending()
        XCTAssertTrue(pendingAfterAcknowledgement.isEmpty)
    }

    func testLogicalClockOrdersConcurrentDevicesDeterministically() {
        let earlierDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterDevice = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let lhs = HybridLogicalTimestamp(milliseconds: 100, counter: 0, deviceID: earlierDevice)
        let rhs = HybridLogicalTimestamp(milliseconds: 100, counter: 0, deviceID: laterDevice)
        XCTAssertLessThan(lhs, rhs)
    }

    func testDeletionIsRepresentedAsReplicatedJournalEvent() throws {
        let timestamp = HybridLogicalTimestamp(milliseconds: 10, counter: 2, deviceID: UUID())
        let mutation = JournalMutation(
            collection: NSID(rawValue: "com.example.deleted")!, recordKey: RecordKey(rawValue: "item")!,
            operation: .delete, value: nil, timestamp: timestamp
        )
        let tombstone = ReplicatedJournalEvent(type: NSID(rawValue: "com.example.journal")!, mutation: mutation)
        let roundTrip = try JSONValue.encoding(tombstone).decode(ReplicatedJournalEvent.self)
        XCTAssertEqual(roundTrip, tombstone)
    }

    func testPeerAndServerRoundTripsDeduplicateByEventID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ATProtoKitPeerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collection = NSID(rawValue: "com.example.items")!
        let key = RecordKey(rawValue: "one")!
        let a = try OfflineMutationJournal(fileURL: directory.appendingPathComponent("a.json"))
        let b = try OfflineMutationJournal(fileURL: directory.appendingPathComponent("b.json"))
        let event = try a.appendPut(collection: collection, key: key, value: .string("value"))

        XCTAssertTrue(try b.merge(event, needsUpload: true))
        XCTAssertEqual(b.pending().map(\.id), [event.id])
        try b.acknowledge([event.id]) // B uploaded it to ATProto, then went offline.

        XCTAssertFalse(try a.merge(event, needsUpload: true)) // A meets B again.
        XCTAssertEqual(a.events().filter { $0.id == event.id }.count, 1)
        XCTAssertEqual(b.events().filter { $0.id == event.id }.count, 1)
    }

    func testConcurrentEventsConvergeIndependentOfMergeOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ATProtoKitConvergenceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collection = NSID(rawValue: "com.example.items")!
        let key = RecordKey(rawValue: "one")!
        let timestamp = HybridLogicalTimestamp(milliseconds: 42, counter: 0, deviceID: UUID())
        let first = JournalMutation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, collection: collection,
            recordKey: key, operation: .put, value: .string("first"), timestamp: timestamp
        )
        let second = JournalMutation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, collection: collection,
            recordKey: key, operation: .put, value: .string("second"), timestamp: timestamp
        )
        let left = try OfflineMutationJournal(fileURL: directory.appendingPathComponent("left.json"))
        let right = try OfflineMutationJournal(fileURL: directory.appendingPathComponent("right.json"))

        _ = try left.merge(first, needsUpload: false)
        _ = try left.merge(second, needsUpload: false)
        _ = try right.merge(second, needsUpload: false)
        _ = try right.merge(first, needsUpload: false)

        XCTAssertEqual(left.version(collection: collection, key: key), second.version)
        XCTAssertEqual(right.version(collection: collection, key: key), second.version)
        XCTAssertEqual(Set(left.events()), Set(right.events()))
    }

    func testSignedBatchPreservesEventIDCollisionsAndOrder() throws {
        let id = UUID()
        let device = UUID()
        let timestamp = HybridLogicalTimestamp(milliseconds: 42, counter: 0, deviceID: device)
        let collection = NSID(rawValue: "com.example.items")!
        let first = JournalMutation(
            id: id, collection: collection, recordKey: RecordKey(rawValue: "first")!,
            operation: .put, value: .string("first"), timestamp: timestamp
        )
        let second = JournalMutation(
            id: id, collection: collection, recordKey: RecordKey(rawValue: "second")!,
            operation: .put, value: .string("second"), timestamp: timestamp
        )
        let signer = try JournalEventSigner(
            instanceID: UUID(), privateKeyRepresentation: P256.Signing.PrivateKey().rawRepresentation
        )
        let batch = try ReplicatedJournalBatch(
            type: NSID(rawValue: "com.example.journal")!, mutations: [second, first], signer: signer
        )

        XCTAssertEqual(batch.events, [
            .init(eventID: id, index: 0), .init(eventID: id, index: 1),
        ])
        XCTAssertEqual(try batch.verifiedMutations(), [second, first])
    }

    func testSignedBatchRejectsSubstitutedEventData() throws {
        let signer = try JournalEventSigner(
            instanceID: UUID(), privateKeyRepresentation: P256.Signing.PrivateKey().rawRepresentation
        )
        let timestamp = HybridLogicalTimestamp(milliseconds: 42, counter: 0, deviceID: UUID())
        let original = JournalMutation(
            collection: NSID(rawValue: "com.example.items")!, recordKey: RecordKey(rawValue: "one")!,
            operation: .put, value: .string("original"), timestamp: timestamp
        )
        let batch = try ReplicatedJournalBatch(
            type: NSID(rawValue: "com.example.journal")!, mutations: [original], signer: signer
        )
        let replacement = JournalMutation(
            id: original.id, collection: original.collection, recordKey: original.recordKey,
            operation: .put, value: .string("substituted"), timestamp: timestamp
        )
        let tampered = ReplicatedJournalBatch(
            type: batch.type, batchID: batch.batchID,
            eventData: [.init(eventID: original.id, values: [replacement])], events: batch.events,
            originInstanceID: batch.originInstanceID, originSigningKey: batch.originSigningKey,
            signature: batch.signature
        )

        XCTAssertThrowsError(try tampered.verifiedMutations())
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
        session.setDPoPNonce("resource-nonce", for: pds.appendingPathComponent("xrpc/example.method"))
        XCTAssertEqual(session.dpopNonce(for: pds), "resource-nonce")
        XCTAssertEqual(session.dpopNonce(for: issuer), "authorization-nonce")
    }

    func testObserverRelativeRevocationUsesTrustAtEventTime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ATAppSyncTrustTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makePeer("a", root: root)
        let b = try makePeer("b", root: root)
        let c = try makePeer("c", root: root)
        let peers = [a, b, c]

        for (left, right) in [(a, b), (a, c), (b, c)] {
            let facts = [
                try left.trust(right.peer.publicIdentity),
                try right.trust(left.peer.publicIdentity),
            ]
            for peer in peers { _ = try peer.trustStore.merge(facts) }
        }
        XCTAssertTrue(peers.allSatisfy { observer in
            peers.allSatisfy { candidate in observer.trusts(candidate.peer.publicIdentity) }
        })

        let aRevokesB = try a.revokeTrust(with: b.peer.publicIdentity)
        for peer in peers { _ = try peer.trustStore.merge([aRevokesB]) }
        XCTAssertFalse(c.trusts(b.peer.publicIdentity),
                       "C trusted A when A revoked B, so C accepts the revocation")
        XCTAssertEqual(c.trustStore.state(of: b.peer.publicIdentity.stableID), .implicitlyDistrusted)
        let sharedApp = AppSyncAppID(rawValue: "com.example.shared")!
        XCTAssertEqual(
            c.trustStore.suggestions(
                among: [try b.registration(appIDs: [sharedApp], advertisement: nil)],
                localAppIDs: [sharedApp]
            ).first?.recommendation,
            .verifyOrDistrust
        )
        XCTAssertFalse(b.trusts(a.peer.publicIdentity),
                       "the target derives the reciprocal end of mutual trust")

        let aRevokesC = try a.revokeTrust(with: c.peer.publicIdentity)
        for peer in peers { _ = try peer.trustStore.merge([aRevokesC]) }
        XCTAssertFalse(c.trusts(a.peer.publicIdentity))
        XCTAssertTrue(b.trusts(c.peer.publicIdentity),
                      "B already distrusted A and therefore ignores A's later revocation of C")

        let bRetrustsA = try b.trust(a.peer.publicIdentity)
        for peer in peers { _ = try peer.trustStore.merge([bRetrustsA]) }
        XCTAssertTrue(b.trusts(a.peer.publicIdentity), "B can explicitly restore only B → A")
        XCTAssertFalse(a.trusts(b.peer.publicIdentity), "A → B remains revoked")
    }

    func testTrustFactsConvergeAndPersistIndependentOfDeliveryOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ATAppSyncTrustPersistenceTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makePeer("a", root: root)
        let b = try makePeer("b", root: root)
        let trust = try a.trust(b.peer.publicIdentity)
        let revoke = try a.revokeTrust(with: b.peer.publicIdentity)
        let file = root.appendingPathComponent("replica/facts.json")
        let replica = try AppSyncTrustStore(observer: a.peer.publicIdentity, fileURL: file)

        _ = try replica.merge([revoke, trust])
        XCTAssertFalse(replica.trusts(b.peer.publicIdentity.stableID))
        let reopened = try AppSyncTrustStore(observer: a.peer.publicIdentity, fileURL: file)
        XCTAssertEqual(Set(reopened.facts()), Set([trust, revoke]))
        XCTAssertFalse(reopened.trusts(b.peer.publicIdentity.stableID))
    }

    func testTrustSuggestionsAreActionableAndAppScoped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ATAppSyncTrustSuggestionTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try makePeer("a", root: root)
        let b = try makePeer("b", root: root)
        let c = try makePeer("c", root: root)
        let unknown = try makePeer("unknown", root: root)
        let unrelated = try makePeer("unrelated", root: root)
        let sharedApp = AppSyncAppID(rawValue: "com.example.shared")!
        let otherApp = AppSyncAppID(rawValue: "com.example.other")!

        let aTrustsB = try a.trust(b.peer.publicIdentity)
        let bTrustsC = try b.trust(c.peer.publicIdentity)
        _ = try a.trustStore.merge([aTrustsB, bTrustsC])

        let suggestions = a.trustStore.suggestions(
            among: [
                try b.registration(appIDs: [sharedApp], advertisement: nil),
                try c.registration(appIDs: [sharedApp], advertisement: nil),
                try unknown.registration(appIDs: [sharedApp], advertisement: nil),
                try unrelated.registration(appIDs: [otherApp], advertisement: nil),
            ],
            localAppIDs: [sharedApp]
        )
        let byID = Dictionary(uniqueKeysWithValues: suggestions.map {
            ($0.registration.stablePeerID, $0)
        })

        XCTAssertNil(byID[b.peer.publicIdentity.stableID], "direct trust needs no prompt")
        XCTAssertEqual(byID[c.peer.publicIdentity.stableID]?.recommendation, .verifyDirectly)
        XCTAssertEqual(
            byID[c.peer.publicIdentity.stableID]?.state,
            .indirectlyTrusted(path: [
                a.peer.publicIdentity.stableID,
                b.peer.publicIdentity.stableID,
                c.peer.publicIdentity.stableID,
            ])
        )
        XCTAssertEqual(
            byID[unknown.peer.publicIdentity.stableID]?.recommendation, .verifyOrDistrust
        )
        XCTAssertEqual(byID[unknown.peer.publicIdentity.stableID]?.state, .unknown)
        XCTAssertNil(byID[unrelated.peer.publicIdentity.stableID])
    }

    func testPeerVerificationCodeContainsOnlySelfCertifyingID() throws {
        let identity = AppSyncPeerIdentity.generate()
        let code = AppSyncPeerVerificationCode(peerID: identity.publicIdentity.stableID)

        XCTAssertEqual(code.rawValue, identity.publicIdentity.stableID.rawValue)
        XCTAssertEqual(AppSyncPeerVerificationCode(rawValue: code.rawValue), code)
        XCTAssertNil(AppSyncPeerVerificationCode(rawValue: identity.publicIdentity.id.uuidString))
        XCTAssertFalse(code.rawValue.contains(identity.publicIdentity.id.uuidString))
    }

    func testProfileRegistryLoadsDistinctPersistentInstanceIdentities() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ATAppSyncProfiles-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = MemoryAppSyncCredentialStore()
        let registry = try AppSyncProfileRegistry(
            credentialStore: credentials, storageDirectory: root
        )
        let first = try registry.createProfile()
        let second = try registry.createProfile()

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(
            first.peerService.peer.publicIdentity.stableID,
            second.peerService.peer.publicIdentity.stableID
        )

        let reopened = try AppSyncProfileRegistry(
            credentialStore: credentials, storageDirectory: root
        )
        let restored = try reopened.profiles()
        XCTAssertEqual(Set(restored.map(\.id)), [first.id, second.id])
        XCTAssertEqual(
            Set(restored.map { $0.peerService.peer.publicIdentity.stableID }),
            [
                first.peerService.peer.publicIdentity.stableID,
                second.peerService.peer.publicIdentity.stableID,
            ]
        )
    }

    func testStoredProfileIdentityIsReadOnlyOnce() throws {
        let credentials = MemoryAppSyncCredentialStore()
        let profileID = UUID()
        let first = try InstanceIdentityStore(
            credentialStore: credentials, profileID: profileID
        ).identity()
        credentials.resetLoadCounts()

        let restored = try InstanceIdentityStore(
            credentialStore: credentials, profileID: profileID
        ).identity()

        XCTAssertEqual(restored.publicIdentity, first.publicIdentity)
        XCTAssertEqual(
            credentials.loadCount(
                account: "com.eightybps.appsync.profile.\(profileID.uuidString.lowercased()).instance-identity.v1"
            ),
            1
        )
    }

    func testTrustedProfilesPullSignedJournalOverLANWithoutAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ATAppSyncLAN-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let appID = AppSyncAppID(rawValue: "com.example.lan-test")!
        let a = try makePeer("a", root: root)
        let b = try makePeer("b", root: root)
        let aAdvertisement = try await a.startLANServer(appIDs: [appID])
        let bAdvertisement = try await b.startLANServer(appIDs: [appID])
        let aRegistration = try a.registration(
            appIDs: [appID], advertisement: aAdvertisement
        )
        let bRegistration = try b.registration(
            appIDs: [appID], advertisement: bAdvertisement
        )
        try a.observeDiscoveredRegistration(bRegistration)
        try b.observeDiscoveredRegistration(aRegistration)
        try a.trust(b.peer.publicIdentity)
        try b.trust(a.peer.publicIdentity)

        let aJournal = try OfflineMutationJournal(
            fileURL: root.appendingPathComponent("a-journal.json"),
            signer: a.peer.mutationSigner()
        )
        let bJournal = try OfflineMutationJournal(
            fileURL: root.appendingPathComponent("b-journal.json"),
            signer: b.peer.mutationSigner()
        )
        let event = try aJournal.appendPut(
            collection: NSID(rawValue: "com.example.profile.value")!,
            key: RecordKey(rawValue: "item")!, value: .string("offline")
        )
        _ = AppSyncLANClient(messaging: a, journal: aJournal, appID: appID)
        let bClient = AppSyncLANClient(messaging: b, journal: bJournal, appID: appID)

        let pulledEvents = await bClient.pull()
        XCTAssertEqual(pulledEvents, [event])

        a.stopLANServer()
        let restarted = try await a.startLANServer(appIDs: [appID])
        XCTAssertNotNil(restarted.endpoint.port)
    }

    private func makePeer(_ name: String, root: URL) throws -> AppSyncPeerService {
        try AppSyncPeerService(
            credentialStore: MemoryAppSyncCredentialStore(),
            storageDirectory: root.appendingPathComponent(name, isDirectory: true)
        )
    }
}

private final class MemoryAppSyncCredentialStore: AppSyncCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var loadCounts: [String: Int] = [:]
    func load(account: String) -> Data? {
        lock.withLock {
            loadCounts[account, default: 0] += 1
            return values[account]
        }
    }
    func save(_ data: Data?, account: String) { lock.withLock { values[account] = data } }
    func loadCount(account: String) -> Int { lock.withLock { loadCounts[account, default: 0] } }
    func resetLoadCounts() { lock.withLock { loadCounts.removeAll() } }
}
