#pragma once
#include <jsc/jsc.h>

typedef char *(*HummingbirdJSCHostCall)(
    const char *name, const char *first, const char *second, void *context
);

typedef struct {
    HummingbirdJSCHostCall callback;
    void *context;
    GDestroyNotify destroy;
} HummingbirdJSCHostFunction;

static inline char *hummingbird_jsc_host_bridge(
    const char *name, const char *first, const char *second,
    HummingbirdJSCHostFunction *host
) {
    return host->callback(
        name ? name : "", first ? first : "", second ? second : "", host->context
    );
}

static inline void hummingbird_jsc_host_destroy(HummingbirdJSCHostFunction *host) {
    if (host->destroy)
        host->destroy(host->context);
    g_free(host);
}

static inline void hummingbird_jsc_install_host_call(
    JSCContext *context, HummingbirdJSCHostCall callback, void *user_data,
    GDestroyNotify destroy
) {
    HummingbirdJSCHostFunction *host = g_new(HummingbirdJSCHostFunction, 1);
    host->callback = callback;
    host->context = user_data;
    host->destroy = destroy;
    GType parameters[] = { G_TYPE_STRING, G_TYPE_STRING, G_TYPE_STRING };
    JSCValue *function = jsc_value_new_functionv(
        context, "__hostCall", G_CALLBACK(hummingbird_jsc_host_bridge), host,
        (GDestroyNotify)hummingbird_jsc_host_destroy, G_TYPE_STRING, 3, parameters
    );
    jsc_context_set_value(context, "__hostCall", function);
    g_object_unref(function);
}

static inline void hummingbird_jsc_unref(void *object) {
    if (object)
        g_object_unref(object);
}

static inline void hummingbird_jsc_free(void *memory) {
    g_free(memory);
}
