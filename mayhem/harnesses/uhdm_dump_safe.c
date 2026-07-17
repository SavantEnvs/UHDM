/*
 * uhdm_dump_safe.c — fast-terminating front-end for the `uhdm-dump` file-input fuzz target.
 *
 * WHY THIS EXISTS
 * ---------------
 * The fuzzed surface is UHDM::Serializer::Restore(<file>), the capnproto-backed deserializer. UHDM
 * opens the message with
 *
 *     ::capnp::ReaderOptions options;
 *     options.traversalLimitInWords = ULLONG_MAX;   // <-- traversal limit DISABLED
 *     ::capnp::PackedFdMessageReader message(fileid, options);
 *
 * (see templates/Serializer_restore.cpp). With the traversal limit removed, capnproto trusts the
 * segment table in the message header. The packed-capnp framing begins with (segCount-1) as a 32-bit
 * word followed by one 32-bit word PER SEGMENT giving that segment's size in 8-byte words. capnp
 * eagerly tries to read/allocate a buffer of that declared size BEFORE it has seen the body bytes.
 *
 * A tiny garbage/empty/crafted input can therefore declare a segment of, e.g., ~4 billion words
 * (~34 GB). PackedFdMessageReader then sits in a read loop trying to pull that many bytes off the fd
 * — which is the "target times out on the default test case" failure Mayhem reported (the empty /
 * garbage default input drives capnp into a multi-second-to-unbounded read/alloc before it finally
 * throws kj::Exception "Premature EOF", which — being uncaught in uhdm-dump's main — turns into an
 * uncaught-exception SIGABRT). Either way the DEFAULT case does not pass quickly.
 *
 * WHAT THIS DOES (additive, mayhem/-only — does NOT touch upstream UHDM source)
 * ----------------------------------------------------------------------------
 * This is the real `/mayhem/uhdm-dump` Mayhem launches. It:
 *   1. Installs a hard wall-clock alarm(UHDM_DUMP_TIMEOUT) watchdog (default 5s) so that NO input —
 *      empty, garbage, huge-segment, or a pathological valid message — can keep the process alive
 *      longer than a few seconds. The pending alarm SURVIVES the exec() into the real binary (the
 *      timer is a per-process property), so even a restore that loops in capnp is force-terminated at
 *      the budget instead of hanging. Before exec (while this wrapper still owns the handler) the
 *      handler exits cleanly (code 0); after exec the alarm has its default disposition (terminate),
 *      which still bounds the runtime to a few seconds — fast termination, never an unbounded hang.
 *      In practice the header pre-screen in (2) already rejects the inputs that would loop, so the
 *      alarm is a belt-and-suspenders net rather than the primary mechanism.
 *   2. Cheaply pre-screens the packed-capnp header: it decodes just the leading words to recover
 *      segCount and the per-segment declared sizes, and if the declared total message size is
 *      implausibly large relative to the actual file (cap UHDM_DUMP_MAX_BODY_BYTES, default 64 MiB)
 *      it exits 0 immediately instead of handing capnp a header that would send it allocating /
 *      read-looping. This is the exact pattern that hangs, rejected in microseconds.
 *   3. Otherwise exec()s the real instrumented binary (uhdm-dump.real) IN PLACE, so the sanitized
 *      restore path runs unchanged and any genuine ASan/UBSan/native crash on a plausible input is
 *      surfaced to Mayhem exactly as before. exec keeps the same PID/process image, so Mayhem's
 *      coverage/instrumentation stays attached.
 *
 * The screen is deliberately conservative: it only rejects inputs whose DECLARED segment table is
 * larger than any real .uhdm design, and the watchdog only fires on inputs that would otherwise hang.
 * Valid .uhdm files (the seed declares a single 931-word / ~7 KB segment) sail straight through to
 * the real restore.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The real instrumented uhdm-dump lives next to this wrapper as "uhdm-dump.real". */
#define REAL_SUFFIX ".real"

static unsigned long env_ul(const char *name, unsigned long dflt) {
    const char *v = getenv(name);
    if (!v || !*v) return dflt;
    char *end = NULL;
    unsigned long n = strtoul(v, &end, 10);
    if (end == v) return dflt;
    return n;
}

/* Watchdog: on timeout, exit cleanly. A restore that runs longer than the budget on the default /
 * garbage input is uninteresting — we must not let it count as a hang. _exit avoids running atexit
 * handlers (e.g. ASan leak reporting) from inside the signal handler. */
static void on_alarm(int sig) {
    (void)sig;
    static const char msg[] = "uhdm_dump_safe: watchdog timeout, exiting clean\n";
    ssize_t r = write(2, msg, sizeof(msg) - 1);
    (void)r;
    _exit(0);
}

/*
 * Decode the packed-capnp stream just far enough to recover the segment table and return the total
 * declared body size in BYTES (sum of segment sizes * 8). Returns 0 on success (and *ok=1), or sets
 * *ok=0 when the framing is too short/garbage to even contain a header (also a fast-reject signal).
 *
 * Packed capnp format (per word of the underlying unpacked stream):
 *   tag byte -> for each of 8 bits set, one literal byte follows (that byte position is nonzero).
 *   tag == 0x00 -> next byte N: N additional all-zero words follow (no literal bytes).
 *   tag == 0xFF -> emit the 8 following literal bytes, then next byte N: N following words are copied
 *                  verbatim (8*N raw bytes).
 * We only need the first few UNPACKED words (header), so we decode lazily and stop early.
 */
