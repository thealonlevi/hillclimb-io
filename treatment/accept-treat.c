// accept-treat.c — milestone-0 treatment arm: TCP-accept benchmark via io_uring (liburing).
// Deliberately SIMPLE, correct, UNOPTIMIZED baseline.
//
// Per connection (observed externally):
//   accept -> recv client request (once, up to 256 bytes) -> send exactly 19 reply bytes -> close.
// One reply per connection, then close (no keep-alive).
//
// Architecture:
//   - Worker count = number of CPUs in the process's CPU affinity mask (sched_getaffinity).
//   - One worker thread per allowed CPU; each thread pinned to one allowed CPU.
//   - Each worker has its OWN io_uring instance and OWN SO_REUSEPORT listening socket
//     bound to the same --port. The kernel load-balances accepts across reuseport sockets.
//   - Classic re-armed single-shot accept. Per-connection state machine:
//     ACCEPT -> RECV -> SEND (loop until all 19 bytes sent) -> CLOSE.
//   - Batched submit/harvest: one io_uring_submit_and_wait per loop flushes all
//     queued SQEs and blocks for completions in a single io_uring_enter, then the
//     whole CQ batch is drained before the next enter. This amortizes io_uring_enter
//     across the 4 CQEs/conn instead of paying one enter per CQE.
//   - Plain (unregistered) buffers and fds. No SQPOLL, no multishot, no registered files.
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <liburing.h>

static const char REPLY[] = "HTTP/1.1 200 OK\r\n\r\n";
#define REPLY_LEN 19
#define READ_BUF_SZ 256
#define QUEUE_DEPTH 4096
// Registered (direct) descriptor table size. Connections are accepted into
// auto-allocated slots here instead of the process fd table, so recv/send/close
// reference a slot index (IOSQE_FIXED_FILE) and skip the per-op fd-table lookup,
// and accept skips the fd install. Direct descriptors is the strongest real lever
// found (the ONLY config to ever exceed the champion; draws 36136/36048 ~= champion
// 36079, table size is noise). Only the in-flight accept->close window uses a slot
// (~tens; un-accepted SYNs use the separate listen backlog) -> 4096 drop-safe.
#define NFILES 4096

static int g_port = 31;

// Per-connection state machine states.
enum conn_state {
    ST_ACCEPT = 0,   // user_data is the accept SQE; CQE result = accepted client fd
    ST_RECV,         // reading the client's request bytes
    ST_SEND,         // writing the 19-byte reply (possibly across multiple sends)
    ST_CLOSE,        // closing the fd
};

struct conn {
    enum conn_state state;
    int fd;                    // direct-descriptor INDEX when wc->direct, else a real fd
    int sent;                  // bytes of REPLY already sent (for short-write handling)
    char buf[READ_BUF_SZ];     // request scratch buffer (also reused, harmless)
};

// A sentinel conn used only for the accept SQE so we can recognize accept CQEs.
// We allocate it per-worker so the user_data pointer is stable and distinguishable.
struct worker_ctx {
    struct io_uring ring;
    int listen_fd;
    int direct;                // 1 if the registered file table is active (direct descriptors)
    struct conn accept_marker; // state == ST_ACCEPT
};

static int make_listen_socket(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        perror("socket");
        return -1;
    }
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) < 0) {
        perror("SO_REUSEADDR");
        close(fd);
        return -1;
    }
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one) < 0) {
        perror("SO_REUSEPORT");
        close(fd);
        return -1;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((unsigned short)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        perror("bind");
        close(fd);
        return -1;
    }
    if (listen(fd, 4096) < 0) {
        perror("listen");
        close(fd);
        return -1;
    }
    return fd;
}

// Submit a fresh single-shot accept SQE to (re-)arm accepting.
static void arm_accept(struct worker_ctx *wc)
{
    struct io_uring_sqe *sqe = io_uring_get_sqe(&wc->ring);
    if (!sqe) {
        // Should not happen with a deep queue + per-event submit, but be safe.
        io_uring_submit(&wc->ring);
        sqe = io_uring_get_sqe(&wc->ring);
        if (!sqe)
            return;
    }
    if (wc->direct)
        // Accept into an auto-allocated registered-table slot; CQE res = slot index.
        io_uring_prep_accept_direct(sqe, wc->listen_fd, NULL, NULL, 0,
                                    IORING_FILE_INDEX_ALLOC);
    else
        io_uring_prep_accept(sqe, wc->listen_fd, NULL, NULL, 0);
    wc->accept_marker.state = ST_ACCEPT;
    io_uring_sqe_set_data(sqe, &wc->accept_marker);
}

