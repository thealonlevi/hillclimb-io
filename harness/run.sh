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
# auto-size loadgen threads to the load generator's core count (it must out-supply the SUT)
if [ "${LG_THREADS:-auto}" = auto ]; then
  if [ -n "${LOADGEN_URL:-}" ]; then
    LG_THREADS=$(curl -fsS --max-time 5 "$LOADGEN_URL/health" 2>/dev/null | python3 -c "import sys,json;print(max(4,int(json.load(sys.stdin).get('cores',8))))" 2>/dev/null || echo 8)
  else
    LG_THREADS=$(nproc 2>/dev/null || echo 8)
  fi
fi
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

# loadgen_run <kind:rate|conns> <level> <duration> <threads> <sample_pct> -> prints loadgen JSON.
#   rate  = open-loop offered conn/s (fine on sub-ms links)
#   conns = closed-loop in-flight connections (correct over latency: throughput = conns/latency,
#           and a slow/distant SUT can't be overloaded into congestion collapse)
# Remote (box 2) when LOADGEN_URL is set; else local. TARGET_HOST must be box 1 as seen from box 2.
loadgen_run(){
  local kind="$1" level="$2" dur="$3" th="$4" sp="$5"
  if [ -n "${LOADGEN_URL:-}" ]; then
    curl -fsS --max-time $((dur+30)) -G "$LOADGEN_URL/run" \
      --data-urlencode "host=$TARGET_HOST" --data-urlencode "port=$PORT" \
      --data-urlencode "$kind=$level"      --data-urlencode "duration=$dur" \
      --data-urlencode "threads=$th"       --data-urlencode "sample_pct=$sp" 2>/dev/null
  else
    loadgen/loadgen --host "$TARGET_HOST" --port "$PORT" "--$kind" "$level" --duration "$dur" \
      --threads "$th" --sample-pct "$sp"
  fi
}

# ---- 2. smoke test --------------------------------------------------------
smoke(){
  local t0=$SECONDS
  while [ $((SECONDS-t0)) -lt "$SMOKE_TIMEOUT" ]; do
    ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q . && {
      local out; out=$(loadgen_run rate 200 1 2 100)
      echo "$out" | grep -q '"reply_ok":true' && [ "$(echo "$out"|sed 's/.*"completed":\([0-9]*\).*/\1/')" -ge 100 ] && return 0
    }
    sleep 0.5
  done
  return 1
}

# ---- 3. ramp -> max sustained conn/s --------------------------------------
# measure_step <rate> <idx> <do_sample>: one warmup+measure window. Appends the step JSON (and
# per-second samples when do_sample), and returns metrics via globals M_COMP/M_CPU/M_RECVQ/M_DROP/M_GATE.
measure_step(){
  local kind="$1" RATE="$2" idx="$3" do_sample="$4"
  loadgen_run "$kind" "$RATE" "$WARMUP" "$LG_THREADS" "$SAMPLE_PCT" >/dev/null 2>&1   # warmup
  local u0 u1 wall mq res samp="$RUNDIR/.samp"
  u0=$(cpu_usec); local s0=$SECONDS; : > "$samp"
  ( for ((i=1;i<=MEASURE;i++)); do sleep 1; printf '%d %s %s\n' "$i" "$(cpu_usec)" "$(max_recvq)"; done ) > "$samp" &
  local sp=$!
  res=$(loadgen_run "$kind" "$RATE" "$MEASURE" "$LG_THREADS" "$SAMPLE_PCT")
  wait "$sp" 2>/dev/null
  u1=$(cpu_usec); wall=$(( (SECONDS-s0>0?SECONDS-s0:1) ))
  mq=$(awk '{print $3}' "$samp" | sort -n | tail -1); mq=${mq:-0}
  [ "$do_sample" = 1 ] && awk -v u0="$u0" -v idx="$idx" -v c="$CORES" 'BEGIN{prev=u0}
      {util=($2-prev)/(c*1000000); if(util<0)util=0;
       printf "{\"step_idx\":%d,\"t_offset_s\":%d,\"cpu_util\":%.3f,\"recvq\":%d}\n",idx,$1,util,$3; prev=$2}' \
      "$samp" >> "$RUNDIR/samples.jsonl"
  local comp drop ok p99 p999 maxms cpuutil=0
  comp=$(echo "$res" | sed 's/.*"completed_cps":\([0-9.]*\).*/\1/')
  drop=$(echo "$res" | sed 's/.*"drop_rate":\([0-9.]*\).*/\1/')
  ok=$(echo "$res"   | grep -o '"reply_ok":[a-z]*' | cut -d: -f2)
  p99=$(echo "$res"  | sed 's/.*"p99_ms":\([0-9.]*\).*/\1/')
  p999=$(echo "$res" | sed 's/.*"p99_9_ms":\([0-9.]*\).*/\1/')
  maxms=$(echo "$res"| sed 's/.*"max_ms":\([0-9.]*\).*/\1/')
  [ -n "$u0" ] && [ -n "$u1" ] && cpuutil=$(awk -v d=$((u1-u0)) -v c="$CORES" -v w="$wall" 'BEGIN{printf "%.3f", d/(c*w*1000000)}')
  printf '{"idx":%d,"offered":%d,"completed_cps":%s,"drop_rate":%s,"reply_ok":"%s","cpu_util":%s,"max_recvq":%s,"p99_ms":%s,"p99_9_ms":%s,"max_ms":%s}\n' \
    "$idx" "$RATE" "${comp:-0}" "${drop:-1}" "${ok:-false}" "$cpuutil" "${mq:-0}" "${p99:-0}" "${p999:-0}" "${maxms:-0}" >> "$STEPFILE"
  local gate_ok=1; [ "$ok" = "true" ] || gate_ok=0
  awk -v d="${drop:-1}" -v c="$DROP_CEILING" 'BEGIN{exit !(d<c)}' || gate_ok=0
  log "  step $idx: $kind=$RATE completed=${comp:-0}/s drop=${drop} reply_ok=${ok} cpu=${cpuutil} recvq=${mq} gate=$gate_ok"
  M_COMP=${comp:-0}; M_CPU=$cpuutil; M_RECVQ=${mq:-0}; M_DROP=${drop:-1}; M_GATE=$gate_ok
}

