import Foundation
import XCTest
@testable import HummingbirdKit

/// Exiting never waits past its budget: the system kills an app that takes
/// about 5 seconds to exit, so a slow write still in flight must not hold the
/// exit up.
final class ExitDeadlineTests: XCTestCase {
    /// A value whose encoding takes `seconds`, standing in for a large or slow write.
    private struct SlowValue: Encodable, Sendable {
        let seconds: Double
        func encode(to encoder: Encoder) throws {
            Thread.sleep(forTimeInterval: seconds)
            var container = encoder.singleValueContainer()
            try container.encode(seconds)
        }
    }

    func testDrainStopsAtTheDeadlineWhileWorkIsInFlight() {
        let queue = DispatchQueue(label: "test.exit-deadline")
        queue.async { Thread.sleep(forTimeInterval: 3) }
        let started = Date()
        let drained = ExitDeadline.forExit(budget: .milliseconds(300)).drain(queue)
        XCTAssertFalse(drained)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testDrainReportsAQueueThatFinishedInTime() {
        let queue = DispatchQueue(label: "test.exit-deadline.quick")
        queue.async {}
        XCTAssertTrue(ExitDeadline.forExit(budget: .seconds(2)).drain(queue))
    }

    func testStorageFlushOnExitIsBoundedWithASlowWriteInFlight() {
        let storage = Storage.inMemory()
        storage.save(SlowValue(seconds: 3), name: "slow")
        let started = Date()
        let flushed = storage.flushBeforeTermination(until: .forExit(budget: .milliseconds(300)))
        XCTAssertFalse(flushed, "the slow write is still in flight")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "exit didn't wait for it")
    }

    func testStorageFlushOnExitWaitsForQuickWrites() {
        let storage = Storage.inMemory()
        storage.save(["value"], name: "quick")
        XCTAssertTrue(storage.flushBeforeTermination(until: .forExit(budget: .seconds(2))))
        let value = storage.load([String].self, name: "quick")
        XCTAssertEqual(value, ["value"])
    }
}
