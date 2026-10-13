#include "CMainThreadSampler.h"

#if defined(__APPLE__) && defined(__arm64__)
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <ptrauth.h>

static uint64_t hb_strip_code_pointer(uint64_t address) {
    return (uint64_t)ptrauth_strip((void *)address, ptrauth_key_return_address);
}

static mach_port_t hb_main_thread = MACH_PORT_NULL;

void hb_sampler_set_main_thread(void) {
    if (hb_main_thread != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), hb_main_thread);
    hb_main_thread = mach_thread_self();
}

int hb_sampler_capture(uint64_t *addresses, int capacity) {
    if (hb_main_thread == MACH_PORT_NULL || capacity <= 0) return 0;
    if (thread_suspend(hb_main_thread) != KERN_SUCCESS) return 0;

    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t result = thread_get_state(hb_main_thread, ARM_THREAD_STATE64,
                                             (thread_state_t)&state, &count);
    if (result != KERN_SUCCESS) {
        thread_resume(hb_main_thread);
        return 0;
    }

    int output = 0;
    addresses[output++] = hb_strip_code_pointer(arm_thread_state64_get_pc(state));
    uint64_t link = hb_strip_code_pointer(arm_thread_state64_get_lr(state));
    if (link && output < capacity) addresses[output++] = link;

    uint64_t frame = arm_thread_state64_get_fp(state);
    const uint64_t first_frame = frame;
    while (frame && output < capacity) {
        struct { uint64_t previous; uint64_t return_address; } record;
        vm_size_t copied = 0;
        result = vm_read_overwrite(mach_task_self(), (vm_address_t)frame,
                                   sizeof(record), (vm_address_t)&record, &copied);
        if (result != KERN_SUCCESS || copied != sizeof(record) || !record.return_address) break;
        addresses[output++] = hb_strip_code_pointer(record.return_address);
        if (record.previous <= frame || record.previous - first_frame > 8 * 1024 * 1024) break;
        frame = record.previous;
    }
    thread_resume(hb_main_thread);
    return output;
}
#else
void hb_sampler_set_main_thread(void) {}
int hb_sampler_capture(uint64_t *addresses, int capacity) { return 0; }
#endif
