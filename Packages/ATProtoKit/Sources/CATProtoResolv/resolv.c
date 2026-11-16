#include "CATProtoResolv.h"

#if defined(__linux__)
#include <arpa/nameser.h>
#include <netdb.h>
#include <netinet/in.h>
#include <resolv.h>
#include <stdlib.h>
#include <string.h>

int atproto_resolv_query_txt(const char *name, atproto_resolv_txt_rdata each, void *context) {
    struct __res_state state;
    memset(&state, 0, sizeof state);
    if (res_ninit(&state) != 0) return -1;

    // The largest possible DNS message; TXT answers can exceed 512 bytes, in
    // which case libresolv retries over TCP.
    enum { answer_capacity = 65535 };
    unsigned char *answer = malloc(answer_capacity);
    if (!answer) {
        res_nclose(&state);
        return -1;
    }
    int result = -1;
    int length = res_nquery(&state, name, ns_c_in, ns_t_txt, answer, answer_capacity);
    if (length < 0) {
        // A definite negative answer is not a failure: there just is no record.
        int error = state.res_h_errno;
        result = (error == HOST_NOT_FOUND || error == NO_DATA) ? 0 : -1;
    } else {
        ns_msg message;
        if (ns_initparse(answer, length, &message) == 0) {
            result = 0;
            int count = ns_msg_count(message, ns_s_an);
            for (int index = 0; index < count; index++) {
                ns_rr record;
                if (ns_parserr(&message, ns_s_an, index, &record) != 0) {
                    result = -1;
                    break;
                }
                if (ns_rr_type(record) == ns_t_txt && ns_rr_class(record) == ns_c_in)
                    each(ns_rr_rdata(record), ns_rr_rdlen(record), context);
            }
        }
    }
    free(answer);
    res_nclose(&state);
    return result;
}
#else
int atproto_resolv_query_txt(const char *name, atproto_resolv_txt_rdata each, void *context) {
    (void)name; (void)each; (void)context;
    return -1;
}
#endif
