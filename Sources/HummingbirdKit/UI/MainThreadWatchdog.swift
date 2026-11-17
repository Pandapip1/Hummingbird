#if DEBUG
import Dispatch
import Foundation
import os
import Synchronization
import SwiftOpenUI

/// Detects main-thread hangs from its own thread, the way the system's hang
/// detection does, in debug builds. It posts a ping to the main queue and
/// times the reply; a reply 250 ms or more late is a hang. The main thread
/// only ever runs the ping itself, and the app context is gathered once it
/// has responded, so measuring never adds to a hang.
///
/// Each hang becomes a `RenderStall` signpost interval spanning the hang
/// (Instruments: os_signpost, category `performance`), a `render_stall` log
/// entry with what the app was doing, and a record in the `StallLog` that
/// Settings › Diagnostics exports. Instruments' Hangs instrument and MetricKit
/// hang diagnostics give the stacks. It does not run under XCTest.
///
/// Not counted: time the app is not active (SwiftOpenUI's
/// `ApplicationActivity`, reported by every backend), system sleep (the
/// suspending clock stops), and any time the whole process was stopped, such
/// as at a debugger breakpoint. The watchdog notices the last when its own
/// waits overrun. It behaves the same on every platform.
final class MainThreadWatchdog: Sendable {
    static let shared = MainThreadWatchdog()

    private static let threshold: Duration = .milliseconds(250)
    /// Pause between a reply and the next ping.
    private static let pingInterval: Duration = .milliseconds(50)
    /// How long each wait for a reply lasts before checking for an overrun.
    private static let waitSlice: Duration = .milliseconds(100)
    /// A wait that overruns its slice by this much means this thread did not
    /// run either: the process was stopped, not the main thread busy.
    private static let stoppedProcessTolerance: Duration = .milliseconds(150)

    private let state = Mutex(State())

    private struct State {
        var started = false
        /// The app is inactive or in the background.
        var paused = false
    }

    private init() {}

    /// Starts watching, once. `context` describes what the app was doing; it
    /// runs on the main actor after the main thread has responded. Stalls are
    /// kept in `log`.
    @MainActor
    func start(log: StallLog, context: @escaping @MainActor () -> [String: String]) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil, environment["XCTestBundlePath"] == nil
        else { return }
        WatchdogContext.provider = context
        WatchdogContext.log = log
        let alreadyStarted = state.withLock { state in
            defer { state.started = true }
            return state.started
        }
        guard !alreadyStarted else { return }
        ApplicationActivity.observe { [self] active in setActive(active) }
        let thread = Thread { [self] in run() }
        thread.name = "com.eightybps.hummingbird.main-thread-watchdog"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private var isPaused: Bool { state.withLock(\.paused) }

    /// Whether the app is active. Stalls are only counted while it is.
    private func setActive(_ active: Bool) {
        state.withLock { $0.paused = !active }
    }

    private func run() {
        let clock = SuspendingClock()
        while true {
            Thread.sleep(forTimeInterval: Self.seconds(Self.pingInterval))
            guard !isPaused else { continue }
            measurePing(clock: clock)
        }
    }

    private func measurePing(clock: SuspendingClock) {
        let reply = DispatchSemaphore(value: 0)
        let start = clock.now
        DispatchQueue.main.async { reply.signal() }

        let signposter = OSSignposter.performance
        var interval: OSSignpostIntervalState?
        var processWasStopped = false
        var sliceStart = start
        while reply.wait(timeout: .now() + Self.seconds(Self.waitSlice)) == .timedOut {
            let now = clock.now
            if now - sliceStart > Self.waitSlice + Self.stoppedProcessTolerance {
                processWasStopped = true
            }
            sliceStart = now
            if interval == nil, now - start >= Self.threshold {
                interval = signposter.beginInterval("RenderStall", id: signposter.makeSignpostID())
            }
        }
        let elapsed = clock.now - start
        let ignored = processWasStopped || isPaused
        if let interval {
            signposter.endInterval("RenderStall", interval, "ms=\(Self.milliseconds(elapsed))\(ignored ? " ignored" : "")")
        }
        guard elapsed >= Self.threshold, !ignored else { return }
        let milliseconds = Self.milliseconds(elapsed)
        let began = Date().addingTimeInterval(-Self.seconds(elapsed))
        Task { @MainActor in
            let context = WatchdogContext.provider?() ?? [:]
            let described = context.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            // The route can name a URL, so the context is private.
            Logger.performance.notice("render_stall ms=\(milliseconds, privacy: .public) \(described)")
            // Encoded and written on the log's own queue.
            WatchdogContext.log?.append(.init(date: began, milliseconds: milliseconds, context: context))
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((seconds(duration) * 1_000).rounded())
    }
}

/// Where the watchdog asks what the app was doing.
@MainActor
private enum WatchdogContext {
    static var provider: (@MainActor () -> [String: String])?
    static var log: StallLog?
}
#endif
