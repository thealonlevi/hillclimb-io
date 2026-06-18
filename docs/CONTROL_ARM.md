# Control arm (port 30) — faithful reference-proxy accept clone

This is the FROZEN baseline. It reproduces the accept path of a real, production high-performance
Go proxy (referred to throughout as "the reference proxy") so the comparison against the
io_uring treatment arm is honest and grounded in something that actually runs at scale. The
mechanism below is a standard, well-known high-throughput accept design — `SO_REUSEPORT` accept
fan-out with goroutine-per-connection and an adaptive controller — described here as a build
spec, independent of any particular proprietary source tree.

The control arm does NOT do real proxying — it stops at the fixed-reply contract (read request,
write `REPLY_BYTES`, close). But the **accept mechanism up to and including the goroutine
dispatch** mirrors the reference proxy exactly.

## Listener creation — `net.ListenConfig` + Control hook, options set PRE-BIND

Socket options are applied to **every** reuseport listen socket via the `Control` hook of
`net.ListenConfig` (so they run *before* bind):

| Option | Value |
|--------|-------|
| `SO_REUSEADDR` | 1 |
| `SO_REUSEPORT` | 1 (per socket) |
| `TCP_NODELAY` | 1 (default) |
| `SO_KEEPALIVE` | 1 |
| `TCP_KEEPIDLE` | 60s |
| `TCP_KEEPINTVL` | 10s |
| `TCP_KEEPCNT` | 5 |
| `TCP_FASTOPEN` | 1 (soft-fail if unavailable) |
| listen backlog | **system default** (relies on `net.core.somaxconn`) — NOT set in code |
| `SO_RCVBUF`/`SO_SNDBUF` | **NOT set** on accepted client sockets (Linux) |

## Accept model — one goroutine per reuseport socket, goroutine-per-connection

- **Floor socket count:** `min(GOMAXPROCS, 8)`. For the benchmark, set `GOMAXPROCS == CORES`
  (the pinned core count) so the floor matches the core budget.
- **One goroutine per reuseport socket**, each in a tight `for { c, _ := listener.Accept(); ... }`
  loop. The primary runs inline; secondaries run as background goroutines.
- **After each Accept:** spawn a fresh goroutine per connection — **goroutine-per-connection, no
  worker pool.** This is the defining characteristic of the reference proxy's model and the main
  thing the io_uring arm is contrasted against.

> The reference proxy also does a couple of pre-goroutine fast-reject checks (an IP rate-limiter
> block and a per-IP connection-limit gate) before spawning the goroutine. The benchmark control
> arm **omits** these — they're proxy policy, not accept mechanism, and the treatment arm has no
> equivalent. Keeping them would tax only the control arm and bias the result. Documented here so
> the omission is deliberate, not an oversight.

## Adaptive scaler — TCP_INFO queue probe, double-on-high-water, grow-only

- Every **2s**, probe the deepest accept-queue depth across the reuseport sockets via
  `TCP_INFO` (`tcpi_unacked`, the kernel's `sk_ack_backlog` for a LISTEN socket).
- If the deepest queue ≥ **40** (high-water), **double** the reuseport socket count up to a
  configured max, and never shrink (grow-only).

### Two control configurations to benchmark

1. **`control-frozen`** — scaler DISABLED, socket count fixed at floor. This is the
   apples-to-apples baseline vs the io_uring arm (which has no auto-scaler). **Primary
   comparison.**
2. **`control-adaptive`** — scaler ENABLED exactly as the reference proxy ships it. Shows how the
   real adaptive behavior performs. Reported as a secondary data point.

The optimizer competes against **`control-frozen`** for the headline conn/s-per-core number.

## Runtime / build

- Go (match the reference proxy's toolchain, currently Go 1.25).
- `GOMAXPROCS = CORES`, pinned to the fixed CPU set via `taskset`/cgroup `cpuset`.
- Build: `go build -o control/accept-control ./control/`.
- Run: `cgexec`/`systemd-run` into the fixed cpuset+cgroup, listen on `:30`.

## Validation that the clone is faithful

Before trusting any comparison, confirm the clone matches the reference behavior on a structural
diff: `strace -f -c -e trace=network ./accept-control` under a fixed 5k-conn load should show the
expected syscall *mix per connection* (`accept4`, `read`, `write`, `close`, `epoll_*`) for a
goroutine-per-connection reuseport server. Record this in `results/CONTROL_BASELINE.md` once; if
it drifts, the clone is wrong.
