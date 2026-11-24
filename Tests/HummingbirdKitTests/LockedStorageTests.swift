import ATAppSync
import Foundation
import Synchronization
import XCTest
@testable import HummingbirdKit

/// The app's database stays protected `complete`: while the device is locked
/// it can't be read or written. Writes then go to ATAppSync's pending-write
/// queue, reads see them, and they land once, in order, on unlock, even if
/// the app is killed in between.
final class LockedStorageTests: XCTestCase {
    func testWritesWhileLockedSurviveAKillAndLandOnceOnUnlock() async throws {
        let directory = makeTestDirectory("LockedStorage")
        let device = LockableDevice(unlocked: true)
        do {
            // Unlocked first launch creates the database.
            let storage = Storage(directory: directory, protectedData: device)
            storage.save(["first"], name: "history")
            await storage.flush()
        }
        device.processEnded()
        device.unlocked = false
        do {
            let storage = Storage(directory: directory, protectedData: device)
            storage.save(["second"], name: "history")
            storage.save(["queued"], name: "playlists")
            storage.save(["third"], name: "history")
            await storage.flush()
            // Reads while locked come from the queue.
            XCTAssertEqual(storage.load([String].self, name: "history"), ["third"])
        }
        // Killed while locked; relaunched, still locked.
        device.processEnded()
        let storage = Storage(directory: directory, protectedData: device)
        await storage.flush()
        XCTAssertEqual(storage.load([String].self, name: "history"), ["third"])
        XCTAssertEqual(storage.pendingWrites?.pending(keyPrefix: "storage/").map(\.key),
                       ["storage/playlists", "storage/history"])

        device.unlock()   // the system's notification
        await storage.flush()
        XCTAssertEqual(storage.pendingWrites?.pending().isEmpty, true)
        XCTAssertEqual(storage.load([String].self, name: "history"), ["third"])
        XCTAssertEqual(storage.load([String].self, name: "playlists"), ["queued"])
        // Applying again lands nothing more.
        await storage.applyPendingWrites()
        XCTAssertEqual(storage.pendingWrites?.pending().isEmpty, true)
    }

    /// A save that reaches the database after unlock, before the queue has
    /// been applied, wins: the older queued value neither shadows it on read
    /// nor overwrites it when the queue is applied later.
    func testSaveAfterUnlockIsNotOverwrittenByAnOlderQueuedValue() async throws {
        let directory = makeTestDirectory("LockedStorage")
        let device = LockableDevice(unlocked: false)
        let storage = Storage(directory: directory, protectedData: device)
        storage.save(["while locked"], name: "history")
        await storage.flush()
        device.unlocked = true   // unlocked; the notification hasn't arrived yet
        storage.save(["after unlock"], name: "history")
        await storage.flush()
        XCTAssertEqual(storage.load([String].self, name: "history"), ["after unlock"])
        await storage.applyPendingWrites()
        XCTAssertEqual(storage.load([String].self, name: "history"), ["after unlock"])
        XCTAssertEqual(storage.pendingWrites?.pending().isEmpty, true)
    }

    /// Protection classes are set explicitly, per file.
    func testDatabaseIsCompleteAndQueueIsCompleteUnlessOpen() async throws {
        let directory = makeTestDirectory("LockedStorage")
        let device = LockableDevice(unlocked: true)
        let storage = Storage(directory: directory, protectedData: device)
        storage.save(["x"], name: "history")
        await storage.flush()
        _ = Storage(directory: directory, protectedData: device)   // reopening protects existing files
        XCTAssertEqual(device.protection(of: directory.appendingPathComponent("storage.sqlite3")), .complete)
        XCTAssertEqual(device.protection(of: directory.appendingPathComponent("pending-writes.queue")),
                       .completeUnlessOpen)
    }
}

/// A device whose lock the test controls; records protection classes and
/// tells observers when it unlocks, as the system does.
final class LockableDevice: ProtectedDataAvailability {
    private struct State {
        var unlocked: Bool
        var classes: [String: AppSyncFileProtection] = [:]
        var observers: [@Sendable (Bool) -> Void] = []
    }
    private let state: Mutex<State>

    init(unlocked: Bool) { state = Mutex(State(unlocked: unlocked)) }

    var unlocked: Bool {
        get { state.withLock { $0.unlocked } }
        set { state.withLock { $0.unlocked = newValue } }
    }

    /// The app was killed: its observers are gone.
    func processEnded() { state.withLock { $0.observers.removeAll() } }

    func unlock() {
        let observers = state.withLock { state in
            state.unlocked = true
            return state.observers
        }
        for observer in observers { observer(true) }
    }

    var isProtectedDataAvailable: Bool { unlocked }
    func observeProtectedDataAvailability(_ handler: @escaping @Sendable (Bool) -> Void) {
        state.withLock { $0.observers.append(handler) }
    }
    func setProtection(_ protection: AppSyncFileProtection, for url: URL) throws {
        state.withLock { $0.classes[url.standardizedFileURL.path] = protection }
    }
    func protection(of url: URL) -> AppSyncFileProtection? {
        state.withLock { $0.classes[url.standardizedFileURL.path] }
    }
}
