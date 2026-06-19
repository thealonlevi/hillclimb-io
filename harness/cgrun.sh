#!/usr/bin/env bash
# cgrun.sh <cgroup-name> <command...>
# Launch a command inside an accept-bench cgroup v2 cpuset (replaces cgexec, which is absent on
# Ubuntu 24.04). The cgroup must already exist (created by scripts/setup.sh / harness/cgroups.sh).
# Works by forking, placing the child's own PID into the cgroup, then exec'ing the command.
set -euo pipefail
cg="${1:?usage: cgrun.sh <cgroup> <command...>}"; shift
base=/sys/fs/cgroup/"$cg"
[ -d "$base" ] || { echo "cgrun: cgroup $cg does not exist ($base)" >&2; exit 1; }
# Put *this* shell into the target cgroup, then exec the command so it inherits membership.
echo $$ > "$base/cgroup.procs"
# raise open-fd limit so the arm can hold many concurrent connections (high-latency loadgen path)
ulimit -n 1048576 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
exec "$@"
