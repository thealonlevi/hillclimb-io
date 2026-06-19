#!/usr/bin/env bash
# harness/loop.sh — the autonomous optimization loop (the bash referee that drives `claude -p`).
# Strict MEASURE/ANALYTICS phase split (METRICS.md). Runs as root on the isolated SUT box.
#   ANALYTICS: flush CH, run `claude -p` to make ONE mutation in treatment/ (CH active).
#   MEASURE:   harness/run.sh treatment -> build/pin/ramp/score/gate (CH idle).
#   verdict:   keep (BEST.json + commit) on improvement, else `git reset --hard HEAD~1`.
# Stop with: touch results/STOP  (or Ctrl-C). One mutation per iteration.
set -uo pipefail
cd "$(dirname "$0")/.."
. harness/config
export IS_SANDBOX=1        # REQUIRED: lets `claude --dangerously-skip-permissions` run as root
export PATH=$PATH:/usr/local/go/bin
LOGDIR="$RESULTS_DIR/loop-logs"; mkdir -p "$LOGDIR"
MAX_ITERS="${MAX_ITERS:-1000000}"
log(){ echo "[loop $(date +%H:%M:%S)] $*"; }

# treatment is a subdir of this monorepo; git ops are scoped to treatment/ + kbs/ so a revert
# never touches the fixed harness/referee. (Each iteration only mutates those two paths.)
best_score(){ python3 -c "import json;print(json.load(open('$BEST')).get('score',0))" 2>/dev/null || echo 0; }
treat_head(){ git rev-parse HEAD 2>/dev/null || echo none; }
revert_worktree(){ git checkout -- treatment kbs 2>/dev/null; git clean -fdq treatment kbs 2>/dev/null; }

SID=""; iter=0; no_improve=0
log "starting. champion score=$(best_score). IS_SANDBOX=1, model=$OPT_MODEL."

while [ "$iter" -lt "$MAX_ITERS" ]; do
  [ -f "$RESULTS_DIR/STOP" ] && { log "STOP file present -> exiting"; rm -f "$RESULTS_DIR/STOP"; break; }
  iter=$((iter+1)); log "==== iteration $iter (no_improve=$no_improve/$PATIENCE) ===="

  # ---------- ANALYTICS phase (CH active; SUT not under measurement) ----------
  harness/flush-ch.sh || true
  PRE_HEAD="$(treat_head)"
  out=$(timeout "$ITER_TIMEOUT" env IS_SANDBOX=1 claude -p "$(cat harness/optimizer-prompt.md)" \
        ${SID:+--resume "$SID"} \
        --model "$OPT_MODEL" \
        --append-system-prompt-file harness/optimizer-system.md \
        --add-dir "$PWD/treatment" \
        --mcp-config harness/mcp-clickhouse.json \
        --dangerously-skip-permissions \
        --output-format json 2>>"$LOGDIR/claude-stderr.log")
  rc=$?
  if [ "$rc" -eq 124 ]; then log "claude timed out (${ITER_TIMEOUT}s) -> revert partial, no-op"; revert_worktree; continue; fi
  if [ "$rc" -ne 0 ];  then log "claude rc=$rc -> see claude-stderr.log; revert partial, no-op"; revert_worktree; continue; fi

  # parse session + token usage; rotate session on context pressure
  HYP=$(echo "$out" | python3 -c "import sys,json;print(json.load(sys.stdin).get('result','')[:500])" 2>/dev/null)
  SID=$(echo "$out" | python3 -c "import sys,json;print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)
  intok=$(echo "$out" | python3 -c "import sys,json;u=json.load(sys.stdin).get('usage',{});print(u.get('input_tokens',0))" 2>/dev/null || echo 0)
  cost=$(echo "$out" | python3 -c "import sys,json;print(json.load(sys.stdin).get('total_cost_usd',0))" 2>/dev/null || echo 0)
  log "claude done: in_tokens=$intok cost=\$$cost hyp=\"${HYP:0:80}\""
  if [ "${intok:-0}" -gt "$CTX_ROTATE_TOKENS" ]; then log "context ${intok} > ${CTX_ROTATE_TOKENS} -> rotating session next iter"; SID=""; fi

  # did the model actually change anything under treatment/ or kbs/?
  if git diff --quiet -- treatment kbs && [ -z "$(git status --porcelain -- treatment kbs)" ]; then
    log "no changes from claude this iter -> skip measure"; continue
  fi
  # harness owns the commit (one mutation = one commit), using the model's summary as the message
  git add -- treatment kbs
  git commit -q -m "optimize: ${HYP:-mutation (iter $iter)}" --author="optimizer <opt@accept-bench.local>"

  # ---------- MEASURE phase (CH idle) ----------
  res=$(harness/run.sh treatment)
  score=$(echo "$res" | python3 -c "import sys,json;print(json.load(sys.stdin).get('score',0))" 2>/dev/null || echo 0)
  best=$(best_score)
  thresh=$(awk -v b="$best" -v e="$EPSILON" 'BEGIN{printf "%.6f", b*(1+e)}')
  log "measured score=$score  champion=$best  promote-if>$thresh"

  # ---------- verdict (BEST.json local + authoritative) ----------
  if awk -v s="$score" 'BEGIN{exit !(s<=0)}'; then
    log "gate/build/crash failure (score 0) -> revert"; git reset --hard HEAD~1 -q; no_improve=$((no_improve+1))
  elif awk -v s="$score" -v t="$thresh" 'BEGIN{exit !(s>t)}'; then
    log "NEW CHAMPION ($score > $thresh) -> promote"
    python3 -c "import json;ch='$(treat_head)';json.dump({'config_hash':ch,'score':float('$score'),'cores':$CORES,'note':'champion'},open('$BEST','w'))"
    no_improve=0
  else
    log "not better -> revert (never keep a regression)"; git reset --hard HEAD~1 -q; no_improve=$((no_improve+1))
  fi

  # ---------- control-drift watchdog every K iterations ----------
  if [ $((iter % K)) -eq 0 ]; then
    log "watchdog: re-running control-frozen to check box drift"
    cres=$(harness/run.sh control-frozen); cscore=$(echo "$cres" | python3 -c "import sys,json;print(json.load(sys.stdin).get('score',0))" 2>/dev/null || echo 0)
    if [ -f "$RESULTS_DIR/CONTROL_BASELINE.json" ]; then
      base=$(python3 -c "import json;print(json.load(open('$RESULTS_DIR/CONTROL_BASELINE.json')).get('score',0))")
      drift=$(awk -v c="$cscore" -v b="$base" 'BEGIN{print (b>0)? (c-b)/b*100 : 0}')
      log "control score=$cscore baseline=$base drift=${drift}%"
      awk -v d="$drift" 'BEGIN{exit !(d<-5 || d>5)}' && { log "CONTROL DRIFT >5% -> PAUSE, flag human"; echo "control drift ${drift}% at iter $iter" >> "$RESULTS_DIR/PROPOSALS.md"; break; }
    else
      python3 -c "import json;json.dump({'score':float('$cscore')},open('$RESULTS_DIR/CONTROL_BASELINE.json','w'))"
      log "recorded control baseline=$cscore"
    fi
  fi

  # ---------- plateau detector ----------
  if [ "$no_improve" -ge "$PATIENCE" ]; then
    log "plateau: $no_improve configs w/o >${EPSILON} improvement -> generating REPORT.md and stopping"
    harness/report.sh 2>/dev/null || echo "(report.sh missing)"
    break
  fi
done
log "loop ended at iteration $iter. champion score=$(best_score)."
