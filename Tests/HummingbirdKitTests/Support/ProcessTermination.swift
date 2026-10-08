import Foundation

/// `Process.waitUntilExit()` on Linux (swift-corelibs/swift-foundation) waits by
/// repeatedly calling `RunLoop.current.run(mode:before:)` in a loop, woken by a
/// CFSocket callback when the child exits. Called from a thread that's also
/// servicing Swift's concurrency executor — any code running on `@MainActor`
/// during an `async` function, even a plain synchronous helper it calls — that
/// nested run loop invocation never observes the wakeup and spins at ~100% CPU
/// forever, even though the child already exited. This is what turned
/// `GTKPlaybackTests.testCustomHTTPHeadersReachGStreamer`'s teardown (a
/// `defer { server.terminate(); server.waitUntilExit() }`, unrelated to anything
/// else this session changed) into a multi-minute hang.
///
/// Fix: never call `waitUntilExit()` from MainActor-adjacent code. `terminationHandler`
/// does not share that bug — it fires via Foundation's own process-monitoring thread,
/// not a nested run loop on the caller's thread — so waiting on a semaphore it
/// signals is a true blocking wait (no polling) that sidesteps the broken wrapper
/// entirely. Verified empirically: the semaphore fires in under 1ms from the exact
/// `@MainActor async` context that hung indefinitely under `waitUntilExit()`.
enum ProcessTermination {
    /// Drop-in, hang-proof replacement for `process.waitUntilExit()`.
    @discardableResult
    static func wait(for process: Process, timeout: TimeInterval = 10) -> Bool {
        guard process.isRunning else { return true }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        guard process.isRunning else { return true } // exited between the check above and setting the handler
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    /// Drop-in, hang-proof replacement for `process.terminate(); process.waitUntilExit()`.
    static func terminateAndWait(_ process: Process, timeout: TimeInterval = 5) {
        guard process.isRunning else { return }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        guard process.isRunning else { return }
        process.terminate()
        guard semaphore.wait(timeout: .now() + timeout) == .timedOut else { return }
        // Defensive fallback only — not expected to trigger given the above:
        // SIGTERM delivery itself was verified fine, only the old waitUntilExit()
        // wrapper was broken.
        kill(process.processIdentifier, SIGKILL)
        _ = semaphore.wait(timeout: .now() + 1)
    }
}
