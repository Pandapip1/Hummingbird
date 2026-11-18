import ATAppSync
import Foundation
import Synchronization
import XCTest
@testable import HummingbirdKit

/// Playback progress reaches history and the journal lazily; a crash in
/// between used to lose up to a minute of it. The recovery record keeps the
/// playing item's latest tick, at no journal cost.
@MainActor
final class ProgressRecoveryTests: XCTestCase {
    private struct Profile {
        let log: AppSyncMutationLog
        let changes: ProfileChangeStore
        let recoveryURL: URL
        let id = UUID()
        let journalWrites: WriteCounter
    }

    private func makeProfile() throws -> Profile {
        let directory = makeTestDirectory("ProgressRecovery")
        let log = try AppSyncMutationLog(fileURL: directory.appendingPathComponent("journal.json"))
        let changes = ProfileChangeStore(mutationLog: log)
        let writes = WriteCounter()
        changes.setMutationHandler { writes.increment() }
        return Profile(log: log, changes: changes,
                       recoveryURL: directory.appendingPathComponent("pending-writes.queue"),
                       journalWrites: writes)
    }

    private func launch(_ profile: Profile, history: [HistoryEntry] = []) -> (LibraryStore, ProgressRecovery) {
        var snapshot = LibraryPersistenceSnapshot.empty
        snapshot.history = history
        // Each launch opens the queue afresh, as a relaunch does.
        let queue = PendingWriteQueue(fileURL: profile.recoveryURL, availability: UnprotectedDataAvailability())
        let recovery = ProgressRecovery(queue: queue, profile: profile.id)
        let library = LibraryStore(snapshot: snapshot, profileChanges: profile.changes,
                                   storage: makeTestStores().storage, recovery: recovery)
        return (library, recovery)
    }

    func testCrashDuringPlaybackIsRecoveredOnRelaunchAndSyncedOnce() async throws {
        let profile = try makeProfile()
        let video = try makeVideo()
        let start = Date()
        do {
            let (library, recovery) = launch(profile)
            for tick in 0..<12 {   // a minute of 5-second ticks, then a crash: no flush
                library.recordProgress(video, seconds: Double(tick * 5), now: start.addingTimeInterval(Double(tick * 5)))
            }
            await recovery.waitForWrites()
            await profile.changes.flush()
        }
        // Only the first tick reached the journal (position 0).
        XCTAssertEqual(profile.journalWrites.value, 1)
        let crashedJournal = try XCTUnwrap(profile.log.events().first?.value?.decode(HistoryEntry.self))
        XCTAssertEqual(crashedJournal.position, 0)

        // Relaunch: the library was never saved after the first tick.
        let (library, recovery) = launch(profile)
        await library.recoverInterruptedProgress()
        await recovery.waitForWrites()
        await profile.changes.flush()

        XCTAssertEqual(library.history.first?.position, 55)
        XCTAssertEqual(profile.journalWrites.value, 2, "recovered once into the journal")
        XCTAssertEqual(try profile.log.events().first?.value?.decode(HistoryEntry.self).position, 55)
        let leftover = await recovery.load()
        XCTAssertNil(leftover)

        // A further launch finds nothing to recover and writes nothing.
        let (again, _) = launch(profile, history: library.history)
        await again.recoverInterruptedProgress()
        await profile.changes.flush()
        XCTAssertEqual(profile.journalWrites.value, 2)
    }

    func testNormalPlaybackAddsNoJournalWritesAndFlushClearsTheRecord() async throws {
        let profile = try makeProfile()
        let video = try makeVideo()
        let (library, recovery) = launch(profile)
        let start = Date()
        for tick in 0..<10 {
            library.recordProgress(video, seconds: Double(tick * 5), now: start.addingTimeInterval(Double(tick * 5)))
        }
        await recovery.waitForWrites()
        await profile.changes.flush()
        XCTAssertEqual(profile.journalWrites.value, 1, "the recovery record never writes the journal")
        let recorded = await recovery.load()
        XCTAssertEqual(recorded?.position, 45)

        library.flushHistory()   // pause / stop
        await profile.changes.flush()
        try await waitUntil { await recovery.load() == nil }
        XCTAssertEqual(profile.journalWrites.value, 2)
    }

    func testRecordOlderThanTheLibraryIsDiscardedWithoutWriting() async throws {
        let profile = try makeProfile()
        let video = try makeVideo()
        let stale = HistoryEntry(video: video, position: 10, date: Date(timeIntervalSince1970: 1_000))
        let crashed = ProgressRecovery(
            queue: PendingWriteQueue(fileURL: profile.recoveryURL, availability: UnprotectedDataAvailability()),
            profile: profile.id
        )
        crashed.record(stale)
        await crashed.waitForWrites()
        let newer = HistoryEntry(video: video, position: 99, date: Date(timeIntervalSince1970: 2_000))
        let (library, recovery) = launch(profile, history: [newer])
        await library.recoverInterruptedProgress()
        await recovery.waitForWrites()
        await profile.changes.flush()
        XCTAssertEqual(library.history, [newer])
        XCTAssertEqual(profile.journalWrites.value, 0)
        let leftover = await recovery.load()
        XCTAssertNil(leftover)
    }

    private func makeVideo() throws -> SavedVideo {
        let json = #"{"pluginId":"alpha","url":"https://example.com/v/1","name":"Video","isLive":false,"contentType":1}"#
        return try JSONDecoder().decode(SavedVideo.self, from: Data(json.utf8))
    }

    /// Polls `condition` for up to five seconds.
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class WriteCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
