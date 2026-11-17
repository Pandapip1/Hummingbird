import Foundation
import Crypto
import os

/// Disk cache for downloaded VOD tracks.
///
/// Layout, under `<caches>/Media-v1/`:
///
///     <digest>.media   the track's bytes at their file offsets (a sparse file)
///     <digest>.json    `Metadata`: total size, which byte ranges are present,
///                      last use; rewritten atomically after each write
///
/// `<digest>` is the SHA-256 of the track's stable identity (plugin, content
/// URL and format, never the expiring upstream URL), so a track that was
/// partly downloaded resumes where it stopped, and one that was fully
/// downloaded plays without the network.
///
/// Everything stays cached until the cache is over its limit; then the least
/// recently used tracks that are not playing are removed. A track that is
/// playing is never removed, even when it alone exceeds the limit.
actor MediaCache {
    static let directoryName = "Media-v1"
    static let defaultLimitGigabytes = 10
    static let defaultLimitBytes = bytes(gigabytes: defaultLimitGigabytes)
    static func bytes(gigabytes: Int) -> Int64 { Int64(gigabytes) * 1_024 * 1_024 * 1_024 }

    struct TrackID: Hashable, Sendable {
        fileprivate let digest: String
    }

    private struct Metadata: Codable {
        var identity: String
        var totalBytes: Int64?
        var completed: MediaRangeSet
        var lastAccess: Date
    }

    private struct OpenTrack {
        var metadata: Metadata
        var handle: FileHandle
        var users: Int
    }

    private let parent: URL
    private var limitBytes: Int64
    private var openTracks: [String: OpenTrack] = [:]
    private let others: [any EvictableMediaStore]
    private var bytesSinceEviction: Int64 = 0

    /// `sharing` lists other stores whose entries count toward the same limit.
    init(directory parent: URL, limitBytes: Int64 = MediaCache.defaultLimitBytes,
         sharing others: [any EvictableMediaStore] = []) {
        self.parent = parent
        self.limitBytes = limitBytes
        self.others = others
    }

    func setLimit(_ bytes: Int64) async {
        limitBytes = max(bytes, 256 * 1_024 * 1_024)
        await evictIfNeeded()
    }

    var limit: Int64 { limitBytes }

    // MARK: tracks

    /// Opens (creating if needed) the cached track for `identity`. Every
    /// `open` is balanced by a `close`.
    func open(identity: String) throws -> TrackID {
        let digest = Self.digest(identity)
        let id = TrackID(digest: digest)
        if var track = openTracks[digest] {
            track.users += 1
            openTracks[digest] = track
            return id
        }
        let root = try root()
        let dataURL = root.appendingPathComponent("\(digest).media")
        let metadataURL = root.appendingPathComponent("\(digest).json")
        var metadata = (try? Data(contentsOf: metadataURL)).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
        if !FileManager.default.fileExists(atPath: dataURL.path) {
            guard FileManager.default.createFile(atPath: dataURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            metadata = nil
        }
        let handle = try FileHandle(forUpdating: dataURL)
        var resolved = metadata ?? Metadata(identity: identity, totalBytes: nil, completed: MediaRangeSet(), lastAccess: Date())
        resolved.lastAccess = Date()
        openTracks[digest] = OpenTrack(metadata: resolved, handle: handle, users: 1)
        try persist(digest)
        return id
    }

    func close(_ id: TrackID) {
        guard var track = openTracks[id.digest] else { return }
        track.users -= 1
        if track.users > 0 {
            openTracks[id.digest] = track
            return
        }
        try? persist(id.digest)
        try? track.handle.close()
        openTracks[id.digest] = nil
    }

    func completed(_ id: TrackID) -> MediaRangeSet { openTracks[id.digest]?.metadata.completed ?? MediaRangeSet() }
    func totalBytes(_ id: TrackID) -> Int64? { openTracks[id.digest]?.metadata.totalBytes }

    func setTotalBytes(_ id: TrackID, _ total: Int64) throws {
        guard var track = openTracks[id.digest], track.metadata.totalBytes != total else { return }
        track.metadata.totalBytes = total
        openTracks[id.digest] = track
        try persist(id.digest)
    }

    /// Stores `data` at `offset`. Returns the ranges now present.
    @discardableResult
    func write(_ data: Data, at offset: Int64, to id: TrackID) throws -> MediaRangeSet {
        guard !data.isEmpty, var track = openTracks[id.digest] else { return completed(id) }
        do {
            try track.handle.seek(toOffset: UInt64(offset))
            try track.handle.write(contentsOf: data)
        } catch {
            Logger.mediaCache.error("write_failed bytes=\(data.count) message=\(error.localizedDescription)")
            throw error
        }
        track.metadata.completed.insert(offset..<(offset + Int64(data.count)))
        track.metadata.lastAccess = Date()
        openTracks[id.digest] = track
        try persist(id.digest)
        bytesSinceEviction += Int64(data.count)
        if bytesSinceEviction >= 64 * 1_024 * 1_024 {
            bytesSinceEviction = 0
            Task { await self.evictIfNeeded() }
        }
        return track.metadata.completed
    }

    /// The bytes in `range`, or nil when any of them is missing.
    func read(_ id: TrackID, range: Range<Int64>) throws -> Data? {
        guard let track = openTracks[id.digest], track.metadata.completed.contains(range) else { return nil }
        try track.handle.seek(toOffset: UInt64(range.lowerBound))
        let data = try track.handle.read(upToCount: range.count) ?? Data()
        guard data.count == range.count else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    /// Whether a track is fully cached (open or not).
    func isComplete(identity: String) -> Bool {
        let digest = Self.digest(identity)
        let metadata = openTracks[digest]?.metadata ?? readMetadata(digest)
        guard let metadata, let total = metadata.totalBytes, total > 0 else { return false }
        return metadata.completed.contains(0..<total)
    }

    /// Fully cached tracks that are not open, with their size: what a later
    /// pipeline stage (transcoding) may consume.
    func completeClosedTracks() -> [(identity: String, bytes: Int64)] {
        guard let directory = try? root(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { url -> (String, Int64)? in
            guard url.pathExtension == "json" else { return nil }
            let digest = url.deletingPathExtension().lastPathComponent
            guard openTracks[digest] == nil, let metadata = readMetadata(digest), let total = metadata.totalBytes,
                  total > 0, metadata.completed.contains(0..<total) else { return nil }
            return (metadata.identity, total)
        }
    }

    /// The file holding a complete, closed track: its bytes at their offsets,
    /// i.e. the original file. Valid until the track is opened or removed.
    func fileOfCompleteTrack(identity: String) -> URL? {
        let digest = Self.digest(identity)
        guard openTracks[digest] == nil, isComplete(identity: identity), let directory = try? root() else { return nil }
        return directory.appendingPathComponent("\(digest).media")
    }

    /// Stores a finished file as a complete track (moving it into the cache).
    func importFile(_ file: URL, identity: String) throws {
        let digest = Self.digest(identity)
        guard openTracks[digest] == nil else { throw CocoaError(.fileWriteFileExists) }
        let directory = try root()
        let media = directory.appendingPathComponent("\(digest).media")
        try? FileManager.default.removeItem(at: media)
        try FileManager.default.moveItem(at: file, to: media)
        let size = (try? FileManager.default.attributesOfItem(atPath: media.path)[.size] as? NSNumber)?.int64Value ?? 0
        let metadata = Metadata(identity: identity, totalBytes: size, completed: MediaRangeSet([0..<size]), lastAccess: Date())
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("\(digest).json"), options: .atomic)
    }

    private func readMetadata(_ digest: String) -> Metadata? {
        guard let directory = try? root() else { return nil }
        return (try? Data(contentsOf: directory.appendingPathComponent("\(digest).json")))
            .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
    }

    /// Deletes a cached track that is not open (the downloads list's Remove).
    func remove(identity: String) {
        let digest = Self.digest(identity)
        guard openTracks[digest] == nil, let directory = try? root() else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(digest).media"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(digest).json"))
    }

    /// Forgets a track's contents, e.g. when upstream bytes turned out to
    /// belong to a different rendition.
    func reset(_ id: TrackID) throws {
        guard var track = openTracks[id.digest] else { return }
        try track.handle.truncate(atOffset: 0)
        track.metadata.completed = MediaRangeSet()
        track.metadata.totalBytes = nil
        openTracks[id.digest] = track
        try persist(id.digest)
    }

    // MARK: eviction

    /// Whether the cache holds more than its limit.
    func isOverLimit() async -> Bool { await usage() > limitBytes }

    /// Bytes used by every cached track and every other registered store.
    func usage() async -> Int64 {
        var total = (try? candidates().reduce(Int64(0)) { $0 + $1.bytes }) ?? 0
        for store in others { total += await store.evictionCandidates().reduce(0) { $0 + $1.bytes } }
        total += openTracks.values.reduce(0) { $0 + $1.metadata.completed.byteCount }
        return total
    }

    /// Removes least recently used entries that are not in use until the
    /// cache fits its limit.
    func evictIfNeeded() async {
        await evict(freeing: 0)
    }

    /// Removes least recently used entries not in use until the cache fits its
    /// limit and, beyond that, until `freeing` more bytes are released (a
    /// write that found the disk full).
    @discardableResult
    private func evict(freeing needed: Int64) async -> Int64 {
        struct Candidate { var bytes: Int64; var lastAccess: Date; var remove: () async -> Void }
        var all: [Candidate] = []
        let inUse = openTracks.values.reduce(Int64(0)) { $0 + $1.metadata.completed.byteCount }
        let directory = try? root()
        for candidate in (try? candidates()) ?? [] {
            all.append(Candidate(bytes: candidate.bytes, lastAccess: candidate.lastAccess) {
                guard let directory else { return }
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(candidate.id).media"))
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(candidate.id).json"))
            })
        }
        for store in others {
            for candidate in await store.evictionCandidates() {
                all.append(Candidate(bytes: candidate.bytes, lastAccess: candidate.lastAccess) {
                    await store.remove(candidate.id)
                })
            }
        }
        var total = inUse + all.reduce(0) { $0 + $1.bytes }
        let target = min(limitBytes, total - needed)
        var freed: Int64 = 0
        for candidate in all.sorted(by: { $0.lastAccess < $1.lastAccess }) where total > target {
            await candidate.remove()
            total -= candidate.bytes
            freed += candidate.bytes
            Logger.mediaCache.info("evicted bytes=\(candidate.bytes)")
        }
        return freed
    }

    /// Removes every entry not in use (Settings' Clear). Returns the bytes freed.
    @discardableResult
    func clearUnused() async -> Int64 {
        await evict(freeing: Int64.max / 4)
    }

    /// `write`, but a failed write (typically a full disk) first frees space by
    /// evicting other entries and tries again, so a download is never lost to
    /// space that the cache itself holds.
    @discardableResult
    func writeMakingRoom(_ data: Data, at offset: Int64, to id: TrackID) async throws -> MediaRangeSet {
        do {
            return try write(data, at: offset, to: id)
        } catch {
            let freed = await evict(freeing: Int64(data.count) * 4)
            Logger.mediaCache.notice("write_retry_after_eviction freed=\(freed)")
            return try write(data, at: offset, to: id)
        }
    }

    /// Closed entries on disk.
    private func candidates() throws -> [MediaCacheEvictionCandidate] {
        let root = try root()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileAllocatedSizeKey])
        return files.compactMap { url -> MediaCacheEvictionCandidate? in
            guard url.pathExtension == "json" else { return nil }
            let digest = url.deletingPathExtension().lastPathComponent
            guard openTracks[digest] == nil else { return nil }
            let metadata = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
            let media = root.appendingPathComponent("\(digest).media")
            let allocated = (try? media.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize).map(Int64.init)
            return MediaCacheEvictionCandidate(id: digest,
                                               bytes: allocated ?? metadata?.completed.byteCount ?? 0,
                                               lastAccess: metadata?.lastAccess ?? .distantPast)
        }
    }

    // MARK: files

    private func root() throws -> URL {
        let root = parent.appendingPathComponent(Self.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func persist(_ digest: String) throws {
        guard let track = openTracks[digest] else { return }
        let url = try root().appendingPathComponent("\(digest).json")
        try JSONEncoder().encode(track.metadata).write(to: url, options: .atomic)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct MediaCacheEvictionCandidate: Sendable {
    var id: String
    var bytes: Int64
    var lastAccess: Date
}

/// A store whose closed entries count toward the media cache limit.
protocol EvictableMediaStore: Actor {
    /// Entries not in use by this process, which may be removed.
    func evictionCandidates() -> [MediaCacheEvictionCandidate]
    func remove(_ id: String)
}

extension Logger {
    /// The VOD media cache and its downloads.
    static let mediaCache = Logger(subsystem: Diagnostics.subsystem, category: "media-cache")
}

extension OSSignposter {
    /// VOD downloads (`VODPiece`) and local serving (`VODServe`).
    static let mediaCache = OSSignposter(subsystem: Diagnostics.subsystem, category: "media-cache")
}
