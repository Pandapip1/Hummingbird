import Foundation
import os
import Synchronization

/// A file's data-protection class: when its contents can be read.
public enum AppSyncFileProtection: String, Codable, Sendable, CaseIterable {
    /// Readable only while the device is unlocked.
    case complete
    /// Can be created and, once open, written and read while locked; closed,
    /// readable only while unlocked.
    case completeUnlessOpen
    /// Readable after the first unlock since boot.
    case completeUntilFirstUserAuthentication
    /// Always readable.
    case unprotected
}

/// What the host platform says about data protection. ATAppSync never asks
/// the platform itself; the application supplies this (Hummingbird wires it
/// from SwiftOpenUI). Platforms without data protection use
/// `UnprotectedDataAvailability`.
public protocol ProtectedDataAvailability: Sendable {
    /// Whether files protected until unlock can be read and written now.
    var isProtectedDataAvailable: Bool { get }
    /// Calls `handler` whenever availability changes, from any thread.
    func observeProtectedDataAvailability(_ handler: @escaping @Sendable (Bool) -> Void)
    /// Sets a file's protection class.
    func setProtection(_ protection: AppSyncFileProtection, for url: URL) throws
    /// A file's protection class, when the platform has one.
    func protection(of url: URL) -> AppSyncFileProtection?
}

/// No data protection: always available; protection classes are not kept.
public struct UnprotectedDataAvailability: ProtectedDataAvailability {
    public init() {}
    public var isProtectedDataAvailable: Bool { true }
    public func observeProtectedDataAvailability(_ handler: @escaping @Sendable (Bool) -> Void) {}
    public func setProtection(_ protection: AppSyncFileProtection, for url: URL) throws {}
    public func protection(of url: URL) -> AppSyncFileProtection? { nil }
}

/// One queued write: the latest value for `key`, or that key's queued
/// values being done with (`cleared`).
public struct PendingWrite: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case value, cleared }

    /// Increases with every append, also across relaunches.
    public let sequence: UInt64
    public let key: String
    public let kind: Kind
    /// The value (`.value`); nil for `.cleared`.
    public let payload: Data?
    /// For `.cleared`: values of `key` up to this sequence are done with.
    public let through: UInt64?
}

/// A durable, append-only queue of writes for stores that can't take them
/// now: the device is locked and their files are protected until unlock, or
/// the process may die before a slower write lands. Each append is one line
/// written through a handle opened at launch and kept open, then fsync'd,
/// so it works while the device is locked (the file's class is
/// `completeUnlessOpen`: unreadable at rest once closed while locked) and
/// survives a crash or the app being killed. A partly written last line
/// (a crash mid-append) is ignored.
///
/// Readers get the latest uncleared value per key (`latest`, `pending`).
/// `apply` hands the pending values, in the order they were queued, to the
/// store that owns them, once protected data is available; each key is
/// cleared as its value lands, so applying again after a crash repeats
/// nothing that already landed. The file is compacted only while protected
/// data is available; while locked, clearing appends a marker instead.
public final class PendingWriteQueue: Sendable {
    public let fileURL: URL
    private let availability: any ProtectedDataAvailability
    private let state: Mutex<State>
    private static let log = Logger(subsystem: "com.eightybps.appsync", category: "pending-writes")

    private struct State {
        var handle: FileHandle?
        var records: [PendingWrite]
        var nextSequence: UInt64
    }

