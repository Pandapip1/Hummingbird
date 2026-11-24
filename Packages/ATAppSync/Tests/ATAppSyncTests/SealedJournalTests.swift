import ATProtoKit
import CredentialStorage
import Foundation
import Synchronization
import XCTest
@testable import ATAppSync

/// The profile journal at rest: sealed record by record, migrated from
/// plaintext once, and salvaged record by record. Nothing is ever wiped
/// because something didn't open.
final class SealedJournalTests: XCTestCase {
    private let collection = NSID(rawValue: "com.example.history")!

    func testTheJournalOnDiskHoldsNoPlaintext() throws {
        let file = try temporaryFile()
        let journal = try OfflineMutationJournal(fileURL: file, sealer: testAtRestSealer)
        try journal.appendPut(collection: collection, key: RecordKey(rawValue: "a")!,
                              value: .string("A very private title"))
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data("very private".utf8)))
        XCTAssertNil(bytes.range(of: Data("com.example.history".utf8)), "collections are sealed too")

        let reopened = try OfflineMutationJournal(fileURL: file, sealer: testAtRestSealer)
        XCTAssertEqual(reopened.events().first?.value, .string("A very private title"))
    }

    /// A journal written before sealing is read as it was and sealed once;
    /// later a damaged record costs only itself, kept in quarantine.
    func testAPlaintextJournalIsMigratedOnceAndADamagedRecordIsQuarantined() throws {
        let file = try temporaryFile()
        let device = UUID()
        var clock = HybridLogicalClock(deviceID: device)
        let events = (0..<3).map { index in
            JournalMutation(collection: collection, recordKey: RecordKey(rawValue: "r\(index)")!,
                            operation: .put, value: .string("title \(index)"), timestamp: clock.tick())
        }
        try JSONEncoder().encode(JournalSnapshot(clock: clock, events: events)).write(to: file)
        XCTAssertNotNil(try Data(contentsOf: file).range(of: Data("title 1".utf8)), "plaintext before")

        let migrated = try OfflineMutationJournal(fileURL: file, sealer: testAtRestSealer, deviceID: device)
        XCTAssertEqual(migrated.events().count, 3)
        XCTAssertNil(try Data(contentsOf: file).range(of: Data("title".utf8)), "sealed in place")

        // Damage one sealed record on disk.
        var stored = try JSONDecoder().decode(SealedJournalFile.Stored.self, from: Data(contentsOf: file))
        stored.events[1][stored.events[1].count - 3] ^= 0xFF
        try JSONEncoder().encode(stored).write(to: file)

        let salvaged = try OfflineMutationJournal(fileURL: file, sealer: testAtRestSealer, deviceID: device)
        XCTAssertEqual(salvaged.events().count, 2, "only the damaged record is set aside")
        let quarantine = file.deletingLastPathComponent().appendingPathComponent("quarantine")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count, 1)
        // New edits still go in, ahead of everything kept.
        let next = try salvaged.appendPut(collection: collection, key: RecordKey(rawValue: "r3")!, value: .string("new"))
        XCTAssertTrue(salvaged.events().filter { $0.id != next.id }.allSatisfy { $0.timestamp < next.timestamp })
    }

    /// A key that can't be read now (locked store) is not damage: opening
    /// fails, and nothing is quarantined or rewritten.
    func testAnUnreadableKeyLeavesTheJournalUntouched() throws {
        let file = try temporaryFile()
        let vault = SwitchableVault()
        let keyring = AtRestKeyring(vault: vault)
        let journal = try OfflineMutationJournal(fileURL: file, sealer: keyring.sealer(profile: nil, purpose: "journal"))
        try journal.appendPut(collection: collection, key: RecordKey(rawValue: "a")!, value: .string("x"))
        let before = try Data(contentsOf: file)

        vault.locked = true
        let lockedKeyring = AtRestKeyring(vault: vault)   // a fresh process: no cached key
        XCTAssertThrowsError(try OfflineMutationJournal(fileURL: file,
                                                        sealer: lockedKeyring.sealer(profile: nil, purpose: "journal")))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: file.deletingLastPathComponent().appendingPathComponent("quarantine").path))

        vault.locked = false
        XCTAssertEqual(try OfflineMutationJournal(fileURL: file, sealer: AtRestKeyring(vault: vault)
            .sealer(profile: nil, purpose: "journal")).events().count, 1)
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SealedJournal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("journal.json")
    }
}

/// A credential vault that can be locked, refusing reads as a locked
/// keychain does.
final class SwitchableVault: CredentialDataVault {
    private struct State {
        var items: [String: SecureBytes] = [:]
        var locked = false
    }
    private let state = Mutex(State())
    struct Locked: Error {}

    var locked: Bool {
        get { state.withLock { $0.locked } }
        set { state.withLock { $0.locked = newValue } }
    }

    func load(account: String) throws -> SecureBytes? {
        try state.withLock { state in
            if state.locked { throw Locked() }
            return state.items[account]
        }
    }

    func save(_ secret: SecureBytes, account: String) throws {
        try state.withLock { state in
            if state.locked { throw Locked() }
            state.items[account] = secret
        }
    }

    func delete(account: String) throws { _ = state.withLock { $0.items.removeValue(forKey: account) } }
}
