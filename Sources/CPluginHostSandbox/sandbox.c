#include "CPluginHostSandbox.h"

#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/syscall.h>

#if defined(__x86_64__)
#define HB_ARCH AUDIT_ARCH_X86_64
#else
#define HB_ARCH AUDIT_ARCH_AARCH64
#endif

#define HB_DENY BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA))
#define HB_LOAD_NR BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr))
/* Refuse syscall `nr` outright. */
#define HB_REFUSE(nr) BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (nr), 0, 1), HB_DENY
/* Refuse syscall `nr` when its flags argument asks to write or create. */
#define HB_WRITE_FLAGS (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND)
#define HB_REFUSE_WRITING(nr, arg) \
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (nr), 0, 4), \
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[arg])), \
    BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, HB_WRITE_FLAGS, 0, 1), \
    HB_DENY, \
    HB_LOAD_NR

int hb_plugin_host_sandbox(void) {
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, HB_ARCH, 1, 0),
        HB_DENY, /* another ABI (x32, i386 compat): nothing */
        HB_LOAD_NR,
        HB_REFUSE(__NR_socket), HB_REFUSE(__NR_socketpair), HB_REFUSE(__NR_connect), HB_REFUSE(__NR_bind),
        HB_REFUSE(__NR_listen), HB_REFUSE(__NR_accept), HB_REFUSE(__NR_accept4), HB_REFUSE(__NR_sendto),
        HB_REFUSE(__NR_sendmsg), HB_REFUSE(__NR_execve), HB_REFUSE(__NR_execveat), HB_REFUSE(__NR_ptrace),
        HB_REFUSE(__NR_process_vm_writev), HB_REFUSE(__NR_process_vm_readv),
        HB_REFUSE(__NR_unlinkat), HB_REFUSE(__NR_renameat2), HB_REFUSE(__NR_mkdirat), HB_REFUSE(__NR_truncate),
        HB_REFUSE(__NR_linkat), HB_REFUSE(__NR_symlinkat),
#if defined(__x86_64__)
        HB_REFUSE(__NR_creat), HB_REFUSE(__NR_unlink), HB_REFUSE(__NR_rename), HB_REFUSE(__NR_renameat),
        HB_REFUSE(__NR_mkdir), HB_REFUSE(__NR_rmdir), HB_REFUSE(__NR_link), HB_REFUSE(__NR_symlink),
        HB_REFUSE(__NR_fork), HB_REFUSE(__NR_vfork),
        HB_REFUSE_WRITING(__NR_open, 1),
#else
        HB_REFUSE(__NR_renameat),
#endif
        HB_REFUSE_WRITING(__NR_openat, 2),
#ifdef __NR_openat2
        HB_REFUSE(__NR_openat2), /* its flags live behind a pointer the filter cannot read */
#endif
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = { .len = (unsigned short)(sizeof(filter) / sizeof(filter[0])), .filter = filter };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) != 0) return -1;
    return 0;
}

#else
int hb_plugin_host_sandbox(void) { return -1; }
#endif
