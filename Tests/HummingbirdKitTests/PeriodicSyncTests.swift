import Foundation
import Synchronization
import XCTest
@testable import HummingbirdKit

/// The periodic sync pass used to run every 30 seconds for as long as the
/// app ran, in front or not, whether or not anything changed.
@MainActor
final class PeriodicSyncTests: XCTestCase {
    /// Waits recorded by the sleeper; each wait returns at once.
    private final class Waits: Sendable {
        private let recorded = Mutex<[Duration]>([])
        var all: [Duration] { recorded.withLock { $0 } }
        func record(_ wait: Duration) { recorded.withLock { $0.append(wait) } }
    }

    func testIdlePassesBackOffToTheCapAndAnEditResetsIt() async throws {
        let waits = Waits()
        var passes = 0
        var sync: PeriodicSync!
        sync = PeriodicSync(pass: {
            passes += 1
            if passes == 7 { sync.stop() }
            return false
        }, defers: { false }, sleep: { waits.record($0); await Task.yield() })
        sync.start()
        try await waitUntil { passes == 7 }
        XCTAssertEqual(waits.all, [30, 60, 120, 240, 480, 600, 600].map { Duration.seconds($0) })
        XCTAssertEqual(sync.interval, SyncBackoff.cap)

        // A local edit (or a device appearing) starts again from 30 s.
        sync.nudge()
        XCTAssertEqual(sync.interval, SyncBackoff.first)
        sync.stop()
    }

    func testNoPassesWhileInactiveAndForegroundingResumes() async throws {
        let waits = Waits()
        var passes = 0
        let sync = PeriodicSync(pass: { passes += 1; return false }, defers: { false },
                                sleep: { waits.record($0); try await Task.sleep(for: .milliseconds(5)) })
        sync.setActive(false)
        sync.start()
        sync.nudge()
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(passes, 0)
        XCTAssertTrue(waits.all.isEmpty)
        XCTAssertFalse(sync.isRunning)

        sync.setActive(true)
        try await waitUntil { passes > 0 }
        sync.setActive(false)
        let count = passes
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(passes, count, "no passes once inactive")
    }

    func testNoPassesWhileEnergyIsSavedAndAChangeResetsTheWait() async throws {
        let waits = Waits()
        var passes = 0
        let saving = Flag()
        var sync: PeriodicSync!
        sync = PeriodicSync(pass: {
            passes += 1
            sync.stop()
            return true
        }, defers: { saving.isSet }, sleep: { wait in
            waits.record(wait)
            if waits.all.count == 3 { saving.clear() }
            await Task.yield()
        })
        sync.start()
        try await waitUntil { passes == 1 }
        // Two skipped (energy saving) waits backed off; then a pass ran.
        XCTAssertEqual(waits.all, [30, 60, 120].map { Duration.seconds($0) })
        XCTAssertEqual(sync.interval, SyncBackoff.first, "a pass that brought changes resets the wait")
    }

    private final class Flag: Sendable {
        private let value = Mutex(true)
        var isSet: Bool { value.withLock { $0 } }
        func clear() { value.withLock { $0 = false } }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
