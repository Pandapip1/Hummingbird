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
}
