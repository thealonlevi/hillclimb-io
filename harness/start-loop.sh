#!/usr/bin/env bash
# start-loop.sh — launch the autonomous optimizer loop in the background (survives logout) and
# print how to watch / stop it. MUST be run by a human in a real shell (NOT from inside another
# Claude Code session — the parent session's classifier blocks the nested skip-perms claude).
#
#   harness/start-loop.sh           # fast profile (short windows) — good for this single box
#   PROFILE=full harness/start-loop.sh   # real 10s/30s x N=3 windows (for Track-B hardware)
#   MAX_ITERS=20 harness/start-loop.sh   # bounded run
set -uo pipefail
cd "$(dirname "$0")/.."
. harness/config
mkdir -p "$RESULTS_DIR/loop-logs"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$RESULTS_DIR/loop-logs/loop.$TS.out"

# already running?
if pgrep -f 'harness/loop.sh' >/dev/null; then
  echo "loop already running (pid $(pgrep -f 'harness/loop.sh' | tr '\n' ' ')). Watch: harness/watch.sh --follow"; exit 0
fi

# preflight: cgroups + clickhouse (best-effort)
[ -d /sys/fs/cgroup/accept-bench-sut ] || bash harness/cgroups.sh >/dev/null 2>&1 || true
clickhouse-client --query "SELECT 1" >/dev/null 2>&1 || clickhouse start >/dev/null 2>&1 || true

# profile -> per-step windows
case "${PROFILE:-fast}" in
  full) envline=(MAX_ITERS="${MAX_ITERS:-1000000}") ;;
  # fast = short windows but keep N=5 (the user-required average of 5 load tests); adaptive ramp.
  fast|*) envline=(MAX_ITERS="${MAX_ITERS:-1000000}" WARMUP_OVERRIDE="${WARMUP_OVERRIDE:-3}" \
          MEASURE_OVERRIDE="${MEASURE_OVERRIDE:-6}") ;;
esac

nohup env "${envline[@]}" harness/loop.sh > "$OUT" 2>&1 &
PID=$!
ln -sfn "$(basename "$OUT")" "$RESULTS_DIR/loop-logs/loop.out"
sleep 1
echo "started optimizer loop  pid=$PID  profile=${PROFILE:-fast}"
echo "  log:     $OUT   (symlink: $RESULTS_DIR/loop-logs/loop.out)"
echo "  watch:   harness/watch.sh --follow"
echo "  stop:    touch $RESULTS_DIR/STOP   (graceful, after current iter)  |  kill $PID (hard)"
