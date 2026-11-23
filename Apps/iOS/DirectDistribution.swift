import Foundation
import PluginEngine
#if !APP_STORE
import CJSCExecutionLimit
#endif

/// Installs plugin execution limits at launch: process isolation where the platform can start
/// processes (macOS: the bundled XPC service), and, in builds distributed outside the App Store,
/// JavaScriptCore's own script time limit. The time limit is not public API, so App Store builds
/// (HUMMINGBIRD_DISTRIBUTION=appstore, which defines APP_STORE) compile none of it and carry no
/// reference to it (scripts/check-app-store-symbols).
enum PluginExecutionSetup {
    static func install() {
        #if !APP_STORE
        PluginExecutionLimits.installEngineTimeLimit(JavaScriptCoreTimeLimit())
        #endif
        PluginExecutionLimits.installPlatformIsolation()
    }
}

#if !APP_STORE
/// JavaScriptCore's script time limit: a script past it is stopped by the engine, with a
/// termination it cannot catch, and its context returns.
private struct JavaScriptCoreTimeLimit: JSCExecutionTimeLimiter {
    func setLimit(_ seconds: Double?, globalContext: OpaquePointer) {
        if let seconds {
            hb_set_execution_time_limit(globalContext, seconds)
        } else {
            hb_clear_execution_time_limit(globalContext)
        }
    }
}
#endif
