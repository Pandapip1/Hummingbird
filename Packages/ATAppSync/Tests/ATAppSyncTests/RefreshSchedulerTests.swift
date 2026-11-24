import Foundation
import Synchronization
import XCTest
@testable import ATAppSync

final class RefreshSchedulerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstChecksAreStaggeredWithinTheInitialInterval() {
        var scheduler = RefreshScheduler()
        scheduler.track((0..<50).map { ("channel-\($0)", "yt") }, now: start)
        let dues = scheduler.items.values.map { $0.nextDue.timeIntervalSince(start) }
        XCTAssertTrue(dues.allSatisfy { $0 >= 0 && $0 < scheduler.configuration.initialInterval })
        XCTAssertGreaterThan(Set(dues.map { Int($0 / 600) }).count, 5, "spread out, not all at once")
        // Stable across launches.
        var again = RefreshScheduler()
        again.track([("channel-7", "yt")], now: start)
        XCTAssertEqual(again.items["channel-7"]?.nextDue, scheduler.items["channel-7"]?.nextDue)
    }

    func testTheIntervalFollowsHowOftenAnItemUpdates() {
        var scheduler = RefreshScheduler()
        scheduler.track([("daily", "yt"), ("frequent", "yt"), ("rare", "yt")], now: start)
        let day: TimeInterval = 86_400
        scheduler.recordSuccess(key: "daily", updates: (0..<5).map { start.addingTimeInterval(-Double($0) * day) }, now: start)
        scheduler.recordSuccess(key: "frequent", updates: (0..<5).map { start.addingTimeInterval(-Double($0) * 1_800) }, now: start)
        scheduler.recordSuccess(key: "rare", updates: (0..<5).map { start.addingTimeInterval(-Double($0) * 30 * day) }, now: start)
        XCTAssertEqual(scheduler.items["daily"]?.interval, day / 2)
        XCTAssertEqual(scheduler.items["frequent"]?.interval, scheduler.configuration.minimumInterval)
        XCTAssertEqual(scheduler.items["rare"]?.interval, scheduler.configuration.maximumInterval)
    }

    func testRequestsToOneSourceAreSpacedAndCapped() {
        var configuration = RefreshScheduler.Configuration()
        configuration.sourceSpacing = 2
        configuration.sourceRequestsPerWindow = 3
        configuration.sourceWindow = 60
        var scheduler = RefreshScheduler(configuration: configuration)
        var now = start
        for _ in 0..<3 {
            let slot = scheduler.nextSlot(for: "yt", now: now)!
            scheduler.recordRequest(source: "yt", at: slot)
            now = slot
        }
        XCTAssertEqual(now, start.addingTimeInterval(4), "two seconds apart")
        // The window is full: the next request waits for the oldest to age out.
        XCTAssertEqual(scheduler.nextSlot(for: "yt", now: now), start.addingTimeInterval(60))
        XCTAssertEqual(scheduler.nextSlot(for: "other", now: now), now, "other sources are unaffected")
    }

    func testFailuresBackTheSourceOffAndASuccessClearsIt() {
        var scheduler = RefreshScheduler()
        scheduler.track([("a", "yt"), ("b", "yt"), ("c", "odysee")], now: start)
        let later = start.addingTimeInterval(scheduler.configuration.initialInterval)
        scheduler.recordFailure(key: "a", now: later)
        XCTAssertNil(scheduler.nextSlot(for: "yt", now: later))
        XCTAssertEqual(scheduler.due(now: later).map(\.key), ["c"], "the whole source waits")
        scheduler.recordFailure(key: "a", now: later.addingTimeInterval(301))
        XCTAssertEqual(scheduler.items["a"]?.nextDue, later.addingTimeInterval(301 + 600), "exponential")
        scheduler.recordFailure(key: "b", retryAfter: 3_600, now: later)
        XCTAssertEqual(scheduler.items["b"]?.nextDue, later.addingTimeInterval(3_600), "the source's Retry-After")
        scheduler.recordSuccess(key: "a", updates: [], now: later.addingTimeInterval(4_000))
        XCTAssertNotNil(scheduler.nextSlot(for: "yt", now: later.addingTimeInterval(4_000)))
    }

    func testUntrackedItemsAreForgotten() {
        var scheduler = RefreshScheduler()
        scheduler.track([("a", "yt"), ("b", "yt")], now: start)
        scheduler.track([("b", "yt")], now: start)
        XCTAssertEqual(Set(scheduler.items.keys), ["b"])
    }
}

final class BackgroundRunnerTests: XCTestCase {
    private final class Log: Sendable {
        private let entries = Mutex<[Int]>([])
        var all: [Int] { entries.withLock { $0 } }
        func add(_ value: Int) { entries.withLock { $0.append(value) } }
    }

    func testWorkThatDoesNotFitIsDeferredNotLost() async {
        let log = Log()
        var budget = BackgroundBudget(duration: .milliseconds(400))
        budget.reserve = .zero
        let report = await BackgroundRunner.run(Array(0..<20), budget: budget, minimumStep: .milliseconds(50)) { key in
            try await Task.sleep(for: .milliseconds(60))
            log.add(key)
        }
        XCTAssertTrue(report.ranOut)
        XCTAssertFalse(report.completed.isEmpty)
        XCTAssertEqual(report.completed, log.all)
        XCTAssertEqual(Set(report.completed + report.deferred), Set(0..<20), "every key completed or deferred")
    }

    func testASlowStepIsCutOffAndTheRestStillRun() async {
        var budget = BackgroundBudget(duration: .seconds(5))
        budget.stepLimit = .milliseconds(100)
        budget.reserve = .zero
        let report = await BackgroundRunner.run([1, 2, 3], budget: budget) { key in
            if key == 2 { try await Task.sleep(for: .seconds(10)) }
        }
        XCTAssertEqual(report.completed, [1, 3])
        XCTAssertEqual(report.deferred, [2])
    }

    func testExpirationMidTaskDefersWhatIsLeft() async {
        let log = Log()
        let started = Log()
        let run = Task {
            await BackgroundRunner.run(Array(0..<10), budget: BackgroundBudget(duration: .seconds(30))) { key in
                started.add(key)
                try await Task.sleep(for: .milliseconds(50))
                log.add(key)
            }
        }
        while started.all.count < 3 { try? await Task.sleep(for: .milliseconds(5)) }
        run.cancel()   // the system expires the window
        let report = await run.value
        XCTAssertTrue(report.ranOut)
        XCTAssertEqual(report.completed, log.all)
        XCTAssertEqual(Set(report.completed + report.deferred), Set(0..<10))
        XCTAssertLessThan(report.completed.count, 10)
    }

    func testFailuresAreReportedSeparately() async {
        struct Failure: Error {}
        let report = await BackgroundRunner.run([1, 2], budget: BackgroundBudget(duration: .seconds(5))) { key in
            if key == 1 { throw Failure() }
        }
        XCTAssertEqual(report.failed, [1])
        XCTAssertEqual(report.completed, [2])
    }
}
