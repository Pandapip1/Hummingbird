import Foundation

/// How long the application may spend finishing work while it exits. The
/// system kills an app that hasn't exited about 5 seconds after it was asked
/// to ("failed to terminate gracefully"), so every wait on the way out shares
/// one budget well inside that: when the budget runs out, the app exits with
/// whatever is still queued, as it would after a crash, instead of being
/// killed while it waits.
struct ExitDeadline: Sendable {
    let end: DispatchTime

    /// The budget for one exit, from now.
    static func forExit(budget: DispatchTimeInterval = .milliseconds(2_500)) -> ExitDeadline {
        ExitDeadline(end: .now() + budget)
    }

    /// Waits until `queue` has run everything submitted to it so far, or the
    /// deadline passes. True if everything ran.
    @discardableResult
    func drain(_ queue: DispatchQueue) -> Bool {
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        return drained.wait(timeout: end) == .success
    }
}
