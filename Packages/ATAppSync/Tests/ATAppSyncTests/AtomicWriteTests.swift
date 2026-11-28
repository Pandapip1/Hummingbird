import ATProtoKit
import Foundation
import PlatformSupport
import XCTest
@testable import ATAppSync

/// Writes that run out of space part way (`AtomicFile.SimulatedSpace`, a
/// disk that fills mid-write) leave the previous state readable, and the
/// next write that fits lands on top of it as if the failed one never
/// happened.
final class AtomicWriteTests: XCTestCase {
    private let collection = NSID(rawValue: "com.example.history")!

    func testAWholeFileWriteThatRunsOutOfSpaceLeavesThePreviousVersion() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("state.json")
        try AtomicFile.write(Data("version one".utf8), to: file)
        for budget in [0, 1, 6, 4_000] {
            AtomicFile.$simulatedSpace.withValue(.init(bytes: budget)) {
                XCTAssertThrowsError(try AtomicFile.write(Data(repeating: 2, count: 8_000), to: file)) { error in
                    XCTAssertEqual((error as? POSIXError)?.code, .ENOSPC)
                }
            }
            XCTAssertEqual(try Data(contentsOf: file), Data("version one".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["state.json"],
                           "no temporary file left behind")
        }
        try AtomicFile.write(Data("version two".utf8), to: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("version two".utf8))
    }

    func testAStreamThatFailsLeavesThePreviousVersion() throws {
        let file = try temporaryDirectory().appendingPathComponent("export.json")
        try AtomicFile.write(Data("previous".utf8), to: file)
        struct Stop: Error {}
        XCTAssertThrowsError(try AtomicFile.write(to: file) { stream in
            try stream.append(Data("half of the ".utf8))
            throw Stop()
        })
        XCTAssertEqual(try Data(contentsOf: file), Data("previous".utf8))
        try AtomicFile.write(to: file) { stream in
            try stream.append(Data("new ".utf8))
            try stream.append(Data("version".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("new version".utf8))
    }

    func testAnAppendThatRunsOutOfSpaceIsCutBackOff() throws {
        let file = try temporaryDirectory().appendingPathComponent("log")
        let log = try AppendLog(url: file)
        try log.append(Data("first\n".utf8))
        AtomicFile.$simulatedSpace.withValue(.init(bytes: 5)) {
            XCTAssertThrowsError(try log.append(Data("second, torn by a full disk\n".utf8)))
        }
        XCTAssertEqual(try log.contents(), Data("first\n".utf8), "the torn part is gone at once")
        try log.append(Data("third\n".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("first\nthird\n".utf8))
    }

    func testAMoveNeverReplacesWhenAskedNotTo() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("new")
        let destination = directory.appendingPathComponent("kept")
        try AtomicFile.write(Data("new".utf8), to: source)
        try AtomicFile.write(Data("kept".utf8), to: destination)
        XCTAssertThrowsError(try AtomicFile.move(source, to: destination, replacing: false))
        XCTAssertEqual(try Data(contentsOf: destination), Data("kept".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("new".utf8))
        try AtomicFile.move(source, to: destination, replacing: true)
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    /// A file that is there but can't be read is never taken for an empty
    /// one (and then written over).
    func testAnUnreadableFileIsNotAMissingOne() throws {
        let directory = try temporaryDirectory()
        XCTAssertNil(try AtomicFile.contents(of: directory.appendingPathComponent("missing")))
        let file = directory.appendingPathComponent("journal.json")
        let journal = try OfflineMutationJournal(fileURL: file, sealer: testAtRestSealer)
        try journal.appendPut(collection: collection, key: RecordKey(rawValue: "a")!, value: .string("kept"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try OfflineMutationJournal(fileURL: file, sealer: testAtRestSealer))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try OfflineMutationJournal(fileURL: file, sealer: testAtRestSealer).events().count, 1)
    }

    func testTheQueueKeepsEveryAppendItReportedDurable() throws {
        let file = try temporaryDirectory().appendingPathComponent("pending-writes.queue")
        let queue = PendingWriteQueue(fileURL: file, availability: FakeDevice(unlocked: false), sealer: testAtRestSealer)
        try queue.append(key: "before", payload: Data("kept".utf8))
        AtomicFile.$simulatedSpace.withValue(.init(bytes: 40)) {
            XCTAssertThrowsError(try queue.append(key: "torn", payload: Data(repeating: 7, count: 4_096)))
        }
        try queue.append(key: "after", payload: Data("also kept".utf8))

        let reopened = PendingWriteQueue(fileURL: file, availability: FakeDevice(unlocked: false), sealer: testAtRestSealer)
        XCTAssertEqual(reopened.pending().map(\.key), ["before", "after"])
        XCTAssertEqual(reopened.latest(key: "after")?.payload, Data("also kept".utf8))
    }

    func testTheJournalKeepsItsLastGoodState() throws {
        let file = try temporaryDirectory().appendingPathComponent("journal.json")
        let journal = try OfflineMutationJournal(fileURL: file, sealer: testAtRestSealer)
        try journal.appendPut(collection: collection, key: RecordKey(rawValue: "a")!, value: .string("kept"))
        let before = try Data(contentsOf: file)
        AtomicFile.$simulatedSpace.withValue(.init(bytes: 100)) {
            XCTAssertThrowsError(try journal.appendPut(collection: collection, key: RecordKey(rawValue: "b")!,
                                                       value: .string(String(repeating: "x", count: 4_096))))
        }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try OfflineMutationJournal(fileURL: file, sealer: testAtRestSealer).events().count, 1)
    }

    func testTheSyncedCacheKeepsWhatItPersisted() throws {
        let root = try temporaryDirectory()
        let kept = KeptDirectory(named: "SyncedCache", inDataDirectory: root)
        let vault = MemoryVault()
        let profile = UUID()
        let instance = AppSyncPeerID(signingKey: Data([42]))
        let context = CacheFetchContext(sourceVersion: "1", locale: "en-GB")
        let viewer = CacheViewer(contexts: ["yt": context])
        func key(_ url: String) -> CacheEntityKey { CacheEntityKey(kind: "video", source: "yt", url: url) }
        func open() -> CacheJournal {
            CacheJournal(directory: kept, profileID: profile, instance: instance, credentialStore: vault,
                         availability: FakeDevice(unlocked: true))
        }
        let cache = open()
        cache.put(key("before"), context: context, payload: Data("kept".utf8))
        cache.persist()
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: kept.url, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "frames" })
        let persisted = try Data(contentsOf: file)

        // Random bytes: they don't compress, so the frames are bigger than the space left.
        let payloads = (0..<8).map { _ in Data((0..<2_048).map { _ in UInt8.random(in: 0...255) }) }
        AtomicFile.$simulatedSpace.withValue(.init(bytes: 600)) {
            for (index, payload) in payloads.enumerated() {
                cache.put(key("torn-\(index)"), context: context, payload: payload)
            }
            cache.persist()
        }
        XCTAssertEqual(try Data(contentsOf: file), persisted, "the failed append is cut back off")

        cache.put(key("after"), context: context, payload: Data("also kept".utf8))
        cache.persist()
        let reopened = open()
        XCTAssertEqual(reopened.entity(key("before"), for: viewer)?.payload, Data("kept".utf8))
        XCTAssertEqual(reopened.entity(key("torn-7"), for: viewer)?.payload, payloads[7],
                       "what failed stayed pending and landed with the next write")
        XCTAssertEqual(reopened.entity(key("after"), for: viewer)?.payload, Data("also kept".utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
