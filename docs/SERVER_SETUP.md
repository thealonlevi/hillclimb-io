# Server setup — fresh Ubuntu 22.04, target kernel 6.8

The benchmark box (box 1, SUT + co-located CH + the `claude -p` optimizer) and the load
generator (box 2) both start as **fresh Ubuntu 22.04** installs. This is a manual checklist for
now (not yet a script — the exact deps firm up once the buildable pieces exist). Everything here
is a prerequisite to building any of the four artifacts.

> Decisions already locked: **kernel 6.8** on the SUT box (matches the production fleet and
> unlocks io_uring multishot accept + modern opcodes — see "Kernel" below). cgroup v2 (default
> on 22.04). C/liburing treatment arm, Go control arm, co-located fresh ClickHouse, `claude -p`
> optimizer.

---

## 0. Why these versions matter (read first)

- **Stock 22.04 ships kernel 5.15.** That kernel **lacks io_uring multishot accept** (landed in
  5.19) — the single most impactful optimization the agent would explore — plus weaker
  provided-buffers and `accept_direct` support. On 5.15 the treatment arm is handicapped and
  **not representative of the prod fleet**, which runs **6.8**. So we move the SUT box to 6.8.
- **cgroup v2 is the 22.04 default** (unified hierarchy). The harness's cpuset/CPU-accounting
  design relies on it. Only catch: the `cpuset` controller must be delegated to child cgroups
  explicitly (step 3).

---

## 1. Kernel → 6.8 (SUT box; box 2 can stay on stock)

Use the Ubuntu 22.04 HWE stack, which brings the 6.x kernel line, to match prod and unlock
io_uring:

```bash
sudo apt update
sudo apt install -y linux-generic-hwe-22.04
sudo reboot
# after reboot:
uname -r          # expect 6.x (6.8 from the current HWE rollup)
```

Verify io_uring multishot accept is actually present before trusting the treatment arm's design
space (a tiny liburing probe, or check the kernel ≥ 5.19; 6.8 is fine). Record `uname -r` in the
environment fingerprint (ENVIRONMENT.md) — the whole benchmark validity depends on the kernel
not changing between the sequential control and treatment runs.

> If exact-6.8 parity with prod matters more than HWE convenience, install the precise mainline
> 6.8 .deb instead — but HWE 6.8 is the low-maintenance default and was the chosen path.

---

## 2. APT packages (SUT box)

```bash
sudo apt update
sudo apt install -y \
  build-essential clang llvm pkg-config \
  liburing-dev \                 # C/liburing treatment arm. Confirm version supports multishot
  linux-tools-common linux-tools-generic \   # perf (perf stat for IPC/LLC-miss profiling)
  strace ltrace \               # syscall-per-conn profiling for the metrics
  git python3 python3-pip \     # harness glue, JSON parsing (jq is NOT used — python3 instead)
  ethtool numactl util-linux \  # NIC ring/queue tuning, taskset/cpuset, IRQ pinning
  iproute2                      # ss for accept-queue (Recv-Q) probing
```

Notes:
- `liburing-dev` from the 22.04 archive may be older; the treatment arm needs a liburing new
  enough for multishot accept helpers. If the packaged version is too old, build liburing from
  source (`git clone https://github.com/axboe/liburing && make && sudo make install`). Verify
  `io_uring_prep_multishot_accept` is declared in the installed headers.
- `perf` must match the running kernel (`linux-tools-$(uname -r)` after the 6.8 upgrade).

---

## 3. cgroup v2 + cpuset (SUT box)

cgroup v2 is already mounted (`mount | grep cgroup2` shows the unified hierarchy). Delegate the
controllers the harness needs down to child cgroups:

```bash
# enable the controllers for child cgroups (idempotent)
echo "+cpuset +cpu +memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control

# create the three exclusive partitions the design needs:
#   accept-bench-sut  -> the arm under measurement (the pinned CORES)
#   accept-bench-ch   -> co-located ClickHouse (MUST be off the SUT cores)
#   (NIC IRQs + everything else -> the remaining cores)
sudo mkdir -p /sys/fs/cgroup/accept-bench-sut /sys/fs/cgroup/accept-bench-ch
# example split on a box where cores 4-11 are the SUT budget, 0-3 are "everything else":
echo 4-11 | sudo tee /sys/fs/cgroup/accept-bench-sut/cpuset.cpus
echo 0-3  | sudo tee /sys/fs/cgroup/accept-bench-ch/cpuset.cpus
# memory caps:
echo 8G | sudo tee /sys/fs/cgroup/accept-bench-ch/memory.max
```

The SUT cpuset must be **exclusive** — nothing else (not CH, not IRQs, not the optimizer) runs
on those cores, or the CPU-efficiency score is contaminated (METRICS.md co-location caveat). The
harness reads `accept-bench-sut/cpu.stat` `usage_usec` for the score.