    /// Opens (or creates) the queue at `fileURL` with protection
    /// `completeUnlessOpen`, and keeps it open. Call while protected data is
    /// available (at launch) so it stays usable while locked.
    public init(fileURL: URL, availability: any ProtectedDataAvailability) {
        self.fileURL = fileURL
        self.availability = availability
        var records: [PendingWrite] = []
        var handle: FileHandle?
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try availability.setProtection(.completeUnlessOpen, for: fileURL)
            let opened = try FileHandle(forUpdating: fileURL)
            let contents = try opened.readToEnd() ?? Data()
            // A crash mid-append leaves a partial last line; drop it so the
            // next append starts on a line of its own.
            if let last = contents.last, last != 0x0A {
                let end = contents.lastIndex(of: 0x0A).map { $0 + 1 } ?? contents.startIndex
                try opened.truncate(atOffset: UInt64(end - contents.startIndex))
                records = Self.decode(contents[contents.startIndex..<end])
            } else {
                records = Self.decode(contents)
            }
            try opened.seekToEnd()
            handle = opened
        } catch {
            Self.log.error("pending_queue_open_failed error=\(String(describing: error), privacy: .public)")
        }
        state = Mutex(State(handle: handle, records: records,
                            nextSequence: (records.map(\.sequence).max() ?? 0) + 1))
    }

    /// Queues `payload` as the latest value for `key`, durably, and returns
    /// its sequence. Throws only if it could not be made durable; the caller
    /// must then report the write as lost.
    @discardableResult
    public func append(key: String, payload: Data) throws -> UInt64 {
        try append { sequence in
            PendingWrite(sequence: sequence, key: key, kind: .value, payload: payload, through: nil)
        }
    }

    /// Marks `key`'s values up to `sequence` done with. Values queued later
    /// stay pending.
    public func clear(key: String, through sequence: UInt64) throws {
        // Nothing to do unless a value up to `sequence` is still pending.
        guard state.withLock({ state in
            Self.pendingUnlocked(state.records).contains { $0.key == key && $0.sequence <= sequence }
        }) else { return }
        _ = try append { next in
            PendingWrite(sequence: next, key: key, kind: .cleared, payload: nil, through: sequence)
        }
        compactIfAvailable()
    }

    /// The latest pending value for `key`, with its sequence.
    public func latest(key: String) -> (sequence: UInt64, payload: Data)? {
        state.withLock { state in
            guard let write = Self.pendingUnlocked(state.records).last(where: { $0.key == key }),
                  let payload = write.payload else { return nil }
            return (write.sequence, payload)
        }
    }

    /// Every key's latest pending value, in the order they were queued.
    public func pending(keyPrefix: String = "") -> [PendingWrite] {
        state.withLock { Self.pendingUnlocked($0.records).filter { $0.key.hasPrefix(keyPrefix) } }
    }

    /// Hands each pending value under `keyPrefix` to `store`, in queue order,
    /// while protected data is available; clears each that `store` reports
    /// as written. Returns how many landed.
    @discardableResult
    public func apply(keyPrefix: String = "", to store: (PendingWrite) -> Bool) -> Int {
        guard availability.isProtectedDataAvailable else { return 0 }
        var landed = 0
        for write in pending(keyPrefix: keyPrefix) where store(write) {
            do {
                try clear(key: write.key, through: write.sequence)
                landed += 1
            } catch {
                Self.log.error("pending_queue_clear_failed error=\(String(describing: error), privacy: .public)")
            }
        }
        return landed
    }

    private func append(_ make: (UInt64) -> PendingWrite) throws -> UInt64 {
        try state.withLock { state in
            guard let handle = state.handle else { throw CocoaError(.fileWriteNoPermission) }
            let write = make(state.nextSequence)
            var line = try JSONEncoder().encode(write)
            line.append(0x0A)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            state.records.append(write)
            state.nextSequence += 1
            return write.sequence
        }
    }

    /// Rewrites the file with only what is still pending, through the open
    /// handle. Only while protected data is available, so a rewrite is never
    /// what a locked device has to survive.
    private func compactIfAvailable() {
        guard availability.isProtectedDataAvailable else { return }
        state.withLock { state in
            guard let handle = state.handle else { return }
            let kept = Self.pendingUnlocked(state.records)
            guard kept.count < state.records.count else { return }
            do {
                var data = Data()
                for write in kept {
                    data.append(try JSONEncoder().encode(write))
                    data.append(0x0A)
                }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                state.records = kept
            } catch {
                Self.log.error("pending_queue_compact_failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The latest value per key that no later marker cleared, in queue order.
    private static func pendingUnlocked(_ records: [PendingWrite]) -> [PendingWrite] {
        var latest: [String: PendingWrite] = [:]
        var cleared: [String: UInt64] = [:]
        for write in records {
            switch write.kind {
            case .value: latest[write.key] = write
            case .cleared: cleared[write.key] = max(cleared[write.key] ?? 0, write.through ?? 0)
            }
        }
        return latest.values
            .filter { $0.sequence > (cleared[$0.key] ?? 0) }
            .sorted { $0.sequence < $1.sequence }
    }

    private static func decode(_ data: Data) -> [PendingWrite] {
        data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(PendingWrite.self, from: Data($0)) }
    }
}