# run_ramp <stepfile> <do_sample> -> echoes "<max_sustained_conn_s> <ceiling_reason>".
# RAMP_MODE=adaptive: auto-scale offered load (geometric) until the SUT tops out — no hand-tuned
# rates. Stops on: gate fail | queue backpressure | CPU saturation | throughput plateau | RAMP_MAX.
# RAMP_MODE=fixed: step through harness/ramp.conf (legacy).
run_ramp(){
  local stepfile="$1" do_sample="${2:-0}"; STEPFILE="$stepfile"; : > "$stepfile"
  local best=0 reason="none" idx=0
  ceiling_hit(){ # uses M_*; sets reason; returns 0 if we should stop
    [ "$M_GATE" -eq 0 ] && { reason="gate_fail"; log "  -> gate fail, stop"; return 0; }
    best=$(awk -v b="$best" -v c="$M_COMP" 'BEGIN{printf "%d",(c>b?c:b)}')
    [ "$M_RECVQ" -gt "$QUEUE_HIGH" ] && { reason="queue_backpressure"; log "  -> recvq>$QUEUE_HIGH, ceiling"; return 0; }
    awk -v u="$M_CPU" 'BEGIN{exit !(u>0.98)}' && { reason="cpu_saturation"; log "  -> cpu saturated, ceiling"; return 0; }
    return 1
  }
  CEIL_CONNS="${CONN_START:-32}"   # in-flight level that achieved `best` (for the profiling passes)
  if [ "${RAMP_MODE:-adaptive}" = adaptive ]; then
    # scale CONCURRENCY (in-flight connections), not offered rate: closed-loop can't congestion-collapse
    local conns="${CONN_START:-32}" prev=0
    while [ "$conns" -le "${CONN_MAX:-200000}" ]; do
      measure_step conns "$conns" "$idx" "$do_sample"
      [ "$M_GATE" -ne 0 ] && awk -v c="$M_COMP" -v b="$best" 'BEGIN{exit !(c>b)}' && CEIL_CONNS="$conns"
      ceiling_hit && break
      # throughput plateau: completed grew < PLATEAU_GAIN despite more concurrency -> SUT is the limit
      if [ "$idx" -gt 0 ] && awk -v c="$M_COMP" -v p="$prev" -v g="${PLATEAU_GAIN:-0.03}" 'BEGIN{exit !(c<=p*(1+g))}'; then
        reason="throughput_plateau"; log "  -> completed plateau ($M_COMP vs $prev), ceiling"; break; fi
      prev="$M_COMP"; idx=$((idx+1))
      conns=$(awk -v r="$conns" -v g="${CONN_GROWTH:-2}" 'BEGIN{printf "%d", r*g}')
    done
  else
    while read -r RATE; do
      [[ "$RATE" =~ ^[0-9]+$ ]] || continue
      measure_step rate "$RATE" "$idx" "$do_sample"
      ceiling_hit && break
      idx=$((idx+1))
    done < "$RAMP_CONF"
  fi
  echo "$best $reason"
}

