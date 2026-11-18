import Foundation
import Synchronization
import XCTest
@testable import ATAppSync

final class PendingWriteQueueTests: XCTestCase {
    /// Locked device: writes queue; the app is killed (the queue reopened);
    /// on unlock they land once, in order, with no duplicates.
    func testWritesQueuedWhileLockedLandOnceInOrderAfterKillAndUnlock() throws {
        let file = try temporaryFile()
        let device = FakeDevice(unlocked: false)
        do {
            let queue = PendingWriteQueue(fileURL: file, availability: device)
            try queue.append(key: "storage/history", payload: Data("h1".utf8))
            try queue.append(key: "storage/playlists", payload: Data("p1".utf8))
            try queue.append(key: "storage/history", payload: Data("h2".utf8))
            // Locked: nothing is handed over yet.
            XCTAssertEqual(queue.apply { _ in XCTFail("applied while locked"); return true }, 0)
        }
        // Killed and relaunched, still locked: the queue is intact.
        let reopened = PendingWriteQueue(fileURL: file, availability: device)
        XCTAssertEqual(reopened.latest(key: "storage/history")?.payload, Data("h2".utf8))

        device.unlocked = true
        var landed: [String] = []
        XCTAssertEqual(reopened.apply { write in
            landed.append("\(write.key)=\(String(decoding: write.payload ?? Data(), as: UTF8.self))")
            return true
        }, 2)
        XCTAssertEqual(landed, ["storage/playlists=p1", "storage/history=h2"])
        XCTAssertEqual(reopened.apply { _ in XCTFail("applied twice"); return true }, 0)
        XCTAssertTrue(PendingWriteQueue(fileURL: file, availability: device).pending().isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data(), "compacted once unlocked")
    }

    /// A store that can't take a value yet keeps it queued.
    func testValuesTheStoreRejectsStayQueued() throws {
        let queue = PendingWriteQueue(fileURL: try temporaryFile(), availability: FakeDevice(unlocked: true))
        try queue.append(key: "a", payload: Data("1".utf8))
        XCTAssertEqual(queue.apply { _ in false }, 0)
        XCTAssertEqual(queue.pending().map(\.key), ["a"])
    }

    /// Clearing through a sequence keeps values queued after it; while
    /// locked it appends a marker rather than rewriting the file.
    func testClearKeepsLaterValuesAndOnlyAppendsWhileLocked() throws {
        let file = try temporaryFile()
        let device = FakeDevice(unlocked: false)
        let queue = PendingWriteQueue(fileURL: file, availability: device)
        let first = try queue.append(key: "progress/p", payload: Data("10".utf8))
        try queue.clear(key: "progress/p", through: first)
        XCTAssertNil(queue.latest(key: "progress/p"))
        let second = try queue.append(key: "progress/p", payload: Data("20".utf8))
        try queue.clear(key: "progress/p", through: first)
        XCTAssertEqual(queue.latest(key: "progress/p")?.sequence, second)
        let lines = String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "append-only while locked")
    }

    /// A crash mid-append leaves a partial line: it is dropped, and the
    /// next append is still readable.
    func testPartialLastLineFromACrashIsDropped() throws {
        let file = try temporaryFile()
        let device = FakeDevice(unlocked: true)
        try PendingWriteQueue(fileURL: file, availability: device).append(key: "a", payload: Data("1".utf8))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"sequence":2,"key":"b","ki"#.utf8))
        try handle.close()

        let reopened = PendingWriteQueue(fileURL: file, availability: device)
        try reopened.append(key: "c", payload: Data("3".utf8))
        let again = PendingWriteQueue(fileURL: file, availability: device)
        XCTAssertEqual(again.pending().map(\.key), ["a", "c"])
    }

    /// The queue asks the host to protect it `completeUnlessOpen`.
    func testQueueFileIsCompleteUnlessOpen() throws {
        let file = try temporaryFile()
        let device = FakeDevice(unlocked: true)
        _ = PendingWriteQueue(fileURL: file, availability: device)
        XCTAssertEqual(device.protection(of: file), .completeUnlessOpen)
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingWriteQueue-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("pending.queue")
    }
}

/// A device whose lock state the test sets, recording protection classes.
final class FakeDevice: ProtectedDataAvailability {
    private let state: Mutex<(unlocked: Bool, classes: [String: AppSyncFileProtection])>

    init(unlocked: Bool) { state = Mutex((unlocked, [:])) }

    var unlocked: Bool {
        get { state.withLock { $0.unlocked } }
        set { state.withLock { $0.unlocked = newValue } }
    }

    var isProtectedDataAvailable: Bool { unlocked }
    func observeProtectedDataAvailability(_ handler: @escaping @Sendable (Bool) -> Void) {}
    func setProtection(_ protection: AppSyncFileProtection, for url: URL) throws {
        state.withLock { $0.classes[url.standardizedFileURL.path] = protection }
    }
    func protection(of url: URL) -> AppSyncFileProtection? {
        state.withLock { $0.classes[url.standardizedFileURL.path] }
    }
}
