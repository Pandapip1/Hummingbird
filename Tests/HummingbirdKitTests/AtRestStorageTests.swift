import ATAppSync
import CredentialStorage
import Foundation
import XCTest
@testable import HummingbirdKit

/// The library database, its legacy files and the pending-write queue at
/// rest: sealed with the profile's key (the device's for the rest), readable
/// while locked once the device has been unlocked since boot, and salvaged
/// value by value.
final class AtRestStorageTests: XCTestCase {
    private let profile = UUID()
    private var historyName: String { "profile.\(profile.uuidString.lowercased()).history" }

    func testTheDatabaseAndTheQueueHoldNoPlaintext() async throws {
        let directory = makeTestDirectory("AtRest")
        let device = LockableDevice(unlocked: true)
        let storage = Storage(directory: directory, protectedData: device, atRest: testAtRestKeyring)
        storage.save(["A very private title"], name: historyName)
        await storage.flush()
        device.unlocked = false   // locked: the next write goes to the queue
        storage.save(["Another private title"], name: historyName)
        await storage.flush()

        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            XCTAssertNil(bytes.range(of: Data("private title".utf8)), "\(name) holds plaintext")
        }
        XCTAssertEqual(storage.load([String].self, name: historyName), ["Another private title"])
        XCTAssertEqual(device.protection(of: directory.appendingPathComponent("storage.sqlite3")),
                       .completeUntilFirstUserAuthentication)
    }

    /// A value written before sealing is read once and sealed in place; one
    /// that doesn't open is moved to quarantine, never deleted, and the rest
    /// of the database is untouched.
    func testLegacyValuesAreSealedAndDamagedOnesQuarantined() throws {
        let directory = makeTestDirectory("AtRest")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(["old title"]).write(to: directory.appendingPathComponent(historyName + ".json"))
        let backend = StorageBackend(directory: directory, queue: nil, protectedData: UnprotectedDataAvailability(),
                                     atRest: testAtRestKeyring)
        XCTAssertEqual(backend.load([String].self, name: historyName), ["old title"])
        let file = directory.appendingPathComponent("storage.sqlite3")
        XCTAssertNil(try Data(contentsOf: file).range(of: Data("old title".utf8)), "imported sealed")

        // A value sealed with a key this device doesn't have (or damaged).
        let foreign = StorageDatabase(url: file, protectedData: UnprotectedDataAvailability(), atRest: .ephemeral())
        XCTAssertTrue(foreign.save(Data(#"["unreadable"]"#.utf8), name: "profile.\(profile.uuidString.lowercased()).playlists"))
        let database = StorageDatabase(url: file, protectedData: UnprotectedDataAvailability(), atRest: testAtRestKeyring)
        let playlists = "profile.\(profile.uuidString.lowercased()).playlists"
        XCTAssertNil(database.load(name: playlists))
        XCTAssertEqual(database.quarantinedCount(name: playlists), 1, "kept, not deleted")
        XCTAssertEqual(database.load(name: historyName), Data(#"["old title"]"#.utf8), "the rest is untouched")
    }

    #if os(macOS)
    /// The at-rest key is kept after-first-unlock, this device only: work done
    /// while the device is locked again (a background window) can still open
    /// the data. A key kept the usual way (when unlocked) could not.
    func testTheKeyIsReadableWhileLockedAfterTheFirstUnlock() async throws {
        let keychain = FakeKeychainBackend()
        let namespace = "tests.at-rest.\(UUID().uuidString)"
        func keyring(_ accessibility: CredentialAccessibility, _ suffix: String) -> AtRestKeyring {
            AtRestKeyring(vault: KeychainCredentialStore(
                serviceNamespace: namespace + suffix, accessibility: accessibility, backend: keychain,
                consentStore: MemoryFallbackConsentStore(), preferences: makeTestPreferences(in: makeTestDirectory())
            ))
        }
        let directory = makeTestDirectory("AtRest")
        let storage = Storage(directory: directory, protectedData: LockableDevice(unlocked: true),
                              atRest: keyring(.afterFirstUnlock, ""))
        storage.save(["kept"], name: historyName)
        await storage.flush()
        let sealedWhenUnlocked = try keyring(.whenUnlocked, ".contrast").sealer(profile: profile, purpose: "storage")
            .seal(Data("x".utf8), context: "x")

        keychain.setDevice(.lockedAfterFirstUnlock)
        // A fresh process (a background launch): nothing cached.
        let background = Storage(directory: directory, protectedData: LockableDevice(unlocked: false),
                                 atRest: keyring(.afterFirstUnlock, ""))
        XCTAssertEqual(background.load([String].self, name: historyName), ["kept"])
        XCTAssertEqual(keyring(.whenUnlocked, ".contrast").sealer(profile: profile, purpose: "storage")
            .open(sealedWhenUnlocked, context: "x"), .unavailable, "a when-unlocked key isn't readable now")

        keychain.setDevice(.beforeFirstUnlock)
        let beforeFirstUnlock = Storage(directory: directory, protectedData: LockableDevice(unlocked: false),
                                        atRest: keyring(.afterFirstUnlock, ""))
        XCTAssertNil(beforeFirstUnlock.load([String].self, name: historyName))
        XCTAssertEqual(StorageDatabase(url: directory.appendingPathComponent("storage.sqlite3"),
                                       protectedData: UnprotectedDataAvailability(), atRest: testAtRestKeyring)
            .quarantinedCount(name: historyName), 0, "unreadable for now is not damage")
    }
    #endif
}

/// A store that is there but can't be read now (before the first unlock, a
/// locked keychain) is never read as empty: the app doesn't start on an
/// empty library, so it can't save one over the real library.
final class UnavailableStoreTests: XCTestCase {
    func testTheAppDoesNotStartOnAnEmptyLibraryWhileItsStoreIsLocked() async throws {
        let directory = makeTestDirectory("LockedLaunch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vault = LockableVault()
        let preferences = makeTestPreferences(in: directory)
        func stores() -> AppDataStores {
            AppDataStores(dataDirectory: directory, cachesDirectory: directory.appendingPathComponent("Caches"),
                          preferences: preferences, credentialStore: TestCredentialStore(),
                          storage: Storage(directory: directory, protectedData: UnprotectedDataAvailability(),
                                           atRest: AtRestKeyring(vault: vault)))
        }
        let first = stores()
        first.storage.save(["kept"], name: "search_history")
        await first.flush()

        vault.locked = true
        let snapshot = await AppPersistenceSnapshot.load(stores: stores())
        XCTAssertNil(snapshot, "unreadable is not empty")

        vault.locked = false
        let unlocked = await AppPersistenceSnapshot.load(stores: stores())
        XCTAssertEqual(unlocked?.searchHistory, ["kept"])
    }

    func testADamagedValueThatCantBeSetAsideIsNotMissing() throws {
        let directory = makeTestDirectory("LockedLaunch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("storage.sqlite3")
        let database = StorageDatabase(url: file, protectedData: UnprotectedDataAvailability(), atRest: testAtRestKeyring)
        guard case .missing = database.read(name: "nothing") else { return XCTFail("no row is missing") }
        let vault = LockableVault()
        let keyring = AtRestKeyring(vault: vault)
        XCTAssertTrue(StorageDatabase(url: file, protectedData: UnprotectedDataAvailability(), atRest: keyring)
            .save(Data("x".utf8), name: "value"))
        vault.locked = true
        guard case .unavailable = StorageDatabase(url: file, protectedData: UnprotectedDataAvailability(),
                                                  atRest: AtRestKeyring(vault: vault)).read(name: "value") else {
            return XCTFail("a key that can't be read is unavailable")
        }
    }
}
