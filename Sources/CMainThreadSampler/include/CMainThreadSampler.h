#ifndef C_MAIN_THREAD_SAMPLER_H
#define C_MAIN_THREAD_SAMPLER_H

#include <stdint.h>

void hb_sampler_set_main_thread(void);
int hb_sampler_capture(uint64_t *addresses, int capacity);

#endif