---

## 4. Kernel & network tuning (SUT box — mirror the production baseline)

These are the production-node settings (the control arm relies on some, e.g. `somaxconn`).
Record exact values in the env fingerprint.

```bash
# /etc/sysctl.d/99-acceptbench.conf  (then: sudo sysctl --system)
net.core.somaxconn = 131072            # control arm relies on this for listen backlog
net.ipv4.tcp_max_syn_backlog = 131072
net.core.netdev_max_backlog = 131072
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1              # mostly matters on box 2 (the connector side)
# BBR + conntrack-disabled to match prod (see a production node's sysctl config)
```

- **THP off** (matches prod): `echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled`.
- **CPU governor → performance** + disable turbo on the SUT cpus for reproducibility
  (`cpupower frequency-set -g performance`; `intel_pstate/no_turbo=1` if applicable).
- **NIC**: size ring buffers like prod (`sudo ethtool -G <iface> rx 4096 tx 4096`); pin NIC IRQs
  to cores **outside** the SUT cpuset (`/proc/irq/*/smp_affinity` → the CH/other cores).

---

## 5. ClickHouse — fresh, co-located, pinned off the SUT cores (SUT box)

```bash
# install a fresh ClickHouse server (official repo)
curl -fsSL https://clickhouse.com/ | sh
sudo ./clickhouse install
sudo clickhouse start
```

Then (per METRICS.md):
- Launch/confine `clickhouse-server` inside the `accept-bench-ch` cgroup (step 3) so it can
  NEVER touch the SUT cores or evict the SUT's working set.
- Create the `acceptbench` database + the `runs`/`steps`/`samples` tables (schema in METRICS.md).
- Remember the discipline: **CH is idle during MEASURE** (no inserts, no queries) — the harness
  buffers and flushes between runs. Co-locating CH is only safe because of that rule + the
  cpuset isolation.

---

## 6. Go (control arm) + claude CLI + graphify (SUT box)

```bash
# Go — match the reference proxy's toolchain (currently 1.25). Install from go.dev tarball, not apt
#   (apt's Go lags). e.g.:
curl -fsSL https://go.dev/dl/go1.25.x.linux-amd64.tar.gz | sudo tar -C /usr/local -xz
export PATH=$PATH:/usr/local/go/bin   # add to /etc/profile.d

# claude CLI (the optimizer). Install per Anthropic's current instructions; this box runs
#   claude -p headless. Verify: claude --version  (spec was validated against v2.1.181)

# graphify — the zero-API-cost code map (TOKEN_EFFICIENCY.md). Install the same tool used across
#   ~/dev/* in this workspace; run `graphify .` once on treatment/, `graphify update .` after
#   each kept mutation.
```

---

## 7. Load generator box (box 2)

Box 2 must NOT be the bottleneck at 10k–20k conn/s of new connections (ENVIRONMENT.md):

```bash
sudo apt install -y build-essential git python3 iproute2
# tune the connector side hard — TIME_WAIT/port exhaustion caps offered load before the SUT does:
#   net.ipv4.ip_local_port_range = 1024 65535
#   net.ipv4.tcp_tw_reuse = 1
#   low net.ipv4.tcp_fin_timeout
# enough cores that box-2 CPU stays < 60% at the SUT ceiling (verify; else you measure box 2).
```

Box 2 does NOT need the 6.8 upgrade, ClickHouse, or graphify — it only runs the load generator
and reports offered/completed/failed + reply-correctness samples.

---

## 8. Order of operations on a fresh box

1. Kernel → 6.8 (step 1), reboot, confirm `uname -r` and io_uring multishot availability.
2. APT packages + liburing (step 2); build liburing from source if the archive one is too old.
3. cgroup v2 cpuset partitions (step 3); confirm SUT cpuset is exclusive.
4. sysctl / THP / governor / NIC / IRQ tuning (step 4); record the fingerprint.
5. ClickHouse install + `acceptbench` schema + pin into `accept-bench-ch` (step 5).
6. Go + claude CLI + graphify (step 6).
7. Box 2 setup + verify it out-runs the SUT's expected ceiling (step 7).
8. Only now build the four artifacts (referee → control → milestone-0 treatment → loop).

Snapshot the env fingerprint (ENVIRONMENT.md) once everything above is in place — it is the
baseline every sequential run is checked against.

## Sources
- [io_uring multishot accept needs kernel 5.19+](https://lore.kernel.org/lkml/a41a1f47-ad05-3245-8ac8-7d8e95ebde44@kernel.dk/t/)
- [Ubuntu 22.04 cgroup v2 default + enabling cpuset](https://oneuptime.com/blog/post/2026-01-15-setup-cgroups-v2-resource-control-ubuntu/view)
