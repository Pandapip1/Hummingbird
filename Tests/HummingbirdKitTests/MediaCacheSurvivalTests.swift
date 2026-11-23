import Foundation
import PlatformSupport
import XCTest
@testable import HummingbirdKit

/// "The video playback cache seems to disappear." Losing the cache is
/// expensive: only a full disk may evict other entries, unreadable metadata
/// never throws bytes away, and the cache never lives where the system
/// purges files (Caches).
final class MediaCacheSurvivalTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func completeTrack(_ cache: MediaCache, _ identity: String, bytes: Int) async throws {
        let id = try await cache.open(identity: identity)
        try await cache.setTotalBytes(id, Int64(bytes))
        try await cache.write(Data(repeating: 7, count: bytes), at: 0, to: id)
        await cache.close(id)
    }

    private func survivors(_ cache: MediaCache) async -> Set<String> {
        Set(await cache.completeClosedTracks().map(\.identity))
    }

    /// A write that fails for any reason but a full disk (a handle a
    /// suspension invalidated) used to evict other tracks on every retry,
    /// draining the cache. Now the track is reopened and nothing else goes.
    func testAFailedWriteThatIsNotAFullDiskEvictsNothing() async throws {
        let cache = MediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: directory()))
        try await completeTrack(cache, "kept-one", bytes: 64 * 1024)
        try await completeTrack(cache, "kept-two", bytes: 64 * 1024)
        let playing = try await cache.open(identity: "playing")
        try await cache.write(Data(repeating: 1, count: 1024), at: 0, to: playing)

        await cache.invalidateHandleForTesting(playing)
        let ranges = try await cache.writeMakingRoom(Data(repeating: 2, count: 32 * 1024), at: 1024, to: playing)

        XCTAssertTrue(ranges.contains(0..<(33 * 1024)), "the write went through after reopening")
        let kept = await survivors(cache)
        XCTAssertEqual(kept, ["kept-one", "kept-two"], "no other track was evicted")
        await cache.close(playing)
    }

    func testMetadataThatDoesNotDecodeKeepsTheTracksBytes() async throws {
        let parent = directory()
        let cache = MediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: parent))
        try await completeTrack(cache, "salvaged", bytes: 4096)
        let root = parent.appendingPathComponent("Media/\(MediaCache.directoryName)")
        let json = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        // One field no longer decodes (a format change, a damaged write).
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        object["lastAccess"] = "not a date"
        try JSONSerialization.data(withJSONObject: object).write(to: json)

        let id = try await cache.open(identity: "salvaged")
        let completed = await cache.completed(id)
        XCTAssertTrue(completed.contains(0..<4096), "the ranges were salvaged, not reset")
        await cache.close(id)

        // Nothing readable at all: set aside, and the media file is not truncated.
        try Data("{garbage".utf8).write(to: json)
        let media = json.deletingPathExtension().appendingPathExtension("media")
        let reopened = try await cache.open(identity: "salvaged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.appendingPathExtension("unreadable").path))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: media.path)[.size] as? Int)
        XCTAssertEqual(size, 4096, "the bytes are still there")
        await cache.close(reopened)
    }

    func testAnUnreadableEntryIsNotEvictedFirst() async throws {
        let parent = directory()
        let cache = MediaCache(directory: KeptDirectory(named: "Media", inDataDirectory: parent),
                               limitBytes: 300 * 1024 * 1024)
        try await completeTrack(cache, "older", bytes: 8 * 1024)
        try await Task.sleep(for: .milliseconds(50))
        try await completeTrack(cache, "newer-unreadable", bytes: 8 * 1024)
        let root = parent.appendingPathComponent("Media/\(MediaCache.directoryName)")
        let unreadable = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .first { (try? JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any])?["identity"] as? String == "newer-unreadable" })
        try Data("{garbage".utf8).write(to: unreadable)

        // One entry has to go: the least recently used readable one, not the unreadable one.
        let playing = try await cache.open(identity: "playing")
        await cache.evictForTesting(freeing: 1)
        let kept = await survivors(cache)
        XCTAssertFalse(kept.contains("older"), "the least recently used entry went")
        let mediaFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "media" }
        XCTAssertEqual(mediaFiles.count, 2, "the unreadable entry and the open one stay")
        await cache.close(playing)
    }

    /// The cache used to live in Caches, which iOS empties when storage runs low.
    func testTheMediaCacheLivesWithTheDataAndAnOldOneIsMoved() throws {
        let root = directory()
        let data = root.appendingPathComponent("Application Support", isDirectory: true)
        let caches = root.appendingPathComponent("Caches", isDirectory: true)
        let old = caches.appendingPathComponent(MediaCache.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 1000).write(to: old.appendingPathComponent("entry.media"))

        let stores = AppDataStores(dataDirectory: data, cachesDirectory: caches, preferences: makeTestPreferences(in: root),
                                   credentialStore: TestCredentialStore(), storage: .inMemory())
        XCTAssertTrue(stores.mediaDirectory.url.path.hasPrefix(data.path), "with the app's data")
        XCTAssertFalse(stores.mediaDirectory.url.path.hasPrefix(caches.path), "never in Caches")
        let moved = stores.mediaDirectory.url.appendingPathComponent("\(MediaCache.directoryName)/entry.media")
        XCTAssertEqual(try Data(contentsOf: moved).count, 1000, "moved, not downloaded again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        #if canImport(Darwin)
        let excluded = try stores.mediaDirectory.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "not backed up")
        #endif
    }

    /// Nothing builds a media cache from a URL: the caches take a
    /// `KeptDirectory` (a compile error otherwise), and the only kept
    /// directory the app makes is inside its data directory.
    func testNoMediaCacheIsPlacedInCaches() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("KeptDirectory(named:") {
                XCTAssertTrue(line.contains("inDataDirectory: dataDirectory"),
                              "\(file.lastPathComponent): a kept directory belongs in the data directory: \(line)")
            }
        }
    }
}
