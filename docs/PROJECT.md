# accept-bench — an optimizable TCP-accept efficiency benchmark

## Purpose

Measure, fairly, how CPU-efficiently a program can accept TCP connections and serve a
trivial fixed reply at high connection churn — and provide a **frozen control** (a faithful
clone of the reference proxy's accept path) against which an **autonomous optimizer agent** can iterate
an io_uring-based implementation until it reaches an empirical optimum.

This document is the contract. The optimizer agent is allowed to change **only** the files
under `treatment/`. Everything else is the fixed "rules of the game."

---

## The two arms

| Arm | Port | Role | Who owns it |
|-----|------|------|-------------|
| **Control** | 30 | Faithful reimplementation of the reference proxy's accept mechanism (Go, SO_REUSEPORT, goroutine-per-conn). The baseline. | FROZEN — never edited during optimization. |
| **Treatment** | 31 | C + liburing. Same observable behavior, free internal design. The thing being optimized. | The optimizer agent edits this. |

They are benchmarked **sequentially** on the **same box** (port 30 first, port 31 later),
each pinned to the **same CPU set**, with the load generator on a **second box**. Same NIC,
same IRQ routing, same kernel, no cross-arm scheduler contention.

---

## The fixed behavioral contract (both arms MUST satisfy this)

Per connection, observed from the outside, each arm does exactly:

1. `accept()` the connection.
2. Read the client's request bytes up to and including the first `\r\n\r\n` (the harness
   client sends a fixed small request; arms may read a fixed number of bytes instead of
   scanning, as long as they consume the request).
3. Write **the exact fixed reply** (see `REPLY_BYTES` below), in full.
4. Close the connection (or honor keep-alive — see note).

