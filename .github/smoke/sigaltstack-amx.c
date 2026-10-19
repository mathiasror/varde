/* LD_PRELOAD shim: make any host look like an AMX one (Intel Xeon 8573C,
 * AT_MINSIGSTKSZ 11952) to the BEAM's alternate-signal-stack setup.
 *
 * musl 1.2.6's sigaltstack() rejects sizes below sysconf(_SC_MINSIGSTKSZ),
 * which it derives as AT_MINSIGSTKSZ + 1024. Unpatched OTP 27 asks for musl's
 * static SIGSTKSZ (8192) and aborts with "Failed to set alternate signal
 * stack"; the patched one (images/patches/otp-27-musl-sigaltstack-size.patch)
 * sizes from sysconf and boots. build.yml's rabbitmq musl smoke runs `erl`
 * under this shim, so the fix is exercised on every runner, not just on the
 * few AMX hosts in GitHub's pool. Every decision is logged to stderr, and the
 * smoke asserts an "accepted" line so a shim that never loaded can't pass.
 *
 * Built with the flake's own pkgsMusl compiler: a musl process cannot
 * preload a glibc object. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

#define AMX_MINSIGSTKSZ (11952 + 1024)

long sysconf(int name) {
    static long (*real)(int);
    if (name == _SC_MINSIGSTKSZ)
        return AMX_MINSIGSTKSZ;
    if (!real)
        real = (long (*)(int))dlsym(RTLD_NEXT, "sysconf");
    return real(name);
}

int sigaltstack(const stack_t *restrict ss, stack_t *restrict old) {
    if (ss && !(ss->ss_flags & SS_DISABLE) && ss->ss_size < AMX_MINSIGSTKSZ) {
        fprintf(stderr, "sigaltstack-amx: rejected size=%zu (< %d)\n",
                ss->ss_size, AMX_MINSIGSTKSZ);
        errno = ENOMEM;
        return -1;
    }
    if (ss)
        fprintf(stderr, "sigaltstack-amx: accepted size=%zu\n", ss->ss_size);
    return syscall(SYS_sigaltstack, ss, old);
}
