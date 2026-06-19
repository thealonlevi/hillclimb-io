#!/usr/bin/env python3
"""accept-bench web dashboard — live visibility into the optimizer loop.

Serves on :1000. Reads local loop state (iterations.csv, loop.out, BEST.json) for the live view
and lightly queries the co-located ClickHouse (cached ~4s) for history + the syscall-profile lever.
Pin it to the non-SUT cores (harness/start-webui.sh) so it never steals cycles from the SUT.

Stdlib only — no pip deps. Charts via Chart.js CDN (the dashboard box has egress; the *arm* does
not — this is a separate service).
"""
import json, os, re, subprocess, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(REPO, "results")
LOGOUT = os.path.join(RESULTS, "loop-logs", "loop.out")
ITERCSV = os.path.join(RESULTS, "loop-logs", "iterations.csv")
BEST = os.path.join(RESULTS, "BEST.json")
CTRL = os.path.join(RESULTS, "CONTROL_BASELINE.json")
PORT = int(os.environ.get("WEBUI_PORT", "1000"))
CH_DB = os.environ.get("CH_DB", "acceptbench")

_cache = {}
def cached(key, ttl, fn):
    now = time.time()
    if key in _cache and now - _cache[key][0] < ttl:
        return _cache[key][1]
    try: val = fn()
    except Exception: val = _cache.get(key, (0, None))[1]
    _cache[key] = (now, val)
    return val

def ch(sql):
    def _q():
        req = urllib.request.Request("http://localhost:8123/", data=(sql + " FORMAT JSON").encode())
        return json.loads(urllib.request.urlopen(req, timeout=3).read()).get("data", [])
    return cached("ch:" + sql, 4, _q) or []

def read_json(p, default):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return default

def tail(p, n):
    try:
        with open(p, "rb") as f:
            return f.read().decode("utf-8", "replace").splitlines()[-n:]
    except Exception: return []

def loop_state():
    try:
        pid = subprocess.check_output(["pgrep", "-f", "harness/loop.sh"], text=True).split()[0]
    except Exception:
        pid = None
    lines = tail(LOGOUT, 200)
    phase = "—"
    if lines:
        last = lines[-1].lower()
        phase = "MEASURE (ramp)" if re.search(r"ramp|step|measur", last) else "ANALYTICS (claude)"
    it = nimp = pat = 0
    for ln in reversed(lines):
        m = re.search(r"iteration (\d+) \(no_improve=(\d+)/(\d+)\)", ln)
        if m:
            it, nimp, pat = int(m.group(1)), int(m.group(2)), int(m.group(3)); break
    hyp = ""
    for ln in reversed(lines):
        m = re.search(r'hyp="([^"]*)"', ln)
        if m: hyp = m.group(1); break
    return {"running": bool(pid), "pid": pid, "phase": phase if pid else "stopped",
            "iter": it, "no_improve": nimp, "patience": pat, "last_hypothesis": hyp}

def iterations():
    rows = []
    try:
        with open(ITERCSV) as f:
            hdr = f.readline().strip().split(",")
            for ln in f:
                v = ln.strip().split(",")
                if len(v) >= len(hdr): rows.append(dict(zip(hdr, v)))
    except Exception: pass
    return rows

def mutations():
    def _q():
        out = subprocess.check_output(
            ["git", "-C", REPO, "log", "--grep=^optimize", "-n", "40",
             "--pretty=%h\t%ct\t%s"], text=True)
        res = []
        for ln in out.splitlines():
            h, t, s = ln.split("\t", 2)
            res.append({"sha": h, "ts": int(t), "msg": s[:240]})
        return res
    return cached("mut", 8, _q) or []

