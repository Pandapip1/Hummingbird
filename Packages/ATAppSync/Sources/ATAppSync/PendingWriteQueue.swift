import Foundation
import os
import PlatformSupport
import Synchronization

/// A file's data-protection class: when its contents can be read. Only the
/// classes app data may use: everything it keeps is read and written by
/// work done while the device is locked, and is sealed at rest
/// (`AtRestSealer`) rather than locked away by a stricter class.
public enum AppSyncFileProtection: String, Codable, Sendable, CaseIterable {
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
    /// A file's protection class: nil without data protection, or for a
    /// class app data never uses (a file from before at-rest sealing).
    func protection(of url: URL) -> AppSyncFileProtection?
}

extension ProtectedDataAvailability {
    /// Returns once protected data is available: at once if it is now,
    /// otherwise when the host reports the device unlocked.
    public func waitUntilAvailable() async {
        guard !isProtectedDataAvailable else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            observeProtectedDataAvailability { available in if available { once.resume() } }
            // It may have become available before the observer was added.
            if isProtectedDataAvailable { once.resume() }
        }
    }
}

/// Resumes a continuation the first time it is asked to; later asks do nothing.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume() {
        continuation.withLock { pending in
            defer { pending = nil }
            return pending
        }?.resume()
    }
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
/// appended through an `AppendLog` opened at launch and kept open, synced,
/// so it works while the device is locked (the file's class is
/// `completeUntilFirstUserAuthentication`; every value is sealed with the
/// device's at-rest key, so nothing in it is readable without that) and
/// survives a crash or the app being killed. An append that fails part way
/// (a full disk) is cut back off at once; a partly written last line left
/// by a crash is cut off when the queue is next opened.
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
    /// Every value is sealed at rest.
    private let sealer: AtRestSealer
    private let state: Mutex<State>
    private static let log = Logger(subsystem: "com.eightybps.appsync", category: "pending-writes")

    private struct State {
        var log: AppendLog?
        var records: [PendingWrite]
        var nextSequence: UInt64
    }

    /// Opens (or creates) the queue at `fileURL` with protection
    /// `completeUntilFirstUserAuthentication`, and keeps it open. Values are
    /// sealed with `sealer`; there is no way to queue one in the clear.
    public init(fileURL: URL, availability: any ProtectedDataAvailability, sealer: AtRestSealer) {
        self.fileURL = fileURL
        self.availability = availability
        self.sealer = sealer
        var records: [PendingWrite] = []
        var log: AppendLog?
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let opened = try AppendLog(url: fileURL, protection: .completeUntilFirstUserAuthentication)
            try availability.setProtection(.completeUntilFirstUserAuthentication, for: fileURL)
            let contents = try opened.contents()
            // A crash mid-append leaves a partial last line; drop it so the
            // next append starts on a line of its own.
            if let last = contents.last, last != 0x0A {
                let end = contents.lastIndex(of: 0x0A).map { $0 + 1 } ?? contents.startIndex
                try opened.truncate(to: end - contents.startIndex)
                records = Self.decode(contents[contents.startIndex..<end])
            } else {
                records = Self.decode(contents)
            }
            log = opened
        } catch {
            Self.log.error("pending_queue_open_failed error=\(String(describing: error), privacy: .public)")
        }
        state = Mutex(State(log: log, records: records,
                            nextSequence: (records.map(\.sequence).max() ?? 0) + 1))
    }

    /// Queues `payload` as the latest value for `key`, durably, and returns
    /// its sequence. Throws only if it could not be made durable; the caller
    /// must then report the write as lost.
    @discardableResult
    public func append(key: String, payload: Data) throws -> UInt64 {
        let sealed = try sealer.seal(payload, context: key)
        let sequence = try append { sequence in
            PendingWrite(sequence: sequence, key: key, kind: .value, payload: sealed, through: nil)
        }
        // A value rewritten every few seconds (the progress record) leaves
        // replaced lines behind; drop them once enough have built up.
        if state.withLock({ $0.records.count >= Self.compactionThreshold }) { compactIfAvailable() }
        return sequence
    }

    /// How many lines the file may hold before replaced values are dropped.
    private static let compactionThreshold = 64

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
    /// The latest uncleared value for `key`, telling apart nothing queued
    /// (`missing`, also for a value that is damaged: logged, kept in the
    /// file) from a value that can't be opened now (`unavailable`): a store
    /// reading through the queue must not take that for "nothing newer".
    public func read(key: String) -> StoredRead<Data> {
        state.withLock { state in
            guard let write = Self.pendingUnlocked(state.records).last(where: { $0.key == key }),
                  let payload = write.payload else { return .missing }
            switch sealer.open(payload, context: write.key) {
            case .opened(let data), .legacyPlaintext(let data): return .value(data)
            case .damaged:
                Self.log.error("pending_queue_value_unreadable")
                return .missing
            case .unavailable: return .unavailable
            }
        }
    }

    /// The sequence of the latest uncleared value for `key`, opened or not:
    /// for clearing what a newer write supersedes, even while it can't be read.
    public func latestSequence(key: String) -> UInt64? {
        state.withLock { state in
            Self.pendingUnlocked(state.records).last(where: { $0.key == key })?.sequence
        }
    }

    /// `read(key:)` with its sequence; nil when nothing is queued or it
    /// can't be opened now.
    public func latest(key: String) -> (sequence: UInt64, payload: Data)? {
        state.withLock { state in
            guard let write = Self.pendingUnlocked(state.records).last(where: { $0.key == key }),
                  let payload = opened(write) else { return nil }
            return (write.sequence, payload)
        }
    }

    /// Every key's latest pending value, in the order they were queued.
    public func pending(keyPrefix: String = "") -> [PendingWrite] {
        state.withLock { state in
            Self.pendingUnlocked(state.records).filter { $0.key.hasPrefix(keyPrefix) }.compactMap { write in
                guard write.payload != nil else { return write }
                guard let payload = opened(write) else { return nil }
                return PendingWrite(sequence: write.sequence, key: write.key, kind: write.kind,
                                    payload: payload, through: write.through)
            }
        }
    }

    /// A value's payload, unsealed; nil when it doesn't open (kept in the file).
    private func opened(_ write: PendingWrite) -> Data? {
        guard let payload = write.payload else { return nil }
        switch sealer.open(payload, context: write.key) {
        case .opened(let data), .legacyPlaintext(let data): return data
        case .damaged:
            Self.log.error("pending_queue_value_unreadable")
            return nil
        case .unavailable:
            return nil
        }
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
            guard let log = state.log else { throw CocoaError(.fileWriteNoPermission) }
            let write = make(state.nextSequence)
            var line = try JSONEncoder().encode(write)
            line.append(0x0A)
            try log.append(line)
            state.records.append(write)
            state.nextSequence += 1
            return write.sequence
        }
    }

    /// Rewrites the file with only what is still pending, in one atomic
    /// step (`AppendLog.replace`): a crash or a full disk mid-compaction
    /// leaves the old file or the new one, never part of either. Only while
    /// protected data is available, so a rewrite is never what a locked
    /// device has to survive.
    private func compactIfAvailable() {
        guard availability.isProtectedDataAvailable else { return }
        state.withLock { state in
            guard let log = state.log else { return }
            let kept = Self.pendingUnlocked(state.records)
            guard kept.count < state.records.count else { return }
            do {
                var data = Data()
                for write in kept {
                    data.append(try JSONEncoder().encode(write))
                    data.append(0x0A)
                }
                try log.replace(with: data)
                try availability.setProtection(.completeUntilFirstUserAuthentication, for: fileURL)
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
