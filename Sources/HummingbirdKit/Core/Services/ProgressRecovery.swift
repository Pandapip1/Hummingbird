import ATAppSync
import Foundation
import os

/// The playing item's latest progress, kept in ATAppSync's
/// `PendingWriteQueue` (the same durable, lock-safe queue storage writes
/// wait in while the device is locked), so a crash, a debugger stopping
/// the app, or the app being killed while the device is locked loses
/// seconds of it, not the minute between history writes. Playback progress
/// reaches the library and the synced journal lazily
/// (`LibraryStore.recordProgress`); this record is written on every
/// progress tick instead, and costs one fsync'd append, never a journal
/// write.
///
/// A launch that finds a record newer than the library's entry for that
/// item applies it once (`LibraryStore.recoverInterruptedProgress`); normal
/// history writes clear it.
final class ProgressRecovery: Sendable {
    private let queue: PendingWriteQueue
    private let key: String
    /// Appends happen here, off the main actor, in order.
    private let worker = DispatchQueue(label: "com.eightybps.hummingbird.progress-recovery", qos: .utility)

    /// `profile` keeps each profile's record apart in the shared queue.
    init(queue: PendingWriteQueue, profile: UUID) {
        self.queue = queue
        key = "progress/" + profile.uuidString.lowercased()
    }

    /// Replaces the record with `entry`.
    func record(_ entry: HistoryEntry) {
        worker.async { [queue, key] in
            do {
                try queue.append(key: key, payload: JSONEncoder().encode(entry))
            } catch {
                Logger.player.error("progress_recovery_write_failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Clears the record if it is no newer than `date`: a record written
    /// for a later tick stays.
    func clear(upTo date: Date) {
        worker.async { [queue, key] in
            guard let latest = queue.latest(key: key),
                  let entry = try? JSONDecoder().decode(HistoryEntry.self, from: latest.payload),
                  entry.date <= date else { return }
            do { try queue.clear(key: key, through: latest.sequence) }
            catch {
                Logger.player.error("progress_recovery_clear_failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The recorded entry, if any, read after every write submitted so far.
    func load() async -> HistoryEntry? {
        await withCheckedContinuation { continuation in
            worker.async { [queue, key] in
                let entry = queue.latest(key: key).flatMap {
                    try? JSONDecoder().decode(HistoryEntry.self, from: $0.payload)
                }
                continuation.resume(returning: entry)
            }
        }
    }

    /// Waits until every write and clear submitted so far is done.
    func waitForWrites() async {
        await withCheckedContinuation { continuation in worker.async { continuation.resume() } }
    }
}
