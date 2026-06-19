# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`accept-bench` (project name "hillclimb-io") is a **fair, optimizable benchmark for how
CPU-efficiently a program accepts TCP connections** and serves one fixed 19-byte reply
(`HTTP/1.1 200 OK\r\n\r\n`) at high connection churn. The score is
`max_sustained_conn_per_sec / CORES` — CPU efficiency at a fixed core budget.

It is a two-arm experiment benchmarked **sequentially on the same box** (load generator on a
second box):

- **Control (port 30, FROZEN):** a faithful Go clone of a reference proxy's accept path
  (`SO_REUSEPORT` fan-out, goroutine-per-connection, TCP_INFO adaptive scaler). The baseline.
- **Treatment (port 31):** C + liburing. The thing an **autonomous optimizer agent** mutates in
  a loop until the score plateaus.

The optimizer agent is concretely **`claude -p` (headless)** invoked once per iteration by a
bash harness. That agent edits **only `treatment/`** and is judged by a fixed scoring function +
anti-cheat gate. Future Claude instances working here are usually either (a) building the fixed
referee pieces, or (b) acting as that treatment-optimizing agent.

## Current status: BUILT + RUNNING (single-box dev)

All four pieces are implemented and validated end-to-end on a single Ubuntu 24.04 box:
`loadgen/` (epoll C connection-storm + gate sampler), `control/` (Go reuseport arm),
`treatment/` (C/liburing milestone-0, own git repo), `harness/` (run.sh referee + loop.sh
optimizer + flush-ch.sh + cgroups), ClickHouse `acceptbench.*`. A full `claude -p` optimizer
iteration has run (commit→measure→keep/revert→promote).

- **One-shot bring-up on a fresh box:** `sudo bash scripts/setup.sh` (idempotent; installs
  toolchain, cgroups, ClickHouse, builds all arms). See **`docs/BUILD_LOG.md`** for the real
  install journal + every gotcha the script encodes.
- **Single-box caveat:** this VM has no second loadgen box / 10GbE / NIC-IRQ pinning / cpufreq
  control, so nothing saturates the 4 SUT cores at 10k/s over loopback — **scores are
  loadgen-limited and noisy, not measurement-grade.** The pipeline is correct; trustworthy
  numbers need the 2-box "Track B" deployment (`docs/ENVIRONMENT.md`).
- **Two load-bearing runtime facts:** (1) `claude -p --dangerously-skip-permissions` is refused
  as root — the loop exports **`IS_SANDBOX=1`** to allow it (isolated box only). (2) Never
  `pkill -f <armpath>` — `-f` matches the harness's own wrapper and self-kills it (exit 144);
  use `pkill -x <basename>`.

## The hard contract (read before changing anything)

`docs/PROJECT.md` is the authoritative contract. The non-negotiables:

- The optimizer agent may change **only files under `treatment/`**. The scoring function, the
  ramp definition, the correctness gate, `REPLY_BYTES`, the behavioral contract, the control
  arm, the loadgen, the harness, and the pinned `CORES`/cgroup/kernel baseline are all **FIXED**.
  If a fixed parameter looks wrong, write to `results/PROPOSALS.md` for a human — do not change it.
- **Behavioral contract (both arms):** per connection — `accept` → consume request bytes through
  the first `\r\n\r\n` → write the exact 19-byte `REPLY_BYTES` in full → close. One reply per
  connection, then close. No keep-alive in v1.
- **Correctness gate (anti-cheat, every scored step):** exact reply bytes + end-to-end
  completion audit + drop rate `< 0.01%`. Any failure ⇒ that step scores **0** and the ramp
  stops. This is what stops the optimizer "winning" by truncating replies or shedding load.

## Build & run (intended commands)

