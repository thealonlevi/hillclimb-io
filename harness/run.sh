#!/usr/bin/env bash
# harness/run.sh <arm>  —  the FIXED referee. Build, pin, ramp, score, gate, profile, record.
# arm ∈ { treatment | control-frozen | control-adaptive }
# The optimizer calls this but never edits it. Prints the final score JSON on stdout and appends
# one line to results/HISTORY.jsonl. Env overrides (WARMUP/MEASURE/N/RAMP_CONF) allowed for dev.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export PATH="$PATH:/usr/local/go/bin"
. harness/config
export GOMAXPROCS="$CORES"   # control arm (Go) honors the pinned core budget (spec: GOMAXPROCS==CORES)

ARM="${1:?usage: run.sh <treatment|control-frozen|control-adaptive>}"
WARMUP="${WARMUP_OVERRIDE:-$WARMUP}"
MEASURE="${MEASURE_OVERRIDE:-$MEASURE}"
N="${N_OVERRIDE:-$N}"
RAMP_CONF="${RAMP_OVERRIDE:-$RAMP_CONF}"
RUNID="$(date +%Y%m%d-%H%M%S)-$ARM-$$"
RUNDIR="$RESULTS_DIR/$RUNID"; mkdir -p "$RUNDIR"
SUTCG=/sys/fs/cgroup/accept-bench-sut
log(){ echo "[run.sh $ARM] $*" >&2; }

# ---- pick binary + port for the arm ---------------------------------------
case "$ARM" in
  treatment)         BIN="treatment/accept-treat";  PORT=$TREAT_PORT;   SCALER=0 ;;
  control-frozen)    BIN="control/accept-control";  PORT=$CONTROL_PORT; SCALER=0 ;;
  control-adaptive)  BIN="control/accept-control";  PORT=$CONTROL_PORT; SCALER=1 ;;
  *) log "unknown arm '$ARM'"; exit 2 ;;
esac

# ---- 1. PREFLIGHT: build + env fingerprint --------------------------------
build_arm(){
  case "$ARM" in
    treatment)  make -C treatment >"$RUNDIR/build.log" 2>&1 ;;
    control-*)  ( cd control && go build -o accept-control . ) >"$RUNDIR/build.log" 2>&1 ;;
  esac
}
env_fingerprint(){
  { uname -r; cat "$SUTCG/cpuset.cpus" 2>/dev/null; sysctl -n net.core.somaxconn net.ipv4.ip_local_port_range 2>/dev/null;
    cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; } | sha256sum | cut -c1-16
}
# ---- arm lifecycle (pinned into the SUT cpuset via cgrun) ------------------
ARM_PID=""
start_arm(){
  ARM_ARGS=(--port "$PORT")
  [ "$ARM" = control-adaptive ] && ARM_ARGS+=(--scaler) || true
  setsid harness/cgrun.sh accept-bench-sut "./$BIN" "${ARM_ARGS[@]}" \
     >"$RUNDIR/arm.log" 2>&1 < /dev/null &
  ARM_PID=$!
}
# NOTE: use pkill -x on the basename, never `pkill -f <path>` — -f matches this script's own
# wrapper command line and self-kills it (manifests as a confusing exit 144).
stop_arm(){ [ -n "$ARM_PID" ] && kill "$ARM_PID" 2>/dev/null; pkill -x "$(basename "$BIN")" 2>/dev/null; ARM_PID=""; sleep 0.3; }
trap 'stop_arm' EXIT

cpu_usec(){ awk '/usage_usec/{print $2}' "$SUTCG/cpu.stat" 2>/dev/null; }
max_recvq(){ ss -ltnH "sport = :$PORT" 2>/dev/null | awk '{if($2>m)m=$2}END{print m+0}'; }

# ---- 2. smoke test --------------------------------------------------------
smoke(){
  local t0=$SECONDS
  while [ $((SECONDS-t0)) -lt "$SMOKE_TIMEOUT" ]; do
    ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q . && {
      local out; out=$(loadgen/loadgen --host "$TARGET_HOST" --port "$PORT" --rate 200 --duration 1 --threads 2 --sample-pct 100)
      echo "$out" | grep -q '"reply_ok":true' && [ "$(echo "$out"|sed 's/.*"completed":\([0-9]*\).*/\1/')" -ge 100 ] && return 0
    }
    sleep 0.5
  done
  return 1
}