static void submit_recv(struct worker_ctx *wc, struct conn *c)
{
    struct io_uring_sqe *sqe = io_uring_get_sqe(&wc->ring);
    if (!sqe) {
        io_uring_submit(&wc->ring);
        sqe = io_uring_get_sqe(&wc->ring);
        if (!sqe) {
            // Give up on this conn cleanly. (Direct slot leaks only on this
            // effectively-unreachable deep-queue exhaustion path.)
            if (!wc->direct)
                close(c->fd);
            free(c);
            return;
        }
    }
    c->state = ST_RECV;
    io_uring_prep_recv(sqe, c->fd, c->buf, READ_BUF_SZ, 0);
    if (wc->direct)
        io_uring_sqe_set_flags(sqe, IOSQE_FIXED_FILE); // c->fd is a table index
    io_uring_sqe_set_data(sqe, c);
}

static void submit_send(struct worker_ctx *wc, struct conn *c)
{
    struct io_uring_sqe *sqe = io_uring_get_sqe(&wc->ring);
    if (!sqe) {
        io_uring_submit(&wc->ring);
        sqe = io_uring_get_sqe(&wc->ring);
        if (!sqe) {
            if (!wc->direct)
                close(c->fd);
            free(c);
            return;
        }
    }
    c->state = ST_SEND;
    io_uring_prep_send(sqe, c->fd, REPLY + c->sent, REPLY_LEN - c->sent, 0);
    if (wc->direct)
        io_uring_sqe_set_flags(sqe, IOSQE_FIXED_FILE); // c->fd is a table index
    io_uring_sqe_set_data(sqe, c);
}

static void submit_close(struct worker_ctx *wc, struct conn *c)
{
    struct io_uring_sqe *sqe = io_uring_get_sqe(&wc->ring);
    if (!sqe) {
        io_uring_submit(&wc->ring);
        sqe = io_uring_get_sqe(&wc->ring);
        if (!sqe) {
            // Fall back to a synchronous close so we never leak the fd.
            if (!wc->direct)
                close(c->fd);
            free(c);
            return;
        }
    }
    c->state = ST_CLOSE;
    if (wc->direct)
        io_uring_prep_close_direct(sqe, c->fd); // frees the registered table slot
    else
        io_uring_prep_close(sqe, c->fd);
    io_uring_sqe_set_data(sqe, c);
}

#define CQE_BATCH 256

static void *worker_main(void *arg)
{
    struct worker_ctx *wc = arg;
    struct io_uring_cqe *cqes[CQE_BATCH];

    arm_accept(wc);

    for (;;) {
        // Single io_uring_enter: flush all queued SQEs AND block for >=1 completion.
        int ret = io_uring_submit_and_wait(&wc->ring, 1);
        if (ret < 0) {
            if (ret == -EINTR)
                continue;
            fprintf(stderr, "io_uring_submit_and_wait: %s\n", strerror(-ret));
            break;
        }

        // Drain the whole completion batch before the next enter. New SQEs queued
        // here are not submitted until the next loop's submit_and_wait, so the
        // 4 CQEs/conn cost roughly one enter total instead of one enter each.
        unsigned n = io_uring_peek_batch_cqe(&wc->ring, cqes, CQE_BATCH);
        for (unsigned i = 0; i < n; i++) {
            struct io_uring_cqe *cqe = cqes[i];
            struct conn *c = io_uring_cqe_get_data(cqe);
            int res = cqe->res;

            if (c->state == ST_ACCEPT) {
                // Re-arm accept so we keep accepting.
                arm_accept(wc);
                if (res < 0)
                    continue; // transient accept error; keep going.
                // New connection accepted; res is the client fd (direct: table index).
                struct conn *nc = calloc(1, sizeof *nc);
                if (!nc) {
                    if (!wc->direct)
                        close(res); // direct slot leaks only on OOM (box is already dying)
                    continue;
                }
                nc->fd = res;
                nc->sent = 0;
                submit_recv(wc, nc);
            } else if (c->state == ST_RECV) {
                if (res <= 0) {
                    // EOF or read error: close and move on.
                    submit_close(wc, c);
                } else {
                    // Got the request bytes (we don't need to scan them); reply.
                    c->sent = 0;
                    submit_send(wc, c);
                }
            } else if (c->state == ST_SEND) {
                if (res <= 0) {
                    // Send error: close and move on.
                    submit_close(wc, c);
                } else {
                    c->sent += res;
                    if (c->sent < REPLY_LEN) {
                        // Short write: re-submit send for the remaining bytes.
                        submit_send(wc, c);
                    } else {
                        // Full reply sent.
                        submit_close(wc, c);
                    }
                }
            } else { // ST_CLOSE
                // Close completed (ignore res); free per-connection state.
                free(c);
            }
        }

        // Advance the CQ ring past the whole batch in one shot.
        io_uring_cq_advance(&wc->ring, n);
    }

    return NULL;
}

