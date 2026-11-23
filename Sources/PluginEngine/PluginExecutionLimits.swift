import Foundation
import Synchronization
import PlatformSupport

/// Limits a JavaScriptCore context's script execution time; the engine stops a script that runs
/// longer (a termination it cannot catch). Implemented only in builds outside the App Store (it
/// uses a JavaScriptCore function that is not public API): see Apps/iOS/DirectDistribution.swift.
public protocol JSCExecutionTimeLimiter: Sendable {
    /// Sets (or, with nil, clears) the time limit for scripts in `globalContext`'s context group.
    func setLimit(_ seconds: Double?, globalContext: OpaquePointer)
}

/// How a plugin call that runs past its deadline is stopped. One API for every build and platform;
/// each uses the strongest enforcement available to it:
///
/// | build / platform                   | enforcement |
/// |------------------------------------|-------------|
/// | macOS (XPC host), Linux (subprocess)| `.processTermination`: the plugin's host process is killed |
/// | non-App-Store builds, in-process    | `.engineTimeLimit`: JavaScriptCore stops the script |
/// | App Store iOS / tvOS / visionOS     | `.abandonment`: the context is taken out of service; a pure loop keeps one thread busy until it ends |
public enum PluginExecutionLimits {
    public enum Enforcement: String, Sendable {
        case processTermination, engineTimeLimit, abandonment
    }

    private struct State: Sendable {
        var timeLimiter: (any JSCExecutionTimeLimiter)?
        var hostLauncher: (any PluginHostLauncher)?
    }

    private static let state = Mutex(State())

    /// Installs JavaScriptCore's script time limit. Called at launch by builds that may use it.
    public static func installEngineTimeLimit(_ limiter: any JSCExecutionTimeLimiter) {
        state.withLock { $0.timeLimiter = limiter }
    }

    /// Runs plugins in host processes started by `launcher` (an XPC service on macOS, a child
    /// process on Linux). Called at launch where the platform can start processes.
    public static func installProcessIsolation(_ launcher: any PluginHostLauncher) {
        state.withLock { $0.hostLauncher = launcher }
    }

    /// Removes both, for tests.
    public static func reset() {
        state.withLock { $0 = State() }
    }

    public static var engineTimeLimit: (any JSCExecutionTimeLimiter)? { state.withLock { $0.timeLimiter } }

    /// The strongest enforcement this build has for in-process contexts and for new plugins.
    public static var enforcement: Enforcement {
        state.withLock { state in
            if state.hostLauncher != nil { return .processTermination }
            if state.timeLimiter != nil { return .engineTimeLimit }
            return .abandonment
        }
    }

    /// The engine for one plugin's contexts: its own host process when process isolation is
    /// installed, else the in-process engine.
    public static func makeEngine() -> any JSEngine {
        if let launcher = state.withLock({ $0.hostLauncher }) { return RemoteJSEngine(launcher: launcher) }
        return JSEngines.default
    }
}

public extension PluginExecutionLimits {
    /// The XPC service's bundle name (Apps/PluginHostXPC; `<app bundle ID>.PluginHost`).
    static let serviceBundleName = "PluginHost"

    /// Installs the process isolation this platform offers (SwiftOpenUI `HelperProcess`): the
    /// app's XPC service on macOS, when the bundle carries it; the app's own binary run with
    /// `--plugin-host` on Linux. Where the platform can start no helper (iOS, tvOS, visionOS),
    /// plugins stay in-process.
    static func installPlatformIsolation(bundle: Bundle = .main) {
        if let launcher = HelperProcess.Launcher.app(serviceBundleName: serviceBundleName,
                                                     arguments: HelperPluginHostLauncher.hostArguments, bundle: bundle) {
            installProcessIsolation(HelperPluginHostLauncher(launcher))
        }
    }
}