# ---- 3. one ramp -> max sustained conn/s ----------------------------------
run_ramp(){   # echoes: <max_sustained_conn_s> <ceiling_reason> ; writes per-step json to $1
  local stepfile="$1"; : > "$stepfile"
  local best=0 reason="none" idx=0
  while read -r RATE; do
    [[ "$RATE" =~ ^[0-9]+$ ]] || continue
    # warmup
    loadgen/loadgen --host "$TARGET_HOST" --port "$PORT" --rate "$RATE" --duration "$WARMUP" \
       --threads "${LG_THREADS:-8}" --sample-pct "$SAMPLE_PCT" >/dev/null 2>&1
    # measure (sample cpu + recvq around it)
    local u0 u1 wall mq res
    u0=$(cpu_usec); local s0=$SECONDS
    mq=$( ( for i in $(seq 1 "$MEASURE"); do max_recvq; sleep 1; done ) | sort -n | tail -1 )
    res=$(loadgen/loadgen --host "$TARGET_HOST" --port "$PORT" --rate "$RATE" --duration "$MEASURE" \
       --threads "${LG_THREADS:-8}" --sample-pct "$SAMPLE_PCT")
    u1=$(cpu_usec); wall=$(( (SECONDS-s0>0?SECONDS-s0:1) ))
    local comp drop ok p99
    comp=$(echo "$res" | sed 's/.*"completed_cps":\([0-9.]*\).*/\1/')
    drop=$(echo "$res" | sed 's/.*"drop_rate":\([0-9.]*\).*/\1/')
    ok=$(echo "$res"   | grep -o '"reply_ok":[a-z]*' | cut -d: -f2)
    p99=$(echo "$res"  | sed 's/.*"p99_ms":\([0-9.]*\).*/\1/')
    local cpuutil=0
    [ -n "$u0" ] && [ -n "$u1" ] && cpuutil=$(awk -v d=$((u1-u0)) -v c="$CORES" -v w="$wall" 'BEGIN{printf "%.3f", d/(c*w*1000000)}')
    printf '{"idx":%d,"offered":%d,"completed_cps":%s,"drop_rate":%s,"reply_ok":"%s","cpu_util":%s,"max_recvq":%s,"p99_ms":%s}\n' \
      "$idx" "$RATE" "${comp:-0}" "${drop:-1}" "${ok:-false}" "$cpuutil" "${mq:-0}" "${p99:-0}" >> "$stepfile"
    log "step $idx: offered=$RATE completed=${comp:-0}/s drop=${drop} reply_ok=${ok} cpu=${cpuutil} recvq=${mq}"
    # gate
    local gate_ok=1
    [ "$ok" = "true" ] || gate_ok=0
    awk -v d="${drop:-1}" -v c="$DROP_CEILING" 'BEGIN{exit !(d<c)}' || gate_ok=0
    if [ "$gate_ok" -eq 0 ]; then reason="gate_fail"; log "  gate FAILED at $RATE -> stop ramp"; break; fi
    # this step passed -> candidate ceiling
    best=$(awk -v b="$best" -v c="${comp:-0}" 'BEGIN{printf "%d", (c>b?c:b)}')
    # ceiling detection
    if [ "${mq:-0}" -gt "$QUEUE_HIGH" ]; then reason="queue_backpressure"; log "  recvq ${mq}>${QUEUE_HIGH} -> ceiling"; break; fi
    awk -v u="$cpuutil" 'BEGIN{exit !(u>0.98)}' && { reason="cpu_saturation"; log "  cpu saturated -> ceiling"; break; }
    idx=$((idx+1))
  done < "$RAMP_CONF"
  echo "$best $reason"
}

