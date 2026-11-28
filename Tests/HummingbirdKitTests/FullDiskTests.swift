#if os(macOS)
import ATAppSync
import Foundation
import XCTest
@testable import HummingbirdKit

/// The app's stores on a disk that really runs out of space: a small APFS
/// disk image, filled until writes fail part way, then given space back.
/// Whatever a store had made durable before must still read back after,
/// and whatever it reports durable after must too.
final class FullDiskTests: XCTestCase {
    /// A write torn by a full disk must not take the next, successful,
    /// append down with it.
    func testTheWriteQueueKeepsEveryAppendItReportedDurable() throws {
        let volume = try FullDiskVolume(test: self)
        let file = volume.url.appendingPathComponent("pending-writes.queue")
        let queue = PendingWriteQueue(fileURL: file, availability: UnprotectedDataAvailability(), sealer: testAtRestSealer)
        try queue.append(key: "before", payload: Data("kept".utf8))

        try volume.fill(leaving: 8 * 1_024)
        XCTAssertThrowsError(try queue.append(key: "torn", payload: Data(repeating: 7, count: 256 * 1_024)))
        try volume.release()
        try queue.append(key: "after", payload: Data("also kept".utf8))

        let reopened = PendingWriteQueue(fileURL: file, availability: UnprotectedDataAvailability(), sealer: testAtRestSealer)
        XCTAssertEqual(reopened.pending().map(\.key), ["before", "after"])
        XCTAssertEqual(reopened.latest(key: "after")?.payload, Data("also kept".utf8))
    }

    func testTheProfileJournalKeepsItsLastGoodState() throws {
        let volume = try FullDiskVolume(test: self)
        let file = volume.url.appendingPathComponent("journal.json")
        let collection = HummingbirdProfileSchema.history
        let journal = try AppSyncMutationLog(fileURL: file, sealer: testAtRestSealer)
        try journal.appendPut(collection: collection, key: RecordKey(rawValue: "a")!, value: .string("kept"))

        try volume.fill(leaving: 8 * 1_024)
        XCTAssertThrowsError(try journal.appendPut(collection: collection, key: RecordKey(rawValue: "b")!,
                                                   value: .string(String(repeating: "x", count: 256 * 1_024))))
        try volume.release()

        let reopened = try AppSyncMutationLog(fileURL: file, sealer: testAtRestSealer)
        XCTAssertEqual(reopened.events().map(\.recordKey.rawValue), ["a"])
        try reopened.appendPut(collection: collection, key: RecordKey(rawValue: "c")!, value: .string("after"))
        XCTAssertEqual(try AppSyncMutationLog(fileURL: file, sealer: testAtRestSealer).events().count, 2)
    }

    func testTheLibraryDatabaseKeepsItsLastGoodValue() async throws {
        let volume = try FullDiskVolume(test: self)
        let device = LockableDevice(unlocked: true)
        let storage = Storage(directory: volume.url, protectedData: device, atRest: testAtRestKeyring)
        storage.save(["kept"], name: "history")
        await storage.flush()

        try volume.fill(leaving: 8 * 1_024)
        storage.save([String(repeating: "x", count: 512 * 1_024)], name: "history")
        storage.save([String(repeating: "y", count: 512 * 1_024)], name: "playlists")
        await storage.flush()
        try volume.release()
        storage.save(["after"], name: "subscriptions")
        await storage.flush()

        let reopened = Storage(directory: volume.url, protectedData: device, atRest: testAtRestKeyring)
        await reopened.flush()
        let history = reopened.load([String].self, name: "history")
        XCTAssertNotNil(history, "the last good value or the new one, never nothing")
        XCTAssertEqual(reopened.load([String].self, name: "subscriptions"), ["after"])
    }

