import ATProtoKit
import ATAppSync
import CredentialStorage
import XCTest
@testable import HummingbirdKit

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
    func testPluginSettingsAreReplicatedButCredentialsAreNot() throws {
        let previousStore = AuthKeychain.store
        AuthKeychain.store = InMemoryCredentialStore()
        defer { AuthKeychain.store = previousStore }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mutationLog = try AppSyncMutationLog(fileURL: directory.appendingPathComponent("changes.json"))
        let recorder = ProfileChangeStore(mutationLog: mutationLog)
        let configJSON = #"{"name":"Example","id":"example","sourceUrl":"https://plugins.example/config.json"}"#
        let config = try JSONDecoder().decode(PluginConfig.self, from: Data(configJSON.utf8))
        let manager = PluginManager(
            installed: [InstalledPlugin(config: config, script: "secret executable")],
            profileChanges: recorder
        )

        manager.setSetting(pluginID: "example", key: "region", value: "ca")
        let beforeCredential = mutationLog.pending()
        manager.saveAuth(SourceAuth(headers: ["plugins.example": ["authorization": "Bearer secret"]]), pluginID: "example")

        XCTAssertEqual(mutationLog.pending(), beforeCredential)
        let encoded = try JSONEncoder().encode(try XCTUnwrap(beforeCredential.last?.value))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("region"))
        XCTAssertFalse(text.contains("secret executable"))
        XCTAssertFalse(text.contains("Bearer secret"))
    }

    @MainActor
    func testLibraryDeletionLeavesDurableTombstone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mutationLog = try AppSyncMutationLog(fileURL: directory.appendingPathComponent("changes.json"))
        let library = LibraryStore(profileChanges: ProfileChangeStore(mutationLog: mutationLog))
        let playlist = library.createPlaylist(name: "Offline")
        library.deletePlaylist(playlist.id)

        let key = try XCTUnwrap(RecordKey(rawValue: playlist.id.uuidString.lowercased()))
        XCTAssertNotNil(mutationLog.tombstone(collection: HummingbirdProfileSchema.playlist, key: key))
        XCTAssertEqual(mutationLog.pending().last?.operation, .delete)
    }

    func testLocalProfileChangesPersistWithoutAnAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = ProfileChangeStore(storageDirectory: directory)
        let profileID = UUID()
        let first = try recorder.activate(localProfileID: profileID)
        try first.appendPut(
            collection: HummingbirdProfileSchema.subscription, key: RecordKey(rawValue: "one")!,
            value: .string("first")
        )

        recorder.deactivate()

        let reopenedFirst = try recorder.activate(localProfileID: profileID)
        XCTAssertEqual(reopenedFirst.events().count, 1)
        XCTAssertEqual(reopenedFirst.events().first?.value, .string("first"))
    }
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SecureBytes] = [:]

    func load(account: String) -> SecureBytes? { lock.withLock { values[account] } }

    func save(_ secret: SecureBytes, account: String) {
        lock.withLock { values[account] = secret }
    }

    func delete(account: String) {
        lock.withLock { values[account] = nil }
    }
}