`REPLY_BYTES` (19 bytes, byte-for-byte — this mirrors the reference proxy's CONNECT success line so the
control arm is literally the reference proxy's response):

```
HTTP/1.1 200 OK\r\n\r\n
```

The load generator validates that it received **exactly** these bytes on every sampled
connection. Any deviation (truncation, extra bytes, wrong bytes) fails the run.

> **Keep-alive note:** the default contract is **one reply per connection, then close**
> (connection *churn* is what we're measuring). Keep-alive/pipelining is OUT OF SCOPE for v1
> — the load generator opens a fresh TCP connection per request. An arm that tries to hold
> connections open to inflate its number will fail the completion audit (it won't be closing
> at the offered rate).

---

## The scoring function (FIXED — the agent optimizes against this, cannot change it)

### Objective

```
SCORE = max_sustained_conn_per_sec / CORES
```

`CORES` is fixed and identical for both arms (the pinned CPU set). So in practice the agent
is maximizing **max sustained conn/s at a fixed core budget** — i.e. CPU efficiency, which is
the whole point.

### What "max sustained conn/s" means (the ceiling rule)

The harness ramps offered load and declares a config has hit its ceiling when **either**
signal trips (whichever comes first):

1. **Accept-queue backpressure.** The kernel accept-queue depth on the listening sockets
   exceeds a threshold and stays there. Measured two ways, both must stay healthy:
   - control arm: `TCP_INFO.tcpi_unacked` per reuseport socket (same probe the reference proxy uses), or
     `ss -ltn` `Recv-Q`.
   - treatment arm: same `ss -ltn` `Recv-Q` on its listeners.
   - **Threshold:** sustained max queue depth `> QUEUE_HIGH` (default 40, matching the reference proxy's
     high-water) across a measurement window = backpressure.
2. **Fixed-CPU saturation.** The pinned cores reach ~100% utilization (cgroup `cpu.stat`
   `usage_usec` delta ≈ `CORES × wall_seconds × 0.98`). Once saturated, offering more load
   cannot raise *completed* conn/s — that plateau is the ceiling.

The **max sustained conn/s** is the highest offered rate at which the config ran a full
measurement window with: queue below threshold **OR** (if CPU-saturated) completion rate not
yet declining, **and** the correctness gate passing. The harness reports the conn/s at that
operating point.

### The ramp

Offered load steps: `1k → 2k → 5k → 8k → 10k → 12k → 15k → 20k …` conn/s (configurable in
`harness/ramp.conf`). Each step runs a `WARMUP` window then a `MEASURE` window. The benchmark
target you named is **10,000 conn/s**; the ramp goes past it so we can find the actual ceiling
above 10k, not just confirm 10k passes.

---

## The correctness gate (anti-cheat — runs every benchmarked step)

A step's score counts **only if all three pass**. Any failure ⇒ that step's score = 0 and the
ramp stops (the config cannot sustain that rate honestly).

1. **Exact reply bytes.** Every sampled completed connection received `REPLY_BYTES`
   byte-for-byte. (The load gen samples at least `SAMPLE_PCT`, default 5%, of connections for
   full-payload validation; the rest are checked for correct length + first/last byte.)
2. **Completion audit.** A full handshake = `connect → send request → recv exact reply →
   clean close`. At least `SAMPLE_PCT` of connections are followed end-to-end and must
   complete correctly.
3. **Drop ceiling.** Connection failures (refused, reset, timeout, truncated) `< 0.01%` of
   offered connections over the measure window.

This is what stops the optimizer from "winning" by accepting-and-immediately-closing, by
truncating the reply, or by silently shedding a slice of load.

---

## What the optimizer agent MAY change (treatment surface)

Everything inside `treatment/` that still compiles and passes the contract + gate. Examples of
the design space (the agent explores this; we do not pre-decide):

- ring topology: one ring per pinned core vs shared ring(s)
- `IORING_OP_ACCEPT` multishot vs re-armed single-shot
- `SQPOLL` (kernel submission polling) on/off, and its dedicated-core cost tradeoff
- registered files (`IORING_REGISTER_FILES` / direct descriptors) and registered buffers
  (`IORING_OP_PROVIDE_BUFFERS` / ring-mapped buffers)
- SQE linking (`IOSQE_IO_LINK`) to chain accept→read→write→close
- batch sizes for `io_uring_enter`, CQE harvest batching
- `SO_REUSEPORT` socket count, `SO_ATTACH_REUSEPORT_CBPF` steering
- NAPI busy-poll (`SO_BUSY_POLL` / `io_uring` NAPI), `TCP_NODELAY`, deferred accept
- listen backlog, per-core memory pools, cache-line layout of hot structs
- thread count and CPU pinning **within the fixed core set**

## What the agent MAY NOT change (fixed)

- the scoring function, ramp definition, or correctness gate
- `REPLY_BYTES` or the behavioral contract
- the control arm (`control/`)
- the load generator (`loadgen/`) and harness (`harness/`)
- the pinned core count `CORES`, the cgroup limits, or which box runs what
- the kernel / sysctl baseline (recorded once, identical for every run — see ENVIRONMENT.md)

If the agent thinks a fixed parameter is wrong, it writes a note to
`results/PROPOSALS.md` for a human — it does not change it.

---

## The optimization loop (what the agent runs, on box 1)

```
loop:
  1. read results/HISTORY.jsonl        # every past run: config hash, score, metrics, gate
  2. read results/BEST.json            # current champion config + score
  3. form a hypothesis                 # "multishot accept should cut io_uring_enter calls"
  4. edit treatment/ source            # the mutation
  5. ./harness/run.sh treatment        # build, pin, ramp, score, validate gate
  6. append the run to HISTORY.jsonl   # score=0 if gate failed or build failed
  7. if score > BEST: promote to BEST.json, keep change
     else: git revert the change       # treatment/ is a git repo; never keep a regression
  8. periodically re-run the control arm to confirm the box hasn't drifted
goto loop
```

Guardrails baked into `run.sh` so an unsupervised agent can't wreck the box or fool itself —
see HARNESS.md.

---

## Success definition

The project is "done" for a given environment when the optimizer's `BEST.json` score stops
improving by more than `EPSILON` (default 1%) over `PATIENCE` (default 30) consecutive
distinct configurations — i.e. it has plateaued. At that point `results/REPORT.md` is generated
comparing champion-treatment vs control: conn/s per core, absolute conn/s ceiling, CPU-seconds
per 1M conns, and a syscall-count profile (`perf stat` / `strace -c`) of each.

See: ENVIRONMENT.md, HARNESS.md, CONTROL_ARM.md, TREATMENT_ARM.md, METRICS.md, AGENT_LOOP.md.
