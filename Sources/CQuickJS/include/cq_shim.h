// Swift cannot import QuickJS's compound-literal macros, so the few it needs are wrapped here.
#ifndef CQ_SHIM_H
#define CQ_SHIM_H
#include "quickjs.h"

static inline JSValue cq_undefined(void) { return JS_UNDEFINED; }
static inline JSValue cq_null(void) { return JS_NULL; }
static inline int cq_eval_global(void) { return JS_EVAL_TYPE_GLOBAL; }
#endif
