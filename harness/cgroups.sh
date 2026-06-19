#!/usr/bin/env bash
# cgroups.sh — (re)create the accept-bench cgroup v2 cpuset partitions. Idempotent.
# Layout for a 13-core box (CORES=4):
#   accept-bench-sut       cpus 2-5  (exclusive)  -- the arm under test; score denominator
#   accept-bench-loadgen   cpus 6-11             -- connection storm (must out-muscle the SUT)
#   accept-bench-ch        cpus 0-1,12           -- ClickHouse + harness housekeeping (off SUT)
set -euo pipefail
ROOT=/sys/fs/cgroup
SUT_CPUS="${SUT_CPUS:-2-5}"
LG_CPUS="${LG_CPUS:-6-11}"
CH_CPUS="${CH_CPUS:-0-1,12}"

[ "$(stat -fc %T "$ROOT")" = cgroup2fs ] || { echo "cgroup v2 not mounted at $ROOT" >&2; exit 1; }
# Delegate the controllers we need into the root subtree (no-op if already present).
grep -qw cpuset "$ROOT/cgroup.subtree_control" || echo "+cpuset +cpu +memory" > "$ROOT/cgroup.subtree_control"

mk() { # name cpus exclusive memmax
  local g="$ROOT/$1"; mkdir -p "$g"
  echo "$2" > "$g/cpuset.cpus"
  [ -n "$3" ] && { echo "$3" > "$g/cpuset.cpus.exclusive" 2>/dev/null || echo "  (note: cpuset.cpus.exclusive not settable for $1)"; }
  echo "$4" > "$g/memory.max"
  printf '%-22s cpus=%-8s excl=%-6s mem=%s\n' "$1" "$(cat "$g/cpuset.cpus")" "$(cat "$g/cpuset.cpus.exclusive" 2>/dev/null)" "$(cat "$g/memory.max")"
}
mk accept-bench-sut     "$SUT_CPUS" "$SUT_CPUS" $((8*1024*1024*1024))
mk accept-bench-loadgen "$LG_CPUS"  ""          $((8*1024*1024*1024))
mk accept-bench-ch      "$CH_CPUS"  ""          $((4*1024*1024*1024))

# Park ClickHouse on the CH cores if it is running.
chpid="$(pgrep -x clickhouse-serv 2>/dev/null | head -1 || true)"
[ -n "${chpid:-}" ] && { echo "$chpid" > "$ROOT/accept-bench-ch/cgroup.procs" 2>/dev/null && echo "clickhouse-server ($chpid) -> accept-bench-ch"; }

# Frequency governor (best-effort; absent under virtualization).
command -v cpupower >/dev/null && cpupower frequency-set -g performance >/dev/null 2>&1 && echo "governor=performance" || echo "governor: not settable (VM / no cpufreq) -- Track B"
