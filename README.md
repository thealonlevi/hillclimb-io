# accept-bench

A fair, optimizable benchmark for **how CPU-efficiently a program can accept TCP connections**
and serve a trivial fixed reply at high connection churn.

Two arms, benchmarked **sequentially on the same box** (load generator on a second box):

- **Port 30 — control:** a faithful clone of the reference proxy's accept path (Go, `SO_REUSEPORT`,
  goroutine-per-connection, TCP_INFO adaptive scaler). FROZEN.
- **Port 31 — treatment:** C + liburing. The thing an **autonomous optimizer agent** iterates,
  in a loop, until it plateaus at an empirical optimum.

**Objective:** maximize `sustained_conn_per_sec / cores` (CPU efficiency at a fixed core
budget). **Ceiling:** the offered rate where the accept queue backs up *or* the pinned cores
saturate. **Anti-cheat:** every scored run must serve the exact reply bytes, pass an end-to-end
completion audit, and drop < 0.01% of connections — or it scores 0.

The human builds the fixed referee (control arm + loadgen + harness + scoring) once. The agent
only ever edits `treatment/` and is judged by the scoring function. You do **not** pick the
io_uring architecture — the agent searches the design space (multishot accept, SQPOLL,
registered files/buffers, SQE linking, NAPI, …) and the score + git keep only what wins.

## Read these in order

1. `docs/PROJECT.md` — the contract: arms, behavioral contract, scoring, anti-cheat gate, what
   the agent may/may not change, success definition.
2. `docs/CONTROL_ARM.md` — exact reference-proxy accept-mechanism reproduction (build spec).
3. `docs/TREATMENT_ARM.md` — the optimizer's playground: requirements, milestone-0 baseline,
   the design space.
4. `docs/HARNESS.md` — the measurement rig + guardrails for unsupervised running.
5. `docs/ENVIRONMENT.md` — the fixed baseline that makes sequential runs comparable.
6. `docs/AGENT_LOOP.md` — exactly what the optimizer does each iteration.
7. `docs/METRICS.md` — ClickHouse (analytics memory) + local files (loop state); schema and the
   co-location caveat.
8. `docs/OPTIMIZER_HEADLESS.md` — the optimizer is `claude -p` (headless) in a bash loop:
   verified flags, full autonomy on the isolated box, session-rotation + `kbs/`/git memory model.
9. `docs/TOKEN_EFFICIENCY.md` — keeping the loop cheap enough to run for days: the prompt-cache
   TTL trap (1h vs 5min — a 100x swing), graphify as a zero-cost code map, model tiering,
   `.claudeignore`, and tracking the optimizer's own token spend.
10. `docs/SERVER_SETUP.md` — fresh Ubuntu 22.04 bootstrap checklist: kernel → 6.8 (HWE),
    toolchain (liburing/Go/perf/CH/claude/graphify), cgroup v2 cpuset partitions, sysctl/NIC/IRQ
    tuning, and the build order on a clean box.

## Layout

```
control/     port-30 reference-proxy-clone (Go)          [FROZEN]
treatment/   port-31 C/liburing (own git repo)   [agent edits ONLY this]
harness/     run.sh, ramp.conf, scoring, cgroup/pin setup,
             optimizer-prompt.md, optimizer-system.md, mcp-clickhouse.json   [FIXED]
loadgen/     box-2 connection storm + gate sampler          [FIXED]
results/     HISTORY.jsonl, BEST.json, REPORT.md, baselines  [agent appends results]
kbs/         distilled optimization lessons (INDEX.md + notes)  [optimizer writes]
docs/        the specs above
```

The optimizer is **`claude -p` (headless)** driven by `harness/run.sh`'s loop — full autonomy on
the isolated box, one mutation per iteration, memory via a long session rotated under context
pressure and rehydrated from `kbs/` + git history + ClickHouse. See `docs/OPTIMIZER_HEADLESS.md`.

## Status

Specification + skeleton only. The four buildable pieces (control arm, loadgen, harness,
milestone-0 treatment) are not yet implemented — see "Build order" below.

## Build order (suggested)

1. **loadgen** + **harness scoring** first — you can't trust any number without the referee.
2. **control-frozen** arm — establish the baseline conn/s-per-core to beat.
3. **milestone-0 treatment** — a correct, unoptimized liburing server; confirm it passes the
   gate and scores *below* control (it should — it's not optimized yet).
4. **AGENT_LOOP** wiring — hand it to the optimizer and let it climb.
