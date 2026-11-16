#pragma once
#include <stddef.h>

/// Receives the RDATA of one TXT answer record.
typedef void (*atproto_resolv_txt_rdata)(const unsigned char *rdata, size_t length, void *context);

/// Queries the system's unicast DNS resolver (libresolv) for TXT records at
/// `name` and calls `each` once per TXT answer. Returns 0 when the query was
/// answered, including when the name or record does not exist, and -1 when
/// the resolver failed (no server, timeout, malformed answer).
/// Only implemented on Linux; Apple platforms use dnssd instead.
int atproto_resolv_query_txt(const char *name, atproto_resolv_txt_rdata each, void *context);