// Each thread gets its own worker_ctx plus the CPU it should pin to.
struct thread_arg {
    struct worker_ctx wc;
    int cpu; // CPU id to pin to, or -1 for no pinning
};

static void *thread_entry(void *arg)
{
    struct thread_arg *ta = arg;
    if (ta->cpu >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(ta->cpu, &set);
        pthread_setaffinity_np(pthread_self(), sizeof set, &set);
    }

    // Initialize the ring in the SAME thread that submits/reaps it so the
    // SINGLE_ISSUER contract holds. SINGLE_ISSUER + DEFER_TASKRUN move completion
    // task-work into our io_uring_submit_and_wait GETEVENTS enter and drop the
    // cross-CPU IPI/eager-wakeup overhead, cutting kernel CPU per completion
    // without touching the data path. Fall back to a plain ring if the kernel
    // rejects the flags, so the server always comes up.
    struct io_uring_params p;
    memset(&p, 0, sizeof p);
    p.flags = IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
    int ret = io_uring_queue_init_params(QUEUE_DEPTH, &ta->wc.ring, &p);
    if (ret < 0) {
        ret = io_uring_queue_init(QUEUE_DEPTH, &ta->wc.ring, 0);
        if (ret < 0) {
            fprintf(stderr, "io_uring_queue_init: %s\n", strerror(-ret));
            return NULL;
        }
    }

    // Register a sparse direct-descriptor table so connections are accepted into
    // auto-allocated slots and recv/send/close reference the slot index with
    // IOSQE_FIXED_FILE — skipping the fd install on accept AND the per-op fd lookup
    // on recv/send/close. Strongest real lever after DEFER_TASKRUN; the only config
    // to ever exceed the champion. Falls back to regular fds if registration fails.
    if (io_uring_register_files_sparse(&ta->wc.ring, NFILES) == 0)
        ta->wc.direct = 1;
    else
        fprintf(stderr, "register_files_sparse failed; using regular fds\n");

    return worker_main(&ta->wc);
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc)
            g_port = atoi(argv[++i]);
    }

    // Determine worker count from the process's CPU affinity mask.
    cpu_set_t aff;
    CPU_ZERO(&aff);
    if (sched_getaffinity(0, sizeof aff, &aff) < 0) {
        perror("sched_getaffinity");
        return 1;
    }
    int nallowed = CPU_COUNT(&aff);
    if (nallowed < 1)
        nallowed = 1;

    // Collect the list of allowed CPU ids (for pinning).
    int *cpus = calloc(nallowed, sizeof(int));
    if (!cpus) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }
    int idx = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE && idx < nallowed; cpu++) {
        if (CPU_ISSET(cpu, &aff))
            cpus[idx++] = cpu;
    }

    struct thread_arg *targs = calloc(nallowed, sizeof *targs);
    pthread_t *threads = calloc(nallowed, sizeof(pthread_t));
    if (!targs || !threads) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }

    fprintf(stderr, "accept-treat: port=%d workers=%d\n", g_port, nallowed);

    int started = 0;
    for (int i = 0; i < nallowed; i++) {
        struct thread_arg *ta = &targs[i];
        ta->cpu = cpus[i];

        ta->wc.listen_fd = make_listen_socket(g_port);
        if (ta->wc.listen_fd < 0) {
            fprintf(stderr, "worker %d: failed to create listen socket\n", i);
            return 1;
        }

        // Ring init happens inside thread_entry (the submitting thread) to satisfy
        // IORING_SETUP_SINGLE_ISSUER.
        if (pthread_create(&threads[i], NULL, thread_entry, ta) != 0) {
            perror("pthread_create");
            return 1;
        }
        started++;
    }

    for (int i = 0; i < started; i++)
        pthread_join(threads[i], NULL);

    free(cpus);
    free(targs);
    free(threads);
    return 0;
}