```bash
# control arm (Go; GOMAXPROCS = CORES, pinned to the SUT cpuset)
go build -o control/accept-control ./control/

# treatment arm (C/liburing) — the optimizer relies on this exact target
make -C treatment            # => treatment/accept-treat

# one full benchmark run: build, pin to cpuset, ramp, score, run the gate, profile
./harness/run.sh <arm>       # arm = treatment | control-frozen | control-adaptive
```

`run.sh` is the referee. It owns build, cgroup/cpuset pinning, the load ramp, scoring, the gate,
syscall/perf profiling, and writing results. It deliberately does **not** decide keep/revert —
the AGENT_LOOP does that via `git` + `results/BEST.json`. Guardrails (20s smoke-test timeout,
crash⇒score 0, memory cap, network-egress firewall, control-drift watchdog) live in `run.sh`
so an unsupervised optimizer can't wreck the box or fool itself.

## The optimizer loop & its two-phase rule

Each iteration (`docs/AGENT_LOOP.md`, `docs/OPTIMIZER_HEADLESS.md`) is split into two strictly
separated phases — **this separation is load-bearing for measurement validity**:

- **MEASURE phase:** `harness/run.sh` builds → pins → ramps → scores → gates. ClickHouse is
  **completely idle** (no inserts, no queries); rows are buffered locally. Only the SUT arm and
  harness samplers run, so nothing steals the cycles being measured. (CH is co-located on box 1,
  pinned to non-SUT cores — see `docs/METRICS.md` co-location caveat.)
- **ANALYTICS phase:** flush buffered rows to ClickHouse, reason over the data to form **one**
  hypothesis, edit `treatment/`, commit. The `claude -p` call *is* this phase.

Keep/revert verdict: `result.score > BEST.score * (1 + EPSILON)` ⇒ promote to `BEST.json`, keep
the commit; otherwise `git -C treatment reset --hard HEAD~1`. **Never keep a regression.**
A build failure, crash, gate failure, or a timed-out/errored `claude -p` call is a **no-op
iteration** — revert and move on; the loop must survive every bad turn.

## Memory & state model (three tiers)

- **`results/BEST.json`** (local, authoritative) — champion config + score; the keep/revert
  decision is local and atomic so a DB outage never stalls the loop.
- **`results/HISTORY.jsonl`** — durable local fallback (schema in `docs/HARNESS.md`); one line
  per run, always written.
- **ClickHouse `acceptbench.{runs,steps,samples}`** (co-located on box 1) — the queryable
  long-term memory the agent correlates over; best-effort, never blocks a run. Schema + the
  queries the agent runs each iteration are in `docs/METRICS.md`.
- **`treatment/` is its own git repo** — every benchmarked mutation is a commit with a
  structured message (hypothesis / change / result / syscall deltas / verdict). `git log` alone
  reconstructs what's been tried and what won.
- **`kbs/`** — distilled prose lessons (`INDEX.md` = one line per note, loaded first; full notes
  read on demand). A fresh `claude -p` session rehydrates from `kbs/` + git history + ClickHouse.

## Why the optimizer can be trusted to find the architecture

You never pick multishot vs SQPOLL vs registered-files. The agent tries them, the fixed
gate-protected scoring function ranks them, and git keeps only what wins. Reason from the
**syscall profile** (`io_uring_enter`/conn, read/write/conn, LLC misses), not just the score —
the profile tells you *why* a config is fast. Respect the **per-core** objective: SQPOLL burning
a whole core can raise raw conn/s but lower conn/s-per-core, and the score already encodes that.
Promote only when the win exceeds the recorded N=3 spread (don't chase noise).

## Documentation map (`docs/`, read in this order)

`PROJECT.md` (the contract) → `CONTROL_ARM.md` → `TREATMENT_ARM.md` → `HARNESS.md` →
`ENVIRONMENT.md` → `AGENT_LOOP.md` → `METRICS.md` → `OPTIMIZER_HEADLESS.md` →
`TOKEN_EFFICIENCY.md` → `SERVER_SETUP.md`.
