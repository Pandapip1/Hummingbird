import ATProtoKit
import XCTest
@testable import HummingbirdKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class ProfileSyncTests: XCTestCase {
    func testProfileUsesOwnerSelfSpace() throws {
        let did = try XCTUnwrap(DID(rawValue: "did:plc:owner"))
        let space = SpaceReference(authority: did, type: HummingbirdProfileSchema.spaceType,
                                   key: HummingbirdProfileSchema.spaceKey)
        XCTAssertEqual(space.description,
                       "at://did:plc:owner/space/com.eightybps.hummingbird.profile/self")
    }

    func testSyncedPluginContainsPreferencesButCannotContainCredentials() throws {
        let configJSON = #"{"name":"Example","id":"example","sourceUrl":"https://plugins.example/config.json"}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(configJSON.utf8))
        let installed = InstalledPlugin(config: config, script: "plugin = {};",
                                        settings: ["region": "us"], enabled: false)
        let synced = try XCTUnwrap(SyncedPlugin(installed))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(synced)) as? [String: Any]

        XCTAssertEqual(object?["settings"] as? [String: String], ["region": "us"])
        XCTAssertNil(object?["auth"])
        XCTAssertNil(object?["captcha"])
        XCTAssertNil(object?["cookies"])
        XCTAssertNil(object?["headers"])
        XCTAssertNil(object?["script"])
    }

    @MainActor
    func testPluginSettingsAreJournaledButCredentialsAreNot() throws {
        let previousStore = AuthKeychain.store
        AuthKeychain.store = InMemoryCredentialStore()
        defer { AuthKeychain.store = previousStore }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = try OfflineMutationJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let recorder = ProfileMutationJournal(journal: journal)
        let configJSON = #"{"name":"Example","id":"example","sourceUrl":"https://plugins.example/config.json"}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(configJSON.utf8))
        let manager = PluginManager(
            installed: [InstalledPlugin(config: config, script: "secret executable")],
            profileJournal: recorder
        )

        manager.setSetting(pluginID: "example", key: "region", value: "ca")
        let beforeCredential = journal.pending()
        manager.saveAuth(SourceAuth(headers: ["plugins.example": ["authorization": "Bearer secret"]]), pluginID: "example")

        XCTAssertEqual(journal.pending(), beforeCredential)
        let encoded = try JSONEncoder().encode(try XCTUnwrap(beforeCredential.last?.value))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("region"))
        XCTAssertFalse(text.contains("secret executable"))
        XCTAssertFalse(text.contains("Bearer secret"))
    }

    @MainActor
    func testLibraryDeletionLeavesDurableTombstone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let journal = try OfflineMutationJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let library = LibraryStore(profileJournal: ProfileMutationJournal(journal: journal))
        let playlist = library.createPlaylist(name: "Offline")
        library.deletePlaylist(playlist.id)

        let key = try XCTUnwrap(RecordKey(rawValue: playlist.id.uuidString.lowercased()))
        XCTAssertNotNil(journal.tombstone(collection: HummingbirdProfileSchema.playlist, key: key))
        XCTAssertEqual(journal.pending().last?.operation, .delete)
    }

    func testMutationJournalsAreIsolatedByAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProfileMutationJournal(storageDirectory: directory)
        let firstAccount = DID(rawValue: "did:plc:first")!
        let secondAccount = DID(rawValue: "did:plc:second")!
        let first = try recorder.activate(account: firstAccount)
        try first.appendPut(
            collection: HummingbirdProfileSchema.subscription, key: RecordKey(rawValue: "one")!,
            value: .string("first")
        )

        let second = try recorder.activate(account: secondAccount)
        XCTAssertTrue(second.events().isEmpty)
        recorder.deactivate()

        let reopenedFirst = try recorder.activate(account: firstAccount)
        XCTAssertEqual(reopenedFirst.events().count, 1)
        XCTAssertEqual(reopenedFirst.events().first?.value, .string("first"))
    }
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: LockedSecret] = [:]

    func load(account: String) -> Data? { lock.withLock { values[account]?.data() } }

    func save(_ data: Data?, account: String) {
        lock.withLock {
            guard let data else {
                values.removeValue(forKey: account)
                return
            }
            guard let secret = LockedSecret(data) else {
                preconditionFailure("Unable to lock credential memory")
            }
            values[account] = secret
        }
    }
}

/// Test credentials remain in non-pageable storage between protocol-required `Data` copies.
private final class LockedSecret: @unchecked Sendable {
    private let bytes: UnsafeMutableRawPointer
    private let count: Int

    init?(_ data: Data) {
        // `mlock` accepts arbitrary addresses and rounds the covered range to pages.
        // Allocate at least one byte so the empty-secret case still has a valid lifetime.
        count = data.count
        bytes = .allocate(byteCount: max(data.count, 1), alignment: 1)
        guard platformLockMemory(bytes, max(data.count, 1)) else {
            bytes.deallocate()
            return nil
        }
        data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    }

    func data() -> Data {
        Data(bytes: bytes, count: count)
    }

    deinit {
        platformZeroMemory(bytes, max(count, 1))
        platformUnlockMemory(bytes, max(count, 1))
        bytes.deallocate()
    }
}

private func platformLockMemory(_ bytes: UnsafeMutableRawPointer, _ count: Int) -> Bool {
    mlock(bytes, count) == 0
}

private func platformUnlockMemory(_ bytes: UnsafeMutableRawPointer, _ count: Int) {
    _ = munlock(bytes, count)
}

private func platformZeroMemory(_ bytes: UnsafeMutableRawPointer, _ count: Int) {
    // The allocation was exposed to the OS by `mlock`, so this externally visible
    // write cannot be elided as a dead store before `munlock`.
    memset(bytes, 0, count)
}
