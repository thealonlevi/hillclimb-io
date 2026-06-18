# Environment baseline — recorded once, identical for every run

The whole benchmark is only valid if the environment is constant across the control run and all
treatment runs (they happen at different times — sequentially — so drift is the enemy). The
harness records a fingerprint at each run and aborts if it changed.

## SUT box (box 1) setup — done once, by a human

- **Kernel:** record `uname -r`. **Target: 6.8** (via the 22.04 HWE stack — see SERVER_SETUP.md).
  This is deliberate: stock Ubuntu 22.04 ships 5.15, which **lacks io_uring multishot accept**
  (needs 5.19+) — the most impactful optimization the agent explores — and doesn't match the
  production fleet (also 6.8). io_uring opcode availability depends on the kernel; a treatment
  using an opcode newer than the running kernel must degrade gracefully, not crash. The kernel
  MUST NOT change between the sequential control and treatment runs.
- **CPU pinning:** choose the `CORES` cpus for the SUT cpuset. Pin NIC IRQs to *other* cpus
  (`/proc/irq/*/smp_affinity`). Record both maps.
- **Frequency governor:** `cpupower frequency-set -g performance`; disable turbo if you want
  reproducibility over peak (`/sys/devices/system/cpu/intel_pstate/no_turbo=1`). Record it.
- **cgroup v2:** create `accept-bench-sut` with `cpuset.cpus = CORES` (exclusive),
  `memory.max` = a sane cap. The arm runs inside it; the harness reads its `cpu.stat`.
- **Co-located ClickHouse:** a fresh CH instance runs on this same box (the agent's analytics
  store — see METRICS.md). It MUST be pinned to cpus **outside** the SUT cpuset (own
  cgroup/cpuset, e.g. the same non-SUT cores as the NIC IRQs) with its own `memory.max`. If CH
  shares the SUT cores, its ingest/merges steal the very cycles being measured and corrupt the
  score. The harness also defers all CH inserts to **after** each MEASURE window so CH is idle
  while cycles are counted. Treat this as part of the fingerprint: record CH's cpuset.
- **sysctl baseline** (record the exact values; both arms see the SAME values):
  - `net.core.somaxconn` — the control arm relies on this for backlog (the reference proxy doesn't set it).
  - `net.ipv4.tcp_max_syn_backlog`, `net.core.netdev_max_backlog`
  - `net.ipv4.ip_local_port_range` — wide, or box 2 runs out of source ports at 10k+/s.
  - `net.ipv4.tcp_tw_reuse=1`, low `tcp_fin_timeout` — at high conn churn, TIME_WAIT exhaustion
    on box 2 (the connector side) will cap offered load before the SUT does. Tune box 2 for this.
  - conntrack: disabled (matches the production nodes; otherwise conntrack table fills at 10k/s).
- **NIC:** ring buffers sized (the production nodes use `ethtool -G ... rx 4096 tx 4096`); RSS
  queues mapped to non-SUT cpus. Record `ethtool -g` and `-l`.
- **THP:** `never` (matches production nodes).

## Load generator box (box 2) — must NOT be the bottleneck

At 10k–20k conn/s of *new* connections, the connector side is usually what breaks first:

- Wide `ip_local_port_range`, `tcp_tw_reuse=1`, enough source IPs if one box can't supply ports.
- Enough cores that box 2 CPU stays < 60% at the SUT ceiling — verify and record. If box 2
  saturates, you're measuring box 2, not the SUT. (Consider multiple loadgen boxes, or DPDK/
  a SYN-flood-style connector, if a single box can't reach the SUT's ceiling.)
- The loadgen must measure and report: offered/s, completed/s, failed/s, p50/p99 time-to-reply,
  and per-sample reply correctness — these feed the gate and the ceiling decision.

## The fingerprint (computed each run, must match baseline)

`sha256` over: `uname -r`, governor + no_turbo, cpuset map, IRQ affinity map, the recorded
sysctls, NIC ring/queue config, THP setting. Stored in `results/ENV_BASELINE.sha`. If a run's
fingerprint differs, `run.sh` aborts with a diff — the result would not be comparable.

## Why sequential runs make this strict

Because port 30 and port 31 are benchmarked at *different times*, any environmental change
between them (a kernel update, a thermal throttle, a noisy neighbor, a governor flip) silently
corrupts the comparison. The fingerprint + the periodic control-arm re-run (AGENT_LOOP
watchdog) are how we catch that. Treat them as load-bearing, not optional.