# ---- 4. syscall profile (best-effort analytics, not gated) ----------------
profile_syscalls(){   # writes $1 with per-conn counts
  local out="$1"; local rate=5000
  command -v strace >/dev/null || { echo '{}' > "$out"; return; }
  ( strace -f -c -p "$ARM_PID" -o "$RUNDIR/strace.txt" 2>/dev/null ) &
  local sp=$!
  local res; res=$(loadgen/loadgen --host "$TARGET_HOST" --port "$PORT" --rate "$rate" --duration 3 --threads 4 --sample-pct 0)
  kill -INT "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  local comp; comp=$(echo "$res" | sed 's/.*"completed":\([0-9]*\).*/\1/'); [ "${comp:-0}" -lt 1 ] && comp=1
  awk -v C="$comp" '
    /^[ ]*[0-9].*[a-z_0-9]+$/ {n=$NF; c=$4; if(c ~ /^[0-9]+$/) cnt[n]=c}
    END{ printf "{"; first=1; split("io_uring_enter accept4 read write close epoll_wait recvfrom sendto",k," ");
      for(i in k){key=k[i]; v=(key in cnt)?cnt[key]/C:0; printf "%s\"%s\":%.4f",(first?"":","),key,v; first=0} printf "}" }' \
    "$RUNDIR/strace.txt" > "$out" 2>/dev/null || echo '{}' > "$out"
}

# ---- 5. record ------------------------------------------------------------
# reads per-step / syscall JSON from files (robust — never pass big JSON via argv)
record_score(){   # score max_sustained reason  [stepfile] [syscfile]
  local score="$1" mx="$2" reason="$3" stepfile="${4:-}" syscfile="${5:-}"
  CFG_HASH=""
  [ "$ARM" = treatment ] && CFG_HASH="$(git rev-parse HEAD 2>/dev/null || echo '')"
  RUNID="$RUNID" ARM="$ARM" SCORE="$score" MX="$mx" CORES="$CORES" REASON="$reason" \
  ENVFP="$ENVFP" STEPFILE="$stepfile" SYSCFILE="$syscfile" HIST="$HISTORY" CFG_HASH="$CFG_HASH" \
  python3 <<'PY'
import os,json
def loadsteps(p):
    if not p or not os.path.exists(p): return []
    return [json.loads(l) for l in open(p) if l.strip()]
def loadjson(p):
    if not p or not os.path.exists(p): return {}
    try: return json.load(open(p))
    except Exception: return {}
e=os.environ
row=dict(runid=e["RUNID"],arm=e["ARM"],config_hash=e["CFG_HASH"] or None,
         score=float(e["SCORE"]),max_sustained_conn_s=int(float(e["MX"])),cores=int(e["CORES"]),
         ceiling_reason=e["REASON"],env_fingerprint=e["ENVFP"],
         per_step=loadsteps(e["STEPFILE"]),syscall_profile=loadjson(e["SYSCFILE"]))
open(e["HIST"],"a").write(json.dumps(row)+"\n")
print(json.dumps(row))
PY
}

# ============================ MAIN =========================================
if ! build_arm; then
  log "BUILD FAILED — score 0"; tail -5 "$RUNDIR/build.log" >&2
  ENVFP="$(env_fingerprint)"; record_score 0 0 build_fail >/dev/null
  echo '{"score":0,"reason":"build_fail"}'; exit 0
fi
ENVFP="$(env_fingerprint)"
log "built $BIN ; env=$ENVFP ; runid=$RUNID"
declare -a SCORES=()
REASON="none"
for rep in $(seq 1 "$N"); do
  start_arm
  if ! smoke; then log "SMOKE FAILED (rep $rep) — score 0"; stop_arm; record_score 0 0 smoke_fail >/dev/null; echo '{"score":0,"reason":"smoke_fail"}'; exit 0; fi
  log "rep $rep/$N ramping…"
  read -r mx REASON < <(run_ramp "$RUNDIR/steps.$rep.jsonl")
  SCORES+=( "$mx" )
  if [ "$rep" -eq 1 ]; then profile_syscalls "$RUNDIR/syscall.json"; fi
  stop_arm; sleep "$SETTLE"; sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
done
# median of reps
MEDIAN=$(printf '%s\n' "${SCORES[@]}" | sort -n | awk '{a[NR]=$1}END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')
SCORE=$(awk -v m="$MEDIAN" -v c="$CORES" 'BEGIN{printf "%.2f", m/c}')
SPREAD=$(printf '%s\n' "${SCORES[@]}" | sort -n | awk '{a[NR]=$1}END{if(a[1]>0)printf "%.1f",(a[NR]-a[1])/a[1]*100; else print 0}')
log "reps=${SCORES[*]} median_conn_s=$MEDIAN score=$SCORE spread=${SPREAD}% ceiling=$REASON"
record_score "$SCORE" "$MEDIAN" "$REASON" "$RUNDIR/steps.1.jsonl" "$RUNDIR/syscall.json"
