import Foundation
import PlatformSupport
import XCTest
@testable import HummingbirdKit

/// The synced cache moved out of Caches (which the system empties when
/// storage runs low): an existing one is moved, never rebuilt.
@MainActor
final class SyncedCacheTests: XCTestCase {
    func testAnExistingCacheInCachesIsMovedNotRebuilt() throws {
        let root = makeTestDirectory("SyncedCacheMove")
        let old = root.appendingPathComponent("Caches/SyncedCache/profile", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old frames".utf8).write(to: old.appendingPathComponent("cache-1-a.frames"))
        try Data("old other".utf8).write(to: old.appendingPathComponent("cache-2-b.frames"))
        let kept = KeptDirectory(named: "SyncedCache/profile", inDataDirectory: root.appendingPathComponent("Data"))
        // Already written in the new place: kept as it is.
        try Data("new frames".utf8).write(to: kept.url.appendingPathComponent("cache-2-b.frames"))

        SyncedCache.moveFromCaches(old, to: kept)

        XCTAssertEqual(try Data(contentsOf: kept.url.appendingPathComponent("cache-1-a.frames")), Data("old frames".utf8))
        XCTAssertEqual(try Data(contentsOf: kept.url.appendingPathComponent("cache-2-b.frames")), Data("new frames".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("cache-1-a.frames").path))

        // Nothing left to move: the old folder stays only for what wasn't moved.
        SyncedCache.moveFromCaches(old, to: kept)
        XCTAssertEqual(try Data(contentsOf: kept.url.appendingPathComponent("cache-1-a.frames")), Data("old frames".utf8))
    }
}
