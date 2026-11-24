import CredentialStorage
import Crypto
import Foundation
import PlatformSupport
import Synchronization
import XCTest
@testable import ATAppSync

/// The synced data cache: normalised, salvageable, confidential, and aware
/// that devices legitimately see different results.
final class CacheJournalTests: XCTestCase {
    private let profile = UUID()
    private let anonymous = CacheFetchContext(sourceVersion: "1", locale: "en-GB")
    private var viewer: CacheViewer { CacheViewer(contexts: ["yt": anonymous]) }

    // MARK: normalised storage

    func testAnEntityInManyListsIsStoredOnce() throws {
        let cache = makeCache().cache
        cache.put(listKey("channel/a"), context: anonymous, entities: [entity("v1"), entity("v2")])
        cache.put(listKey("feed/home"), context: anonymous, entities: [entity("v1"), entity("v3")])
        cache.put(listKey("search/q"), context: anonymous, entities: [entity("v1")])
        XCTAssertEqual(cache.usage.entities, 3)
        XCTAssertEqual(cache.usage.lists, 3)
        XCTAssertEqual(cache.list(listKey("feed/home"), for: viewer)?.entities.map(\.key.url), ["v1", "v3"])
    }

    func testIdenticalLargeFieldsAreStoredOnce() throws {
        let cache = makeCache().cache
        let description = Data(String(repeating: "Same description. ", count: 200).utf8)
        cache.put(key("v1"), context: anonymous, payload: Data("1".utf8), fields: ["description": description])
        cache.put(key("v2"), context: anonymous, payload: Data("2".utf8), fields: ["description": description])
        XCTAssertEqual(cache.usage.blobs, 1)
        XCTAssertEqual(cache.entity(key("v2"), for: viewer)?.fields["description"], description)
    }

    func testATransferCarriesEachEntityAndBlobOnce() throws {
        let (a, b) = try pairedCaches()
        let shared = Data(String(repeating: "x", count: 4_000).utf8)
        a.put(listKey("channel/a"), context: anonymous, entities: [
            (key("v1"), Data("1".utf8), ["description": shared]),
            (key("v2"), Data("2".utf8), ["description": shared]),
        ])
        a.put(listKey("feed/home"), context: anonymous, entities: [(key("v1"), Data("1".utf8), ["description": shared])])
        let manifest = try XCTUnwrap(a.manifest())
        let want = try b.want(from: manifest)
        let transfer = try a.transfer(for: want)
        XCTAssertEqual(transfer.entities.count, 2)
        XCTAssertEqual(Set(transfer.entities.map(\.key)).count, transfer.entities.count)
        XCTAssertEqual(transfer.blobs.count, 1, "the shared description travels once")
        XCTAssertEqual(transfer.lists.count, 2)
        XCTAssertEqual(try b.apply(transfer), 4)
        XCTAssertEqual(b.list(listKey("channel/a"), for: viewer)?.entities.count, 2)
        // Asked again, nothing is wanted.
        XCTAssertTrue(try b.want(from: try XCTUnwrap(a.manifest())).isEmpty)
    }

    // MARK: salvage

    func testADamagedRecordLosesOnlyItself() throws {
        let made = makeCache()
        for name in ["v1", "v2", "v3"] {
            made.cache.put(key(name), context: anonymous, payload: Data(name.utf8))
            made.cache.persist()
        }
        let file = try partitionFile(made)
        var data = try Data(contentsOf: file)
        // Damage the middle of the file: the second record's ciphertext.
        let middle = data.count / 2
        data[middle] ^= 0xFF
        data[middle + 1] ^= 0xFF
        try data.write(to: file)

        let reopened = reopen(made)
        let survivors = ["v1", "v2", "v3"].filter { reopened.entity(key($0), for: viewer) != nil }
        XCTAssertEqual(survivors.count, 2, "only the damaged record is lost")
    }

