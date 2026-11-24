import Foundation

/// The time a background window allows (an iOS refresh task's ~30 seconds,
/// a processing task's minutes, a desktop timer's pass), and the work done
/// in it: steps run one at a time, each with its own deadline inside the
/// window, and whatever doesn't fit (or is cut off when the system expires
/// the window, which cancels the task) is left for the next window.
/// Nothing is half-recorded: a step either completes or counts as deferred.
public struct BackgroundBudget: Sendable {
    public let deadline: ContinuousClock.Instant
    /// Kept free at the end, for saving state and telling the system.
    public var reserve: Duration = .seconds(2)
    /// The longest one step may take.
    public var stepLimit: Duration = .seconds(20)

    public init(deadline: ContinuousClock.Instant) {
        self.deadline = deadline
    }

    public init(duration: Duration) {
        deadline = .now + duration
    }

    /// Time left for work, after the reserve.
    public var remaining: Duration { (deadline - reserve) - .now }
}

/// What happened to the steps of one window.
public struct BackgroundRunReport<Key: Hashable & Sendable>: Sendable {
    public var completed: [Key] = []
    /// Failed with an error; they'll be retried by their own schedule.
    public var failed: [Key] = []
    /// Not run, or cut off: due again next window.
    public var deferred: [Key] = []
    /// The window ended (expired or out of time) before every step ran.
    public var ranOut = false

    public init() {}
}

public enum BackgroundRunner {
    struct StepTimedOut: Error {}

    /// Runs `step` for each key in order within `budget`. A step that
    /// overruns its deadline is cancelled and deferred, as is every step
    /// left when the budget runs out or the calling task is cancelled
    /// (the system expiring the window).
    public static func run<Key: Hashable & Sendable>(
        _ keys: [Key], budget: BackgroundBudget,
        minimumStep: Duration = .seconds(1),
        step: @escaping @Sendable (Key) async throws -> Void
    ) async -> BackgroundRunReport<Key> {
        var report = BackgroundRunReport<Key>()
        var remaining = keys[...]
        while let key = remaining.first {
            let left = budget.remaining
            guard !Task.isCancelled, left >= minimumStep else {
                report.ranOut = true
                break
            }
            remaining = remaining.dropFirst()
            let limit = min(left, budget.stepLimit)
            do {
                try await withDeadline(limit) { try await step(key) }
                report.completed.append(key)
            } catch is StepTimedOut {
                report.deferred.append(key)
            } catch is CancellationError {
                report.deferred.append(key)
                report.ranOut = true
                break
            } catch {
                if Task.isCancelled {
                    report.deferred.append(key)
                    report.ranOut = true
                    break
                }
                report.failed.append(key)
            }
        }
        report.deferred += remaining
        return report
    }

    /// Runs `work`, cancelling it after `limit`.
    static func withDeadline(_ limit: Duration, _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await work(); return true }
            group.addTask {
                try await Task.sleep(for: limit)
                return false
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return }
            if !first { throw StepTimedOut() }
        }
    }
}
