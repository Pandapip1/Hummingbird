#ifndef CJSCEXECUTIONLIMIT_H
#define CJSCEXECUTIONLIMIT_H

// JavaScriptCore's script time limit. These two functions are exported by JavaScriptCore but are
// not public API (they are declared in WebKit's JSContextRefPrivate.h). Only builds outside the App
// Store import this module (Apps/iOS/DirectDistribution.swift, under #if !APP_STORE); the functions
// are static inline, so a build that never calls them carries no reference to the symbols at all
// (scripts/check-app-store-symbols verifies that).

#include <stdbool.h>
#include <JavaScriptCore/JavaScriptCore.h>

typedef bool (*HBShouldTerminateCallback)(JSContextRef context, void *info);

JS_EXPORT void JSContextGroupSetExecutionTimeLimit(JSContextGroupRef group, double limit,
                                                   HBShouldTerminateCallback callback, void *info);
JS_EXPORT void JSContextGroupClearExecutionTimeLimit(JSContextGroupRef group);

static inline bool hb_should_terminate(JSContextRef context, void *info) {
    (void)context;
    (void)info;
    return true;
}

/// Stops any script in `context`'s group that runs longer than `seconds`.
static inline void hb_set_execution_time_limit(JSGlobalContextRef context, double seconds) {
    JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(context), seconds, hb_should_terminate, 0);
}

static inline void hb_clear_execution_time_limit(JSGlobalContextRef context) {
    JSContextGroupClearExecutionTimeLimit(JSContextGetGroup(context));
}

#endif
