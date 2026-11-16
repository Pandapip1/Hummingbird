import Foundation
import os
import SwiftOpenUI
import Synchronization

/// Marks launch milestones as `Launch` signpost events (category
/// `performance`) and `launch_<milestone> ms=…` log entries, timed from the
/// moment the process started:
///
///     log show --last 10m --predicate 'subsystem == "com.eightybps.hummingbird" AND eventMessage BEGINSWITH "launch_"'
public enum LaunchTiming {
    public enum Milestone: String, Sendable {
        /// The splash's first frame has been committed.
        case splashVisible = "splash_visible"
        /// Stores opened and the credential store probed, off the main thread.
        case storesOpened = "stores_opened"
        /// Persisted state loaded and the profile opened; the model can be made.
        case rootPrepared = "root_prepared"
        /// The main interface's first frame has been committed.
        case interfaceVisible = "interface_visible"
    }

    /// Logs `milestone` once per process.
    public static func mark(_ milestone: Milestone) {
        let first = marked.withLock { $0.insert(milestone.rawValue).inserted }
        guard first else { return }
        let milliseconds = ProcessLaunch.elapsedMilliseconds()
        OSSignposter.performance.emitEvent("Launch", "\(milestone.rawValue, privacy: .public) ms=\(milliseconds)")
        Logger.performance.notice("launch_\(milestone.rawValue, privacy: .public) ms=\(milliseconds, privacy: .public)")
    }

    private static let marked = Mutex(Set<String>())
}