    func testAMissingStoreStartsEmptyAndRefills() throws {
        let made = makeCache()
        made.cache.put(key("v1"), context: anonymous, payload: Data("1".utf8))
        made.cache.persist()
        try FileManager.default.removeItem(at: made.directory)   // the store went missing
        let reopened = reopen(made)
        XCTAssertEqual(reopened.usage.entities, 0)
        reopened.put(key("v2"), context: anonymous, payload: Data("2".utf8))
        reopened.persist()
        XCTAssertNotNil(reopen(made).entity(key("v2"), for: viewer))
    }

    /// A record written by an older version of the format is read and kept.
    func testRecordsInAnOlderFormatArePreserved() throws {
        let made = makeCache()
        made.cache.put(key("current"), context: anonymous, payload: Data("c".utf8))
        made.cache.persist()
        let epoch = try XCTUnwrap(made.cache.currentEpochForTesting)
        // Format 1 records had no origin, storedAt or lastUsed.
        let record = CacheEntityRecord(key: key("old"), context: anonymous, accountHash: nil, payload: Data("o".utf8),
                                       fields: [:], fetchedAt: Date(), origin: .local, storedAt: Date())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(CacheFrame.entity(record))) as? [String: Any])
        var entity = try XCTUnwrap(json["entity"] as? [String: Any])
        var fields = try XCTUnwrap(entity["_0"] as? [String: Any])
        for removed in ["origin", "storedAt", "lastUsed"] { fields[removed] = nil }
        entity["_0"] = fields
        json["entity"] = entity
        var body = Data([1])
        body.append(try Zlib.compress(try JSONSerialization.data(withJSONObject: json)))
        let frame = try CacheFrameFile.encode(body: body, epoch: epoch, profileID: profile)
        let handle = try FileHandle(forWritingTo: try partitionFile(made))
        try handle.seekToEnd()
        try handle.write(contentsOf: frame)
        try handle.close()

        let reopened = reopen(made)
        XCTAssertEqual(reopened.entity(key("old"), for: viewer)?.payload, Data("o".utf8))
        XCTAssertNotNil(reopened.entity(key("current"), for: viewer))
    }

    // MARK: eviction

    func testLowDiskEvictionIsIncrementalAndLeastRecentlyUsedFirst() throws {
        let cache = makeCache().cache
        let start = Date()
        for index in 0..<10 {
            cache.put(key("v\(index)"), context: anonymous, payload: Data(repeating: 1, count: 1_000))
            _ = cache.entity(key("v\(index)"), for: viewer, now: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(cache.evict(toBytes: 0, limit: 3), 3)
        XCTAssertEqual(cache.usage.entities, 7)
        XCTAssertNil(cache.entity(key("v0"), for: viewer))
        XCTAssertNotNil(cache.entity(key("v9"), for: viewer))
    }

    func testEvictionKeepsReferencesConsistent() throws {
        let cache = makeCache().cache
        let shared = Data(repeating: 7, count: 2_000)
        cache.put(listKey("channel/a"), context: anonymous, entities: (0..<6).map {
            (key("v\($0)"), Data(repeating: UInt8($0), count: 500), ["description": $0 % 2 == 0 ? shared : Data([UInt8($0)])])
        })
        cache.evict(toBytes: cache.usage.bytes / 2, limit: 3)
        let violations = cache.integrityViolations
        XCTAssertEqual(violations.dangling, 0)
        XCTAssertEqual(violations.orphaned, 0)
        if let list = cache.list(listKey("channel/a"), for: viewer) {
            XCTAssertTrue(list.isPartial || list.entities.count == 6)
        }
    }

    // MARK: confidentiality

    func testRecordsAreEncryptedAndProtectedAtRest() throws {
        let made = makeCache()
        made.cache.put(key("https://example.com/watch?v=secret"), context: anonymous,
                       payload: Data("Very private title".utf8))
        made.cache.persist()
        let file = try partitionFile(made)
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data("secret".utf8)))
        XCTAssertNil(bytes.range(of: Data("Very private".utf8)))
        XCTAssertEqual(made.device.protection(of: file), .complete)
    }

    func testAnotherProfileCannotReadTheCache() throws {
        let made = makeCache()
        made.cache.put(key("v1"), context: anonymous, payload: Data("1".utf8))
        made.cache.persist()
        let data = try Data(contentsOf: try partitionFile(made))
        let epoch = try XCTUnwrap(made.cache.currentEpochForTesting)
        XCTAssertEqual(CacheFrameFile.decode(data, epoch: epoch, profileID: profile).frames.count, 1)
        XCTAssertTrue(CacheFrameFile.decode(data, epoch: epoch, profileID: UUID()).frames.isEmpty)
        let other = makeCache(profile: UUID(), vault: made.vault).cache
        let otherEpoch = try XCTUnwrap(other.currentEpochForTesting)
        XCTAssertTrue(CacheFrameFile.decode(data, epoch: otherEpoch, profileID: profile).frames.isEmpty)
    }

    func testBlobIDsAreKeyedNotPlainHashes() throws {
        let a = makeCache().cache
        let b = makeCache(profile: UUID()).cache
        let content = Data("A public description everyone can fetch".utf8)
        a.put(key("v1"), context: anonymous, payload: Data(), fields: ["description": content])
        b.put(key("v1"), context: anonymous, payload: Data(), fields: ["description": content])
        let plain = SHA256.hash(data: content).prefix(16).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(a.blobIDs, b.blobIDs, "different keys, different IDs")
        XCTAssertFalse(a.blobIDs.contains { $0.raw == plain })
    }

    func testIdentitiesNeverPrintTheirURLs() {
        let entityKey = key("https://example.com/watch?v=private")
        let list = listKey("https://example.com/@someone")
        for printed in ["\(entityKey)", String(reflecting: entityKey), "\(list)", String(reflecting: list)] {
            XCTAssertFalse(printed.contains("example.com"), printed)
        }
    }

    func testClearingErasesTheKeysAndOnlyThisDevicesCopy() throws {
        let (a, b) = try pairedCaches()
        a.put(key("v1"), context: anonymous, payload: Data("1".utf8))
        try sync(from: a, to: b)
        a.persist()
        let oldEpoch = try XCTUnwrap(a.currentEpochForTesting)
        let oldFile = a.directoryForTesting.appendingPathComponent(CacheJournal.fileName(oldEpoch.id))
        let oldBytes = try Data(contentsOf: oldFile)

        try a.clear()
        XCTAssertEqual(a.usage.entities, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        // Crypto-erase: the old generation's keys are gone from the store,
        // so surviving bytes can't be opened by anything this device holds.
        let stored = try a.epochStoreForTesting.load()
        XCTAssertNotEqual(stored.current?.id, oldEpoch.id)
        XCTAssertTrue(stored.retired.isEmpty)
        let newEpoch = try XCTUnwrap(a.currentEpochForTesting)
        XCTAssertTrue(CacheFrameFile.decode(oldBytes, epoch: newEpoch, profileID: profile).frames.isEmpty)
        // The peer keeps its copy: nothing is sent, nothing deleted there.
        XCTAssertNotNil(b.entity(key("v1"), for: viewer))
    }

    // MARK: key epochs

    func testRevocationMovesTheRemainingDevicesToKeysTheRevokedOneLacks() throws {
        let vaults = (MemoryVault(), MemoryVault(), MemoryVault())
        let ids = (peerID(1), peerID(2), peerID(3))
        let a = makeCache(device: ids.0, vault: vaults.0).cache
        let b = makeCache(device: ids.1, vault: vaults.1).cache
        let c = makeCache(device: ids.2, vault: vaults.2).cache
        let all: Set = [ids.0, ids.1, ids.2]
        for (cache, own) in [(a, ids.0), (b, ids.1), (c, ids.2)] { try cache.follow(trusted: all.subtracting([own])) }
        try converge([(a, ids.0), (b, ids.1), (c, ids.2)], trusted: all)
        XCTAssertEqual(a.epoch, c.epoch)
        let content = Data("description".utf8)
        a.put(key("v1"), context: anonymous, payload: Data("1".utf8), fields: ["description": content])
        try sync(from: a, to: b)
        let revoked = try XCTUnwrap(c.currentEpochForTesting)

        // c is revoked: a and b leave its epoch and converge on a new one.
        try a.follow(trusted: [ids.1])
        try b.follow(trusted: [ids.0])
        try converge([(a, ids.0), (b, ids.1)], trusted: [ids.0, ids.1])
        let current = try XCTUnwrap(a.currentEpochForTesting)
        XCTAssertEqual(a.epoch, b.epoch)
        XCTAssertNotEqual(current.id, revoked.id)
        XCTAssertFalse(current.members.contains(ids.2))
        XCTAssertNil(a.offer(to: ids.2), "the revoked device is never sent the new keys")

        // Re-keyed in place: nothing lost, nothing refetched.
        XCTAssertTrue(a.needsMigration)
        XCTAssertEqual(a.migrate(limit: .max, accounts: []), 0)
        XCTAssertFalse(a.needsMigration)
        XCTAssertEqual(a.entity(key("v1"), for: viewer)?.fields["description"], content)
        XCTAssertEqual(a.blobIDs, [current.blobID(for: content)], "no old-epoch ID survives")
        XCTAssertNotEqual(revoked.blobID(for: content), current.blobID(for: content))
        XCTAssertTrue(try a.epochStoreForTesting.load().retired.isEmpty, "the old keys are erased")

        // The revoked keys open nothing written now.
        a.persist()
        let file = a.directoryForTesting.appendingPathComponent(CacheJournal.fileName(current.id))
        XCTAssertTrue(CacheFrameFile.decode(try Data(contentsOf: file), epoch: revoked, profileID: profile).frames.isEmpty)

        // Old-epoch traffic is refused both ways.
        XCTAssertThrowsError(try b.want(from: try XCTUnwrap(c.manifest())))
        let stale = CacheTransfer(epoch: revoked.id, entities: [], lists: [], blobs: [])
        XCTAssertThrowsError(try b.apply(stale)) { XCTAssertEqual($0 as? CacheJournal.CacheError, .epochMismatch) }
    }

    func testMigrationResumesAfterInterruption() throws {
        let made = makeCache()
        for index in 0..<20 { made.cache.put(key("v\(index)"), context: anonymous, payload: Data("\(index)".utf8)) }
        made.cache.persist()
        try made.cache.follow(trusted: [], now: Date().addingTimeInterval(40 * 86_400))   // the epoch aged out
        XCTAssertTrue(made.cache.needsMigration)
        XCTAssertEqual(made.cache.migrate(limit: 5, accounts: []), 15)
        made.cache.persist()

        // Killed mid-migration, relaunched: it carries on from where it was.
        let reopened = reopen(made)
        XCTAssertTrue(reopened.needsMigration)
        while reopened.migrate(limit: 5, accounts: []) > 0 {}
        _ = reopened.migrate(limit: 1, accounts: [])
        XCTAssertFalse(reopened.needsMigration)
        XCTAssertEqual(reopened.usage.entities, 20)
        for index in 0..<20 { XCTAssertNotNil(reopened.entity(key("v\(index)"), for: viewer)) }
    }

    // MARK: divergent contexts

    func testASignedInOnlyEntryIsNotVisibleWithoutThatSignIn() throws {
        let (a, b) = try pairedCaches()
        let patron = CacheFetchContext(sourceVersion: "1", account: "alice", locale: "en-GB", elevation: ["members-only"])
        a.put(key("post"), context: patron, payload: Data("paywalled".utf8))
        try sync(from: a, to: b, accounts: [])
        XCTAssertNil(b.entity(key("post"), for: viewer), "anonymous device")
        let otherAccount = CacheViewer(contexts: ["yt": CacheFetchContext(sourceVersion: "1", account: "bob", locale: "en-GB", elevation: ["members-only"])],
                                       allowedElevation: ["members-only"])
        XCTAssertNil(b.entity(key("post"), for: otherAccount), "another account")
        let alice = CacheViewer(contexts: ["yt": patron], allowedElevation: ["members-only"])
        XCTAssertEqual(b.entity(key("post"), for: alice)?.payload, Data("paywalled".utf8))
    }

    func testAnAnonymousEntryNeverReplacesASignedInOne() throws {
        let (a, b) = try pairedCaches()
        let signedIn = CacheFetchContext(sourceVersion: "1", account: "alice", locale: "en-GB")
        b.put(key("v1"), context: signedIn, payload: Data("rich".utf8))
        a.put(key("v1"), context: anonymous, payload: Data("poor".utf8))
        try sync(from: a, to: b)
        let alice = CacheViewer(contexts: ["yt": signedIn])
        XCTAssertEqual(b.entity(key("v1"), for: alice)?.payload, Data("rich".utf8))
        XCTAssertEqual(b.entity(key("v1"), for: alice)?.fit, .fresh)
    }

    func testAnABVariantDoesNotFlapOnSync() throws {
        let vaults = (MemoryVault(), MemoryVault(), MemoryVault())
        let ids = (peerID(1), peerID(2), peerID(3))
        let a = makeCache(device: ids.0, vault: vaults.0).cache
        let b = makeCache(device: ids.1, vault: vaults.1).cache
        let c = makeCache(device: ids.2, vault: vaults.2).cache
        let all: Set = [ids.0, ids.1, ids.2]
        for (cache, own) in [(a, ids.0), (b, ids.1), (c, ids.2)] { try cache.follow(trusted: all.subtracting([own])) }
        try converge([(a, ids.0), (b, ids.1), (c, ids.2)], trusted: all)
        a.put(key("v1"), context: anonymous, payload: Data("Title A".utf8))
        c.put(key("v1"), context: anonymous, payload: Data("Title B".utf8), fetchedAt: Date().addingTimeInterval(60))
        try sync(from: a, to: b)
        try sync(from: c, to: b)
        try sync(from: a, to: b)
        XCTAssertEqual(b.entity(key("v1"), for: viewer)?.payload, Data("Title A".utf8), "the first variant stays")
        // Its own refresh replaces it.
        b.put(key("v1"), context: anonymous, payload: Data("Title C".utf8))
        try sync(from: c, to: b)
        XCTAssertEqual(b.entity(key("v1"), for: viewer)?.payload, Data("Title C".utf8))
        XCTAssertEqual(a.entity(key("v1"), for: viewer)?.payload, Data("Title A".utf8), "devices may differ")
    }

    func testAnotherPluginVersionOrSettingsServesOnlyAsAPlaceholder() throws {
        let cache = makeCache().cache
        cache.put(key("v1"), context: anonymous, payload: Data("1".utf8))
        let newer = CacheViewer(contexts: ["yt": CacheFetchContext(sourceVersion: "2", locale: "en-GB")])
        XCTAssertEqual(cache.entity(key("v1"), for: newer)?.fit, .placeholder)
        let otherSettings = CacheViewer(contexts: ["yt": CacheFetchContext(sourceVersion: "1", settings: "hd", locale: "en-GB")])
        XCTAssertEqual(cache.entity(key("v1"), for: otherSettings)?.fit, .placeholder)
        XCTAssertEqual(cache.entity(key("v1"), for: viewer)?.fit, .fresh)
    }

    func testAnAgeRestrictedEntryIsNotShownToARestrictedProfile() throws {
        let cache = makeCache().cache
        let restricted = CacheFetchContext(sourceVersion: "1", locale: "en-GB", elevation: ["age-restricted"])
        cache.put(key("v1"), context: restricted, payload: Data("1".utf8))
        let child = CacheViewer(contexts: ["yt": restricted], allowedElevation: [])
        XCTAssertNil(cache.entity(key("v1"), for: child))
        let adult = CacheViewer(contexts: ["yt": restricted], allowedElevation: ["age-restricted"])
        XCTAssertNotNil(cache.entity(key("v1"), for: adult))
    }

    // MARK: sync padding

    func testResponsesArePaddedToSizeSteps() throws {
        var small = CacheSyncResponse(nonce: UUID())
        try small.pad()
        var larger = CacheSyncResponse(nonce: UUID())
        larger.transfer = CacheTransfer(epoch: CacheEpochID(number: 1, id: UUID()), entities: [], lists: [],
                                        blobs: [Data(repeating: 1, count: 3_000)])
        try larger.pad()
        let sizes = try [small, larger].map { try JSONEncoder().encode($0).count }
        XCTAssertEqual(sizes[0], CacheSyncPadding.step)
        XCTAssertEqual(sizes[1], CacheSyncPadding.step)
    }

    // MARK: helpers

    private struct Made {
        let cache: CacheJournal
        let kept: KeptDirectory
        var directory: URL { kept.url }
        let device: FakeDevice
        let vault: MemoryVault
        let instance: AppSyncPeerID
        let profile: UUID
    }

    private func makeCache(profile: UUID? = nil, device instance: AppSyncPeerID? = nil,
                           vault: MemoryVault = MemoryVault()) -> Made {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheJournal-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let kept = KeptDirectory(named: "SyncedCache", inDataDirectory: root)
        let device = FakeDevice(unlocked: true)
        let instance = instance ?? peerID(UInt8.random(in: 100...200))
        let profile = profile ?? self.profile
        let cache = CacheJournal(directory: kept, profileID: profile, instance: instance,
                                 credentialStore: vault, availability: device)
        return Made(cache: cache, kept: kept, device: device, vault: vault, instance: instance, profile: profile)
    }

    private func reopen(_ made: Made) -> CacheJournal {
        CacheJournal(directory: made.kept, profileID: made.profile, instance: made.instance,
                     credentialStore: made.vault, availability: made.device)
    }

    private func partitionFile(_ made: Made) throws -> URL {
        let epoch = try XCTUnwrap(made.cache.epoch)
        return made.directory.appendingPathComponent(CacheJournal.fileName(epoch))
    }

    /// Two trusted devices on one epoch.
    private func pairedCaches() throws -> (CacheJournal, CacheJournal) {
        let ids = (peerID(1), peerID(2))
        let a = makeCache(device: ids.0).cache
        let b = makeCache(device: ids.1).cache
        try a.follow(trusted: [ids.1])
        try b.follow(trusted: [ids.0])
        try converge([(a, ids.0), (b, ids.1)], trusted: [ids.0, ids.1])
        return (a, b)
    }

    /// Exchanges epoch offers until every device holds the winning epoch.
    private func converge(_ devices: [(CacheJournal, AppSyncPeerID)], trusted: Set<AppSyncPeerID>) throws {
        for _ in 0..<devices.count {
            for (reader, readerID) in devices {
                for (peer, _) in devices where peer !== reader {
                    if let offer = peer.offer(to: readerID) {
                        _ = try reader.consider(offer, trusted: trusted.subtracting([readerID]))
                    }
                }
            }
        }
        XCTAssertEqual(Set(devices.compactMap { $0.0.epoch }).count, 1, "converged")
    }

    private func sync(from source: CacheJournal, to target: CacheJournal, accounts: [String] = []) throws {
        let want = try target.want(from: try XCTUnwrap(source.manifest()))
        try target.apply(try source.transfer(for: want), accounts: accounts)
    }

    private func key(_ url: String) -> CacheEntityKey { CacheEntityKey(kind: "video", source: "yt", url: url) }
    private func listKey(_ url: String) -> CacheListKey { CacheListKey(kind: "list", source: "yt", url: url) }
    private func entity(_ url: String) -> (key: CacheEntityKey, payload: Data, fields: [String: Data]) {
        (key(url), Data(url.utf8), [:])
    }

    private func peerID(_ seed: UInt8) -> AppSyncPeerID { AppSyncPeerID(signingKey: Data([seed])) }
}

/// Credentials kept in memory.
final class MemoryVault: AppSyncCredentialStore {
    private let values = Mutex<[String: SecureBytes]>([:])
    func load(account: String) throws -> SecureBytes? { values.withLock { $0[account] } }
    func save(_ secret: SecureBytes, account: String) throws { values.withLock { $0[account] = secret } }
    func delete(account: String) throws { _ = values.withLock { $0.removeValue(forKey: account) } }
}