# ---- 4. syscall profile (best-effort analytics, not gated) ----------------
profile_syscalls(){   # writes $1 with per-conn counts
  local out="$1"
  command -v strace >/dev/null || { echo '{}' > "$out"; return; }
  ( strace -f -c -p "$ARM_PID" -o "$RUNDIR/strace.txt" 2>/dev/null ) &
  local sp=$!
  local res; res=$(loadgen_run conns "${CEIL_CONNS:-256}" 3 "$LG_THREADS" 0)
  kill -INT "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  local comp; comp=$(echo "$res" | sed 's/.*"completed":\([0-9]*\).*/\1/'); [ "${comp:-0}" -lt 1 ] && comp=1
  awk -v C="$comp" '
    /^[ ]*[0-9].*[a-z_0-9]+$/ {n=$NF; c=$4; if(c ~ /^[0-9]+$/) cnt[n]=c}
    END{ printf "{"; first=1; split("io_uring_enter accept4 read write close epoll_wait recvfrom sendto",k," ");
      for(i in k){key=k[i]; v=(key in cnt)?cnt[key]/C:0; printf "%s\"%s\":%.4f",(first?"":","),key,v; first=0} printf "}" }' \
    "$RUNDIR/strace.txt" > "$out" 2>/dev/null || echo '{}' > "$out"
}

# perf pass: IPC + instructions-per-connection. instr/conn is FREQUENCY-INDEPENDENT, so it's a
# far less noisy efficiency signal than conn/s on a VM whose clock wanders. (LLC misses aren't
# exposed by this VM's PMU.) Best-effort, not gated.
perf_pass(){   # writes {"ipc":..,"instr_pc":..} to $1
  local out="$1"
  command -v perf >/dev/null || { echo '{}' > "$out"; return; }
  # instructions/cycles (IPC) + context-switches/cpu-migrations (software events; work without PMU)
  perf stat -e instructions,cycles,context-switches,cpu-migrations -p "$ARM_PID" \
    -o "$RUNDIR/perf.txt" -- sleep 3 2>/dev/null &
  local pp=$!
  local res; res=$(loadgen_run conns "${CEIL_CONNS:-256}" 3 "$LG_THREADS" 0)
  wait "$pp" 2>/dev/null
  local comp; comp=$(echo "$res" | sed 's/.*"completed":\([0-9]*\).*/\1/'); [ "${comp:-0}" -lt 1 ] && comp=1
  RUNDIR="$RUNDIR" COMP="$comp" OUT="$out" python3 <<'PY'
import os,re
e=os.environ
try: txt=open(os.path.join(e["RUNDIR"],"perf.txt")).read()
except Exception: txt=""
def num(p):
    m=re.search(r'([\d,]+)\s+'+re.escape(p), txt); return int(m.group(1).replace(',','')) if m else 0
ins=num('instructions'); cyc=num('cycles'); cs=num('context-switches'); mg=num('cpu-migrations')
comp=int(e["COMP"])
open(e["OUT"],"w").write('{"ipc":%.3f,"instr_pc":%.0f,"ctxsw_pc":%.4f,"migr_pc":%.4f}'%(
  (ins/cyc if cyc else 0),(ins/comp if comp else 0),(cs/comp if comp else 0),(mg/comp if comp else 0)))
PY
}