def api_state():
    its = iterations()
    promotes = sum(1 for r in its if r.get("verdict") == "promote")
    reverts = sum(1 for r in its if str(r.get("verdict", "")).startswith("revert"))
    def _i(x):
        try: return int(float(x or 0))
        except Exception: return 0
    tokens = sum(_i(r.get("in_tokens", 0)) for r in its)
    cum = its[-1]["cum_cost_usd"] if its else "0"
    runs = ch(f"SELECT arm, round(score,1) AS score, max_sustained_conn_s AS conn_s, "
              f"round(sysc_io_uring_enter,2) AS enter_pc, round(sysc_accept4,2) AS accept_pc, "
              f"round(drop_rate,5) AS drop, ceiling_reason AS ceiling, toString(ts) AS ts "
              f"FROM {CH_DB}.runs ORDER BY ts DESC LIMIT 25")
    # treatment score + lever trajectory from CH (oldest->newest)
    traj = ch(f"SELECT toString(ts) AS ts, round(score,1) AS score, max_sustained_conn_s AS conn_s, "
              f"round(sysc_io_uring_enter,3) AS enter_pc, round(perf_instr_pc,0) AS instr_pc, "
              f"round(perf_ipc,3) AS ipc, round(spread_pct,1) AS spread FROM {CH_DB}.runs "
              f"WHERE arm='treatment' AND gate_passed=1 ORDER BY ts ASC LIMIT 500")
    split = ch(f"SELECT round(cpu_kernel_pct,1) AS kernel, round(cpu_user_pct,1) AS user, "
               f"round(cpu_liburing_pct,1) AS liburing, runid FROM {CH_DB}.runs "
               f"WHERE arm='treatment' AND cpu_kernel_pct>0 ORDER BY ts DESC LIMIT 1")
    hot = []
    if split:
        hot = ch(f"SELECT rank, category, round(self_pct,2) AS pct, symbol FROM {CH_DB}.profile "
                 f"WHERE runid='{split[0]['runid']}' ORDER BY rank LIMIT 14")
    return {
        "now": time.strftime("%Y-%m-%d %H:%M:%S"),
        "loop": loop_state(),
        "cpu_split": split[0] if split else None,
        "hot_functions": hot,
        "champion": read_json(BEST, {}),
        "control_baseline": read_json(CTRL, {}).get("score"),
        "totals": {"iterations": len(its), "promotes": promotes, "reverts": reverts,
                   "cost_usd": cum, "tokens": tokens},
        "iterations": its[-200:],
        "runs": runs,
        "trajectory": traj,
        "mutations": mutations(),
    }

class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/api/state"):
            self._send(200, json.dumps(api_state()).encode(), "application/json")
        elif self.path.startswith("/api/log"):
            self._send(200, json.dumps({"lines": tail(LOGOUT, 80)}).encode(), "application/json")
        else:
            self._send(200, PAGE.encode(), "text/html; charset=utf-8")