    func testTheMediaCacheNeverClaimsBytesItDoesNotHave() async throws {
        let volume = try FullDiskVolume(test: self)
        let kept = KeptDirectory(named: "Media", inDataDirectory: volume.url)
        let cache = MediaCache(directory: kept)
        let track = try await cache.open(identity: "track")
        let first = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
        try await cache.write(first, at: 0, to: track)

        try volume.fill(leaving: 8 * 1_024)
        do { try await cache.write(Data(repeating: 9, count: 1_024 * 1_024), at: 65_536, to: track) } catch {}
        try volume.release()
        await cache.close(track)

        let reopened = MediaCache(directory: kept)
        let again = try await reopened.open(identity: "track")
        let completed = await reopened.completed(again)
        for range in completed.ranges {
            let bytes = try await reopened.read(again, range: range)
            XCTAssertEqual(bytes?.count, range.count, "a range the cache claims must read back whole")
        }
        XCTAssertEqual(try await reopened.read(again, range: 0..<65_536), first)
    }

    func testTheSyncedCacheKeepsWhatItPersistedBefore() throws {
        let volume = try FullDiskVolume(test: self)
        let kept = KeptDirectory(named: "SyncedCache", inDataDirectory: volume.url)
        let vault = TestCredentialStore()
        let profile = UUID()
        let instance = AppSyncPeerID(signingKey: Data([42]))
        let context = CacheFetchContext(sourceVersion: "1", locale: "en-GB")
        let viewer = CacheViewer(contexts: ["yt": context])
        func key(_ url: String) -> CacheEntityKey { CacheEntityKey(kind: "video", source: "yt", url: url) }
        func open() -> CacheJournal {
            CacheJournal(directory: kept, profileID: profile, instance: instance, credentialStore: vault,
                         availability: UnprotectedDataAvailability())
        }
        let cache = open()
        cache.put(key("before"), context: context, payload: Data("kept".utf8))
        cache.persist()

        try volume.fill(leaving: 8 * 1_024)
        for index in 0..<64 {
            cache.put(key("torn-\(index)"), context: context, payload: Data(repeating: UInt8(index), count: 16 * 1_024))
        }
        cache.persist()
        try volume.release()
        cache.put(key("after"), context: context, payload: Data("also kept".utf8))
        cache.persist()

        let reopened = open()
        XCTAssertEqual(reopened.entity(key("before"), for: viewer)?.payload, Data("kept".utf8))
        XCTAssertEqual(reopened.entity(key("after"), for: viewer)?.payload, Data("also kept".utf8))
    }
}

/// A small APFS disk image mounted for one test, that can be filled until
/// writes fail and then given its space back.
final class FullDiskVolume {
    let url: URL
    private let image: URL
    private let filler: URL

    init(test: XCTestCase, megabytes: Int = 24) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullDisk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        image = root.appendingPathComponent("volume.dmg")
        url = root.appendingPathComponent("mount", isDirectory: true)
        filler = url.appendingPathComponent("filler", isDirectory: true)
        try Self.hdiutil(["create", "-quiet", "-size", "\(megabytes)m", "-fs", "APFS", "-volname", "HBFull", image.path])
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Self.hdiutil(["attach", "-quiet", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", url.path, image.path])
        let mounted = url
        test.addTeardownBlock {
            try? Self.hdiutil(["detach", "-quiet", "-force", mounted.path])
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: filler, withIntermediateDirectories: true)
    }

    /// Fills the volume so that about `bytes` stay free.
    func fill(leaving bytes: Int) throws {
        var index = 0
        for size in [1_048_576, 65_536, 4_096] {
            while (try? Data(count: size).write(to: filler.appendingPathComponent("\(index)"))) != nil { index += 1 }
            try? FileManager.default.removeItem(at: filler.appendingPathComponent("\(index)"))
        }
        var freed = 0
        while freed < bytes, index > 0 {
            index -= 1
            let file = filler.appendingPathComponent("\(index)")
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            try FileManager.default.removeItem(at: file)
            freed += size
        }
    }

    /// Gives all the filled space back.
    func release() throws {
        try FileManager.default.removeItem(at: filler)
        try FileManager.default.createDirectory(at: filler, withIntermediateDirectories: true)
    }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("hdiutil \(arguments.first ?? "") failed with status \(process.terminationStatus)")
        }
    }
}
#endif