# function-level CPU profile: WHERE the cycles go. Uses cpu-clock software sampling (no hardware
# PMU needed). Writes category split (kernel/user/liburing/libc %) + top symbols. This is what
# reveals that ~all CPU is kernel-side TCP/netstack, not the arm's own code.
profile_functions(){   # writes {kernel_pct,user_pct,liburing_pct,libc_pct,top:[...]} to $1
  local out="$1"
  command -v perf >/dev/null || { echo '{}' > "$out"; return; }
  perf record -e cpu-clock -F 997 -p "$ARM_PID" -o "$RUNDIR/perf-fn.data" -- sleep 4 2>/dev/null &
  local rp=$!
  loadgen_run conns "${CEIL_CONNS:-256}" 4 "$LG_THREADS" 0 >/dev/null 2>&1
  wait "$rp" 2>/dev/null
  perf report -i "$RUNDIR/perf-fn.data" --stdio --percent-limit 0.1 2>/dev/null > "$RUNDIR/perf-fn.txt" || true
  ARM_COMM="$(basename "$BIN")" FN="$RUNDIR/perf-fn.txt" OUT="$out" python3 <<'PY'
import os,re,json
e=os.environ
try: txt=open(e["FN"]).read()
except Exception: txt=""
comm=e.get("ARM_COMM","")
rx=re.compile(r'^\s*([\d.]+)%\s+(\S+)\s+(\S+)\s+\[([k.])\]\s+(.+?)\s*$')
top=[]; cat={"kernel":0.0,"user":0.0,"liburing":0.0,"libc":0.0,"other":0.0}
for ln in txt.splitlines():
    m=rx.match(ln)
    if not m: continue
    pct=float(m.group(1)); dso=m.group(3); kd=m.group(4); sym=m.group(5)
    if kd=='k' or 'kernel' in dso: c='kernel'
    elif 'liburing' in dso: c='liburing'
    elif 'libc' in dso or 'ld-' in dso: c='libc'
    elif comm in dso: c='user'
    else: c='other'
    cat[c]=cat.get(c,0)+pct
    if len(top)<25: top.append({"sym":sym[:80],"module":dso[:40],"pct":pct,"cat":c})
open(e["OUT"],"w").write(json.dumps({"kernel_pct":round(cat["kernel"],2),"user_pct":round(cat["user"],2),
  "liburing_pct":round(cat["liburing"],2),"libc_pct":round(cat["libc"],2),"top":top}))
PY
}

# ---- 5. record ------------------------------------------------------------
# reads per-step / syscall JSON from files (robust — never pass big JSON via argv)
record_score(){   # score max_sustained reason [stepfile] [syscfile] [perffile] [spread] [funcfile]
  local score="$1" mx="$2" reason="$3" stepfile="${4:-}" syscfile="${5:-}" perffile="${6:-}" spread="${7:-0}" funcfile="${8:-}"
  CFG_HASH=""
  [ "$ARM" = treatment ] && CFG_HASH="$(git rev-parse HEAD 2>/dev/null || echo '')"
  RUNID="$RUNID" ARM="$ARM" SCORE="$score" MX="$mx" CORES="$CORES" REASON="$reason" SPREAD="$spread" \
  ENVFP="$ENVFP" STEPFILE="$stepfile" SYSCFILE="$syscfile" PERFFILE="$perffile" FUNCFILE="$funcfile" \
  NREPS="${N:-1}" HIST="$HISTORY" CFG_HASH="$CFG_HASH" \
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
         spread_pct=float(e["SPREAD"]),median_of=int(e["NREPS"]),
         per_step=loadsteps(e["STEPFILE"]),syscall_profile=loadjson(e["SYSCFILE"]),
         perf=loadjson(e["PERFFILE"]),func_profile=loadjson(e["FUNCFILE"]))
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
  read -r mx REASON < <(run_ramp "$RUNDIR/steps.$rep.jsonl" "$([ "$rep" -eq 1 ] && echo 1 || echo 0)")
  SCORES+=( "$mx" )
  if [ "$rep" -eq 1 ]; then profile_syscalls "$RUNDIR/syscall.json"; perf_pass "$RUNDIR/perf.json"; profile_functions "$RUNDIR/funcprof.json"; fi
  stop_arm; sleep "$SETTLE"; sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
done
# median of reps
MEDIAN=$(printf '%s\n' "${SCORES[@]}" | sort -n | awk '{a[NR]=$1}END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')
SCORE=$(awk -v m="$MEDIAN" -v c="$CORES" 'BEGIN{printf "%.2f", m/c}')
SPREAD=$(printf '%s\n' "${SCORES[@]}" | sort -n | awk '{a[NR]=$1}END{if(a[1]>0)printf "%.1f",(a[NR]-a[1])/a[1]*100; else print 0}')
log "reps=${SCORES[*]} median_conn_s=$MEDIAN score=$SCORE spread=${SPREAD}% ceiling=$REASON"
record_score "$SCORE" "$MEDIAN" "$REASON" "$RUNDIR/steps.1.jsonl" "$RUNDIR/syscall.json" "$RUNDIR/perf.json" "$SPREAD" "$RUNDIR/funcprof.json"
