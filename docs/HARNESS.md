# Harness — the measurement rig (FIXED, agent may not edit)

The harness is what makes runs comparable and what makes an unsupervised optimizer safe. It
lives in `harness/` and `loadgen/`. The optimizer calls it but never edits it.

## Topology

- **Box 1 (SUT — system under test):** runs ONE arm at a time, pinned to `CORES` cpus in a
  dedicated cgroup. This is the box whose CPU we measure.
- **Box 2 (load generator):** runs the connection storm. Must be powerful enough that *it* is
  never the bottleneck — verify by confirming box 2 CPU < 60% at the SUT's ceiling. Connected
  to box 1 by a link that can carry the conn/s without saturating (10GbE+ recommended; at 19
  bytes/reply the bottleneck is packets/sec and the SYN/accept path, not bandwidth).

Arms run **sequentially**: benchmark control fully, then treatment. Never both at once.

## One benchmark run — `harness/run.sh <arm>`

```
1. PREFLIGHT
   - assert box is quiet: no other arm running, load average < 1, SUT cgroup idle
   - record environment fingerprint (see ENVIRONMENT.md); abort if it drifted from baseline
   - build the arm; build failure ⇒ record score=0, exit
2. PIN
   - place the arm process in cgroup `accept-bench-sut` with cpuset = CORES, memory cap
   - confirm no other process shares those cpus (cpuset exclusive)
3. RAMP  (for each offered rate in ramp.conf)
   - tell loadgen (box 2) to offer rate R for WARMUP+MEASURE seconds
   - during MEASURE: sample every 1s
       * SUT cgroup cpu.stat usage_usec  -> cpu utilization
       * ss -ltn Recv-Q on the arm's listen sockets -> accept-queue depth
       * loadgen reports: offered, completed, failed, p50/p99 accept latency, gate samples
   - decide ceiling: queue > QUEUE_HIGH sustained, OR cpu saturated AND completed/s plateaued
   - run CORRECTNESS GATE on this step; fail ⇒ step score 0, stop ramp
4. SCORE
   - max_sustained_conn_s = highest passing step's completed conn/s
   - score = max_sustained_conn_s / CORES
5. RECORD
   - append one JSON line to results/HISTORY.jsonl (see schema below)
   - emit perf/strace syscall profile at the ceiling step into results/<runid>/
6. CLEAN
   - kill arm, reset cgroup, drop caches between runs for determinism
```

## Determinism rules (so two runs of the same config score the same)

- Same WARMUP (default 10s) + MEASURE (default 30s) windows every step.
- Same ramp.conf.
- `echo 3 > /proc/sys/vm/drop_caches` and a fixed settle delay between runs.
- Pin IRQs for the NIC to cpus OUTSIDE the SUT cpuset (so accept work and IRQ work don't
  share cores unfairly) — recorded in ENVIRONMENT.md, identical for both arms.
- Disable turbo/frequency scaling on the SUT cpus (`cpupower frequency-set -g performance`)
  or the score wanders with thermal state. Record the governor in the fingerprint.
- Run each scored config **N=3 times** (configurable); the recorded score is the **median**,
  and the harness records the spread. If spread > 3%, flag the run as noisy.

## Guardrails for the unsupervised optimizer (baked into run.sh)

- **Timeout:** any arm that doesn't come up and pass a smoke test in 20s is killed, score 0.
- **Resource cap:** the SUT cgroup has a memory ceiling and the cpuset is exclusive; a runaway
  treatment build can't OOM the box or steal the harness's cpus.
- **Crash = score 0:** segfault / abort in treatment ⇒ recorded as score 0 with the core
  dump path, ramp aborted. (C/liburing will crash during exploration; this must be survivable.)
- **No-network-egress assertion:** treatment is only allowed to bind :31 and talk to box 2.
  The harness firewalls it from everything else so an optimizer can't "cheat" by offloading.
- **Auto-revert:** run.sh returns the score; the AGENT_LOOP (not run.sh) reverts treatment/ git
  if score regressed. run.sh itself never keeps state in treatment/.
- **Watchdog:** a separate process re-runs the control arm every K treatment runs; if control's
  score drifts > 5% the whole loop pauses (the box changed — thermal, neighbor, kernel) and
  flags a human. This prevents the optimizer from chasing environmental noise.

## HISTORY.jsonl schema (one line per run)

```json
{
  "runid": "string",
  "arm": "treatment|control-frozen|control-adaptive",
  "config_hash": "git sha of treatment/ tree",
  "score": 0.0,
  "max_sustained_conn_s": 0,
  "cores": 0,
  "ceiling_reason": "queue_backpressure|cpu_saturation",
  "gate": {"reply_ok": true, "completion_ok": true, "drop_rate": 0.0},
  "per_step": [{"offered": 0, "completed": 0, "failed": 0,
                "cpu_util": 0.0, "max_recvq": 0, "p99_accept_ms": 0.0}],
  "syscall_profile": {"accept4": 0, "read": 0, "write": 0, "close": 0,
                      "io_uring_enter": 0, "epoll_wait": 0},
  "median_of": 3, "spread_pct": 0.0,
  "env_fingerprint": "sha",
  "notes": "agent's hypothesis for this mutation"
}
```

This schema is the agent's entire view of the world. It reads HISTORY.jsonl, reasons about
which mutations helped (correlate syscall_profile deltas with score deltas), and forms its next
hypothesis. The `syscall_profile` is deliberately included so the optimizer can *understand
why* a config is faster (fewer `io_uring_enter` per conn, etc.), not just that it is.
