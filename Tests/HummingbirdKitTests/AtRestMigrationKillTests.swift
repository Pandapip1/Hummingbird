import ATAppSync
import ATProtoKit
import Foundation
import PlatformSupport
import XCTest
@testable import HummingbirdKit

/// The one-time at-rest migration (plaintext sealed in place) stopped at
/// every point: a full disk or a kill part way through any write leaves data
/// that still reads back whole, and the next launch finishes the job.
final class AtRestMigrationKillTests: XCTestCase {
    /// The journal is resealed by one atomic write. Stopped after any number
    /// of bytes, the plaintext journal is still there, byte for byte, and
    /// opens; a launch with room seals it.
    func testAJournalMigrationStoppedAtAnyByteLosesNothing() throws {
        let directory = makeTestDirectory("AtRestKill")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("journal.json")
        let device = UUID()
        var clock = HybridLogicalClock(deviceID: device)
        let events = (0..<3).map { index in
            JournalMutation(collection: HummingbirdProfileSchema.history, recordKey: RecordKey(rawValue: "r\(index)")!,
                            operation: .put, value: .string("title \(index)"), timestamp: clock.tick())
        }
        let legacy = try JSONEncoder().encode(JournalSnapshot(clock: clock, events: events))
        try legacy.write(to: file)

        for budget in stride(from: 0, through: 4_096, by: 97) {
            let opened = try AtomicFile.$simulatedSpace.withValue(.init(bytes: budget)) {
                try AppSyncMutationLog(fileURL: file, sealer: testAtRestSealer, deviceID: device)
            }
            XCTAssertEqual(opened.events().count, 3, "readable even when it couldn't be sealed (budget \(budget))")
            let onDisk = try Data(contentsOf: file)
            if onDisk != legacy {
                XCTAssertNil(onDisk.range(of: Data("title".utf8)), "either the old file whole or the sealed one")
                break
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["journal.json"])
        }
        let migrated = try AppSyncMutationLog(fileURL: file, sealer: testAtRestSealer, deviceID: device)
        XCTAssertEqual(migrated.events().map(\.value), events.map(\.value))
        XCTAssertNil(try Data(contentsOf: file).range(of: Data("title".utf8)), "sealed")
    }

    /// A legacy JSON value is copied into the database, sealed, and only
    /// then removed. Killed between the two, both are there: the next launch
    /// reads the same value and finishes, and a newer value saved first wins.
    func testALegacyValueKilledBetweenCopyAndRemovalIsReadOnce() throws {
        let directory = makeTestDirectory("AtRestKill")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("history.json")
        let database = directory.appendingPathComponent("storage.sqlite3")
        try JSONEncoder().encode(["old"]).write(to: legacy)
        // The state a kill after the copy leaves: sealed in the database, file still there.
        XCTAssertTrue(StorageDatabase(url: database, protectedData: UnprotectedDataAvailability(), atRest: testAtRestKeyring)
            .save(Data(#"["old"]"#.utf8), name: "history"))

        let backend = StorageBackend(directory: directory, queue: nil, protectedData: UnprotectedDataAvailability(),
                                     atRest: testAtRestKeyring)
        XCTAssertEqual(backend.load([String].self, name: "history"), ["old"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "finished: the file goes")
        backend.save(["new"], name: "history")
        XCTAssertEqual(StorageBackend(directory: directory, queue: nil, protectedData: UnprotectedDataAvailability(),
                                      atRest: testAtRestKeyring).load([String].self, name: "history"), ["new"])
    }

    /// A value that doesn't open moves to quarantine in one transaction:
    /// after it, the value is in exactly one place.
    func testAQuarantinedValueIsInExactlyOnePlace() throws {
        let directory = makeTestDirectory("AtRestKill")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("storage.sqlite3")
        XCTAssertTrue(StorageDatabase(url: file, protectedData: UnprotectedDataAvailability(), atRest: .ephemeral())
            .save(Data("other key".utf8), name: "history"))
        let database = StorageDatabase(url: file, protectedData: UnprotectedDataAvailability(), atRest: testAtRestKeyring)
        XCTAssertNil(database.load(name: "history"))
        XCTAssertNil(database.load(name: "history"), "gone from the table")
        XCTAssertEqual(database.quarantinedCount(name: "history"), 1, "kept once")
    }
}