PAGE = r"""<!doctype html><html><head><meta charset=utf-8>
<title>accept-bench optimizer</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
:root{--bg:#0d1117;--card:#161b22;--bd:#30363d;--fg:#e6edf3;--mut:#8b949e;--grn:#3fb950;--red:#f85149;--blu:#58a6ff;--yel:#d29922}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
.wrap{max-width:1280px;margin:0 auto;padding:18px}
h1{font-size:18px;margin:0 0 2px}.sub{color:var(--mut);font-size:12px;margin-bottom:14px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-bottom:14px}
.card{background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:12px}
.card .k{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.5px}
.card .v{font-size:22px;font-weight:600;margin-top:3px}
.badge{display:inline-block;padding:2px 9px;border-radius:20px;font-size:12px;font-weight:600}
.run{background:rgba(63,185,80,.15);color:var(--grn)}.stop{background:rgba(248,81,73,.15);color:var(--red)}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px}@media(max-width:880px){.grid2{grid-template-columns:1fr}}
.panel{background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:12px;margin-bottom:12px}
.panel h2{font-size:12px;text-transform:uppercase;letter-spacing:.5px;color:var(--mut);margin:0 0 8px}
table{width:100%;border-collapse:collapse;font-size:12px}th,td{text-align:left;padding:5px 7px;border-bottom:1px solid var(--bd);white-space:nowrap}
th{color:var(--mut);font-weight:500}.t-treatment{color:var(--blu)}.t-control-frozen{color:var(--yel)}
.v-promote{color:var(--grn)}.v-revert-fail{color:var(--red)}.v-revert-regression{color:var(--mut)}
pre{background:#010409;border:1px solid var(--bd);border-radius:8px;padding:10px;max-height:240px;overflow:auto;font-size:11.5px;margin:0}
.bar{height:8px;background:#21262d;border-radius:5px;overflow:hidden;margin-top:6px}.bar>i{display:block;height:100%;background:var(--blu)}
.flex{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
small{color:var(--mut)}
</style></head><body><div class=wrap>
<div class=flex><div><h1>accept-bench · optimizer dashboard</h1><div class=sub id=sub>loading…</div></div>
<div id=statusbadge></div></div>
<div class=cards id=cards></div>
<div class=grid2>
 <div class=panel><h2>score per iteration (treatment vs control baseline)</h2><canvas id=cScore height=140></canvas></div>
 <div class=panel><h2>instructions per connection — frequency-independent (cleaner than score; lower = better)</h2><canvas id=cInstr height=140></canvas></div>
</div>
<div class=grid2>
 <div class=panel><h2>io_uring_enter per connection — syscall lever (lower = better)</h2><canvas id=cLever height=120></canvas></div>
 <div class=panel><h2>max sustained conn/s</h2><canvas id=cConn height=120></canvas></div>
</div>
<div class=grid2>
 <div class=panel><h2>cumulative cost ($)</h2><canvas id=cCost height=120></canvas></div>
 <div class=panel><h2>IPC (instructions per cycle)</h2><canvas id=cIpc height=120></canvas></div>
</div>
<div class=panel><h2>where the CPU goes (function-level profile of the champion)</h2>
 <div id=cpusplit style="margin-bottom:8px"></div>
 <div style="max-height:300px;overflow:auto"><table id=hot></table></div></div>
<div class=panel><h2>recent runs</h2><div style=overflow-x:auto><table id=runs></table></div></div>
<div class=grid2>
 <div class=panel><h2>mutation log (what the agent tried)</h2><div style="max-height:240px;overflow:auto"><table id=muts></table></div></div>
 <div class=panel><h2>live loop log</h2><pre id=log></pre></div>
</div>
<div class=sub>refreshes every 4s · stop loop: <code>touch results/STOP</code></div>
</div>
<script>
const charts={};
function mkLine(id,labels,sets,opts={}){
 const ctx=document.getElementById(id);
 if(charts[id]){charts[id].data.labels=labels;charts[id].data.datasets=sets;charts[id].update('none');return;}
 charts[id]=new Chart(ctx,{type:'line',data:{labels,datasets:sets},options:Object.assign({
  responsive:true,animation:false,plugins:{legend:{labels:{color:'#8b949e',boxWidth:12,font:{size:11}}}},
  scales:{x:{ticks:{color:'#6e7681',maxTicksLimit:10,font:{size:10}},grid:{color:'#21262d'}},
          y:{ticks:{color:'#6e7681',font:{size:10}},grid:{color:'#21262d'}}}},opts)});
}
const C={blu:'#58a6ff',grn:'#3fb950',yel:'#d29922',red:'#f85149',mut:'#8b949e'};
async function tick(){
 let s; try{s=await (await fetch('/api/state')).json();}catch(e){return;}
 let lg; try{lg=await (await fetch('/api/log')).json();}catch(e){lg={lines:[]};}
 document.getElementById('sub').textContent='updated '+s.now;
 const lp=s.loop, run=lp.running;
 document.getElementById('statusbadge').innerHTML=
  `<span class="badge ${run?'run':'stop'}">${run?'● RUNNING':'■ STOPPED'}</span>`+
  (run?` <small>pid ${lp.pid} · ${lp.phase}</small>`:'');
 const champ=s.champion||{}, cb=s.control_baseline;
 const t=s.totals;
 const patPct=lp.patience?Math.round(100*lp.no_improve/lp.patience):0;
 const its0=s.iterations||[]; const lastModel=its0.length?its0[its0.length-1].model:'—';
 const lastSpread=(s.trajectory&&s.trajectory.length)?s.trajectory[s.trajectory.length-1].spread:null;
 document.getElementById('cards').innerHTML=[
  card('champion score',(champ.score??'—'),cb!=null?`vs control ${cb}`:''),
  card('iterations',t.iterations,`${t.promotes} kept · ${t.reverts} reverted`),
  card('current iter',lp.iter||'—',`plateau ${lp.no_improve}/${lp.patience}<div class=bar><i style="width:${patPct}%"></i></div>`),
  card('measurement spread',lastSpread!=null?lastSpread+'%':'—','run-to-run noise floor'),
  card('model',lastModel,'last iteration'),
  card('cost spent','$'+(t.cost_usd||'0'),`${fmt(t.tokens)} tok · cumulative`),
 ].join('');
 // trajectory (CH, treatment) + iterations (csv)
 const tr=s.trajectory||[], its=s.iterations||[];
 const labs=its.map(r=>'#'+r.iter);
 mkLine('cScore',labs,[
   {label:'treatment score',data:its.map(r=>+r.score),borderColor:C.blu,backgroundColor:'transparent',pointRadius:2,tension:.2},
   {label:'champion',data:its.map(r=>+r.champion),borderColor:C.grn,borderDash:[4,4],pointRadius:0},
   ...(cb!=null?[{label:'control baseline',data:its.map(()=>cb),borderColor:C.yel,borderDash:[2,3],pointRadius:0}]:[])
 ]);
 mkLine('cInstr',tr.map((_,i)=>i+1),[{label:'instructions / conn',data:tr.map(r=>+r.instr_pc),borderColor:C.yel,backgroundColor:'transparent',pointRadius:2,tension:.2}]);
 mkLine('cLever',tr.map((_,i)=>i+1),[{label:'io_uring_enter / conn',data:tr.map(r=>+r.enter_pc),borderColor:C.red,backgroundColor:'transparent',pointRadius:2,tension:.2}]);
 mkLine('cCost',labs,[{label:'cum $',data:its.map(r=>+r.cum_cost_usd),borderColor:C.grn,fill:true,backgroundColor:'rgba(63,185,80,.08)',pointRadius:0}]);
 mkLine('cConn',tr.map((_,i)=>i+1),[{label:'conn/s',data:tr.map(r=>+r.conn_s),borderColor:C.blu,backgroundColor:'transparent',pointRadius:2,tension:.2}]);
 mkLine('cIpc',tr.map((_,i)=>i+1),[{label:'IPC',data:tr.map(r=>+r.ipc),borderColor:C.grn,backgroundColor:'transparent',pointRadius:2,tension:.2}]);
 // cpu split + hot functions
 const sp=s.cpu_split;
 if(sp){
   const k=+sp.kernel,u=+sp.user,lu=+sp.liburing,other=Math.max(0,100-k-u-lu);
   document.getElementById('cpusplit').innerHTML=
     `<div style="display:flex;height:22px;border-radius:5px;overflow:hidden;font-size:11px;line-height:22px;text-align:center">`+
     `<div style="width:${k}%;background:#f85149" title="kernel">${k>8?'kernel '+k+'%':''}</div>`+
     `<div style="width:${lu}%;background:#d29922" title="liburing">${lu>8?'liburing '+lu+'%':''}</div>`+
     `<div style="width:${u}%;background:#58a6ff" title="user">${u>8?'user '+u+'%':''}</div>`+
     `<div style="width:${other}%;background:#3fb950" title="other">${other>8?'other '+other+'%':''}</div></div>`+
     `<small>kernel ${k}% · liburing ${lu}% · user(arm code) ${u}% · other ${other}% — almost all CPU is kernel TCP/netstack, not the arm's code</small>`;
 }
 document.getElementById('hot').innerHTML='<tr><th>#</th><th>cat</th><th>self%</th><th>symbol</th></tr>'+
  (s.hot_functions||[]).map(h=>`<tr><td>${h.rank}</td><td class="t-${h.category=='kernel'?'control-frozen':'treatment'}">${h.category}</td><td>${h.pct}</td><td><code>${esc(h.symbol)}</code></td></tr>`).join('');
 // runs table
 document.getElementById('runs').innerHTML='<tr><th>time</th><th>arm</th><th>score</th><th>conn/s</th><th>io_uring_enter/c</th><th>accept4/c</th><th>drop</th><th>ceiling</th></tr>'+
  (s.runs||[]).map(r=>`<tr><td><small>${(r.ts||'').slice(5,19)}</small></td><td class="t-${r.arm}">${r.arm}</td><td>${r.score}</td><td>${r.conn_s}</td><td>${r.enter_pc}</td><td>${r.accept_pc}</td><td>${r.drop}</td><td>${r.ceiling}</td></tr>`).join('');
 // mutations
 document.getElementById('muts').innerHTML=(s.mutations||[]).map(m=>`<tr><td><small>${new Date(m.ts*1000).toISOString().slice(5,16).replace('T',' ')}</small></td><td><code>${m.sha}</code></td><td>${esc(m.msg).replace(/^optimize:\s*/,'')}</td></tr>`).join('')||'<tr><td><small>no mutations yet</small></td></tr>';
 document.getElementById('log').textContent=(lg.lines||[]).join('\n');
 const el=document.getElementById('log');el.scrollTop=el.scrollHeight;
}
function card(k,v,sub){return `<div class=card><div class=k>${k}</div><div class=v>${v}</div><small>${sub||''}</small></div>`}
function fmt(n){n=+n||0;return n>=1e6?(n/1e6).toFixed(2)+'M':n>=1e3?(n/1e3).toFixed(1)+'k':n}
function esc(s){return (s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
tick();setInterval(tick,4000);
</script></body></html>"""

class Server(ThreadingHTTPServer):
    daemon_threads = True        # don't let a stuck handler thread block shutdown
    request_queue_size = 128     # bigger accept backlog so a slow CH query can't wedge the listener

if __name__ == "__main__":
    print(f"accept-bench web UI on http://0.0.0.0:{PORT}  (repo={REPO})", flush=True)
    Server(("0.0.0.0", PORT), H).serve_forever()
