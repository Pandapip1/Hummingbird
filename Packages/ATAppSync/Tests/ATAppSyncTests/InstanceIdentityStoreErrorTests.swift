import XCTest
@testable import ATAppSync
import ATProtoKit

final class InstanceIdentityStoreErrorTests: XCTestCase {
    private struct StoreRefused: Error, Equatable {}

    /// Refuses every operation, as a credential store does when its keychain
    /// is unavailable.
    private struct RefusingStore: AppSyncCredentialStore {
        func load(account: String) throws -> SecureBytes? { throw StoreRefused() }
        func save(_ secret: SecureBytes, account: String) throws { throw StoreRefused() }
        func delete(account: String) throws { throw StoreRefused() }
    }

    /// Accepts writes but keeps nothing.
    private struct ForgetfulStore: AppSyncCredentialStore {
        func load(account: String) -> SecureBytes? { nil }
        func save(_ secret: SecureBytes, account: String) {}
        func delete(account: String) {}
    }

    func testStoreFailuresPropagateUnchanged() {
        XCTAssertThrowsError(try InstanceIdentityStore(credentialStore: RefusingStore(), profileID: UUID()).identity()) {
            XCTAssertEqual($0 as? StoreRefused, StoreRefused())
        }
    }

    func testDroppedWritesAreReported() {
        XCTAssertThrowsError(try InstanceIdentityStore(credentialStore: ForgetfulStore(), profileID: UUID()).identity()) {
            XCTAssertEqual($0 as? InstanceMessagingError, .credentialNotPersisted)
        }
    }

    func testClientWithoutMessagingReportsWhy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ATAppSyncMessagingFailure-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let did = try XCTUnwrap(DID(rawValue: "did:plc:example"))
        let space = SpaceReference(
            authority: did, type: try XCTUnwrap(NSID(rawValue: "com.example.app")),
            key: try XCTUnwrap(RecordKey(rawValue: "self"))
        )
        let appID = try XCTUnwrap(AppSyncAppID(rawValue: "com.example.app"))
        let peer = InstanceIdentity.generate().publicIdentity
        func client(failure: (any Error)?) throws -> AppSyncClient {
            AppSyncClient(
                spaces: SpacesClient(xrpc: XRPCClient(service: try XCTUnwrap(URL(string: "https://pds.invalid")))),
                mutationLog: try OfflineMutationJournal(
                    fileURL: root.appendingPathComponent("\(UUID()).json")
                ),
                repo: did, space: space, appID: appID, messaging: nil, messagingFailure: failure
            )
        }

        do {
            _ = try await client(failure: StoreRefused()).trust(peer)
            XCTFail("Trust succeeded without an instance identity.")
        } catch {
            XCTAssertEqual(error as? StoreRefused, StoreRefused())
        }
        do {
            _ = try await client(failure: nil).trust(peer)
            XCTFail("Trust succeeded without an instance identity.")
        } catch {
            XCTAssertEqual(error as? InstanceMessagingError, .instanceIdentityNotConfigured)
        }
    }
}
