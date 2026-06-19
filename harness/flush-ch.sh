#!/usr/bin/env bash
# flush-ch.sh — best-effort flush of new HISTORY.jsonl rows into ClickHouse acceptbench.runs.
# Tracks a high-water mark in results/.ch_flushed (count already flushed). CH down => no-op.
# Runs only in the ANALYTICS phase (never while an arm is under measurement).
set -uo pipefail
cd "$(dirname "$0")/.."
. harness/config
HW="$RESULTS_DIR/.ch_flushed"
[ -f "$HISTORY" ] || exit 0
clickhouse-client --query "SELECT 1" >/dev/null 2>&1 || { echo "[flush-ch] CH unreachable, skip" >&2; exit 0; }
last=$(cat "$HW" 2>/dev/null || echo 0)
total=$(wc -l < "$HISTORY")
[ "$total" -le "$last" ] && exit 0

# Python opens HISTORY itself (NO stdin pipe — a heredoc on `python3 -` would shadow stdin and
# silently read zero rows). Args: history-path  start-line(1-based, exclusive)  db.
HIST="$HISTORY" START="$last" CHDB="$CH_DB" python3 <<'PY'
import os, json, subprocess, datetime
hist=os.environ["HIST"]; start=int(os.environ["START"]); db=os.environ["CHDB"]
rows=[]; steprows=[]; profrows=[]
for i,line in enumerate(open(hist),1):
    if i<=start: continue
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except Exception: continue
    sp=r.get("syscall_profile") or {}; g=r.get("gate") or {}; pf=r.get("perf") or {}
    fp=r.get("func_profile") or {}
    ts=datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"); runid=r.get("runid","")
    rows.append({
        "ts": ts, "runid": runid, "arm": r.get("arm",""),
        "config_hash": r.get("config_hash") or "", "parent_hash": "",
        "hypothesis": r.get("notes",""), "score": float(r.get("score",0)),
        "max_sustained_conn_s": int(r.get("max_sustained_conn_s",0)),
        "cores": int(r.get("cores",0)), "ceiling_reason": r.get("ceiling_reason",""),
        "gate_passed": 1 if (r.get("score",0)>0) else 0,
        "drop_rate": float(g.get("drop_rate",0) or 0),
        "median_of": int(r.get("median_of",1) or 1), "spread_pct": float(r.get("spread_pct",0) or 0),
        "sysc_io_uring_enter": sp.get("io_uring_enter",0), "sysc_accept4": sp.get("accept4",0),
        "sysc_read": sp.get("read",0), "sysc_write": sp.get("write",0),
        "sysc_close": sp.get("close",0), "sysc_epoll_wait": sp.get("epoll_wait",0),
        "perf_ipc": float(pf.get("ipc",0) or 0), "perf_instr_pc": float(pf.get("instr_pc",0) or 0),
        "cpu_kernel_pct": float(fp.get("kernel_pct",0) or 0), "cpu_user_pct": float(fp.get("user_pct",0) or 0),
        "cpu_liburing_pct": float(fp.get("liburing_pct",0) or 0),
        "perf_llc_miss_pc":0,"perf_ctxsw_pc":0,
        "kernel":"", "env_fingerprint": r.get("env_fingerprint",""),
        "input_tokens":0,"output_tokens":0,"cache_read_tokens":0,"cache_write_tokens":0,"cost_usd":0,
    })
    # per-step rows (embedded in the HISTORY row) -> steps table
    for s in (r.get("per_step") or []):
        steprows.append({
            "ts": ts, "runid": runid, "step_idx": int(s.get("idx",0)),
            "offered_cps": int(s.get("offered",0)), "completed_cps": int(float(s.get("completed_cps",0))),
            "failed_cps": 0, "cpu_util": float(s.get("cpu_util",0)),
            "max_recvq": int(s.get("max_recvq",0)), "p50_accept_ms": 0.0,
            "p99_accept_ms": float(s.get("p99_ms",0)), "is_ceiling": 0,
        })
    # function-level profile rows -> profile table (top hot symbols)
    for rank,t in enumerate(fp.get("top") or [], 1):
        profrows.append({
            "ts": ts, "runid": runid, "rank": rank, "symbol": t.get("sym",""),
            "module": t.get("module",""), "category": t.get("cat","other"),
            "self_pct": float(t.get("pct",0)),
        })
if not rows:
    raise SystemExit(0)
def insert(table, data):
    if not data: return 0
    p=subprocess.run(["clickhouse-client","--query", f"INSERT INTO {db}.{table} FORMAT JSONEachRow"],
                     input="\n".join(json.dumps(x) for x in data), text=True, capture_output=True)
    if p.returncode!=0:
        import sys; sys.stderr.write(f"[flush-ch] {table} insert failed: "+p.stderr[:300]+"\n"); raise SystemExit(1)
    return len(data)
n=insert("runs", rows); insert("steps", steprows); insert("profile", profrows)
print(n)
PY
rc=$?
if [ "$rc" -eq 0 ]; then echo "$total" > "$HW"; echo "[flush-ch] flushed up to line $total" >&2; fi
exit 0
