#ifndef CJSCEXECUTIONLIMIT_H
#define CJSCEXECUTIONLIMIT_H

// JavaScriptCore's script time limit. These two functions are exported by JavaScriptCore but are
// not public API (they are declared in WebKit's JSContextRefPrivate.h). Only builds outside the App
// Store import this module (Apps/iOS/DirectDistribution.swift, under #if !APP_STORE); the functions
// are static inline, so a build that never calls them carries no reference to the symbols at all
// (scripts/check-app-store-symbols verifies that).

#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <JavaScriptCore/JavaScriptCore.h>

typedef bool (*HBShouldTerminateCallback)(JSContextRef context, void *info);

JS_EXPORT void JSContextGroupSetExecutionTimeLimit(JSContextGroupRef group, double limit,
                                                   HBShouldTerminateCallback callback, void *info);
JS_EXPORT void JSContextGroupClearExecutionTimeLimit(JSContextGroupRef group);

/// JavaScriptCore measures its limit in CPU time used by the script's thread, which on a loaded
/// machine runs far slower than the wall clock. So the limit is a short CPU slice; at the end of
/// each slice the callback compares the wall clock with the deadline (carried in `info`) and either
/// stops the script or sets the next slice (JavaScriptCore does not re-arm the limit by itself when
/// the callback returns false).
static const double hb_execution_check_interval = 0.05;

static inline uint64_t hb_monotonic_milliseconds(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000000;
}

static inline bool hb_should_terminate(JSContextRef context, void *info) {
    if (hb_monotonic_milliseconds() >= (uint64_t)(uintptr_t)info) return true;
    JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(context), hb_execution_check_interval,
                                        hb_should_terminate, info);
    return false;
}

/// Stops any script in `context`'s group still running `seconds` of wall-clock time from now.
static inline void hb_set_execution_time_limit(JSGlobalContextRef context, double seconds) {
    uint64_t deadline = hb_monotonic_milliseconds() + (uint64_t)(seconds > 0 ? seconds * 1000 : 0);
    JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(context), hb_execution_check_interval,
                                        hb_should_terminate, (void *)(uintptr_t)deadline);
}

static inline void hb_clear_execution_time_limit(JSGlobalContextRef context) {
    JSContextGroupClearExecutionTimeLimit(JSContextGetGroup(context));
}

#endif