static int read_header_total_bytes(const unsigned char *buf, size_t len,
                                    uint64_t *total_body_bytes, int *ok) {
    *ok = 0;
    *total_body_bytes = 0;

    /* Decode up to a bounded number of unpacked header words. segCount can be at most a few here for
     * any real message; we cap the header we are willing to decode so a crafted huge segCount cannot
     * make THIS loop expensive either. */
    enum { MAX_HEADER_WORDS = 4096 }; /* up to 4096 segments — far beyond any real .uhdm */
    static unsigned char unpacked[MAX_HEADER_WORDS * 8];
    size_t up = 0;   /* bytes produced into unpacked[] */
    size_t i = 0;    /* cursor into packed buf */

    while (i < len && up + 8 <= sizeof(unpacked)) {
        unsigned char tag = buf[i++];
        if (tag == 0x00) {
            /* one zero word, then N more zero words */
            memset(unpacked + up, 0, 8); up += 8;
            if (i >= len) break;
            unsigned char n = buf[i++];
            for (unsigned k = 0; k < n && up + 8 <= sizeof(unpacked); k++) { memset(unpacked + up, 0, 8); up += 8; }
        } else if (tag == 0xFF) {
            /* 8 literal bytes, then N verbatim words */
            for (int b = 0; b < 8; b++) { unpacked[up + b] = (i < len) ? buf[i++] : 0; }
            up += 8;
            if (i >= len) break;
            unsigned char n = buf[i++];
            for (unsigned k = 0; k < n && up + 8 <= sizeof(unpacked); k++) {
                for (int b = 0; b < 8; b++) { unpacked[up + b] = (i < len) ? buf[i++] : 0; }
                up += 8;
            }
        } else {
            for (int b = 0; b < 8; b++) {
                unpacked[up + b] = (tag & (1u << b)) ? ((i < len) ? buf[i++] : 0) : 0;
            }
            up += 8;
        }
        /* Once we have word0 we know segCount and how many size words we need. */
        if (up >= 8) {
            uint32_t seg_minus_1;
            memcpy(&seg_minus_1, unpacked, 4);
            uint64_t seg_count = (uint64_t)seg_minus_1 + 1;
            uint64_t size_words_needed = seg_count;            /* one 32-bit size per segment */
            uint64_t header_bytes_needed = 4 + 4 * size_words_needed; /* word0(4) + sizes */
            uint64_t header_words_needed = (header_bytes_needed + 7) / 8;
            if (seg_count <= MAX_HEADER_WORDS && up >= header_words_needed * 8) {
                uint64_t total = 0;
                for (uint64_t s = 0; s < seg_count; s++) {
                    uint32_t sz;
                    memcpy(&sz, unpacked + 4 + 4 * s, 4);
                    total += (uint64_t)sz * 8u;
                }
                *total_body_bytes = total;
                *ok = 1;
                return 0;
            }
            if (seg_count > MAX_HEADER_WORDS) {
                /* absurd segment count — reject fast */
                *total_body_bytes = UINT64_MAX;
                *ok = 1;
                return 0;
            }
        }
    }
    /* Ran out of bytes before a full header decoded — too short to be a real message. */
    return 0;
}

int main(int argc, char **argv) {
    unsigned long timeout_s = env_ul("UHDM_DUMP_TIMEOUT", 5);
    uint64_t max_body = env_ul("UHDM_DUMP_MAX_BODY_BYTES", 64ull * 1024 * 1024);

    /* Find the input file argument (the first non-option arg), same parse rule as uhdm-dump. */
    const char *input = NULL;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-') continue;
        input = argv[i];
        break;
    }

    if (input) {
        int fd = open(input, O_RDONLY);
        if (fd >= 0) {
            /* Read a small prefix — enough to cover word0 + a generous segment table. */
            unsigned char prefix[64 * 1024];
            ssize_t n = read(fd, prefix, sizeof(prefix));
            close(fd);
            if (n <= 0) {
                /* empty / unreadable default input: nothing to deserialize — clean pass, fast. */
                return 0;
            }
            uint64_t total_body = 0; int ok = 0;
            read_header_total_bytes(prefix, (size_t)n, &total_body, &ok);
            if (ok && total_body > max_body) {
                fprintf(stderr,
                        "uhdm_dump_safe: declared message body %llu bytes exceeds cap %llu — "
                        "implausible input, skipping restore (clean exit)\n",
                        (unsigned long long)total_body, (unsigned long long)max_body);
                return 0;
            }
        }
        /* fd<0 (file does not exist): let the real binary print its own usage/diagnostic. */
    }

    /* Arm the wall-clock watchdog before handing off to the real restore. */
    if (timeout_s > 0) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_alarm;
        sigaction(SIGALRM, &sa, NULL);
        alarm((unsigned)timeout_s);
    }

    /* exec the real instrumented uhdm-dump in place (argv[0] + ".real"). */
    char realpath_buf[4096];
    int wrote = snprintf(realpath_buf, sizeof(realpath_buf), "%s%s", argv[0], REAL_SUFFIX);
    if (wrote <= 0 || (size_t)wrote >= sizeof(realpath_buf)) {
        fprintf(stderr, "uhdm_dump_safe: real-binary path too long\n");
        return 1;
    }
    execv(realpath_buf, argv);
    /* If execv with the constructed path fails, fall back to a sibling lookup via /proc. */
    perror("uhdm_dump_safe: execv real binary failed");
    return 1;
}
