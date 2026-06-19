#!/usr/bin/env python3
"""loadgen-server — HTTP wrapper around the loadgen binary, for the 2-box (Track B) setup.

Runs on BOX 2 (the load generator). Box 1's harness (run.sh) calls this over HTTP to drive a
load pass against the arm on box 1, and gets back the loadgen JSON (offered/completed/drop/gate/
latency). Keeping the loadgen on a separate box removes the single-box confounders (shared kernel
netstack, co-resident CPU contention, loopback) that made box-1 scores noisy.

Endpoints:
  GET /health                -> {"ok":true,...}
  GET /run?host=&port=&rate=&duration=&threads=&sample_pct=  -> loadgen JSON

Stdlib only. Start with scripts/setup-loadgen.sh (or: python3 loadgen/loadgen-server.py).
"""
import json, os, subprocess, shlex, resource
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# raise the open-fd limit so spawned loadgen subprocesses inherit it (high-latency links need many
# concurrent connections; default 1024 -> socket() EMFILE). Belt-and-suspenders with loadgen.c.
try:
    resource.setrlimit(resource.RLIMIT_NOFILE, (1048576, 1048576))
except Exception:
    try:
        h = resource.getrlimit(resource.RLIMIT_NOFILE)[1]; resource.setrlimit(resource.RLIMIT_NOFILE, (h, h))
    except Exception: pass

HERE = os.path.dirname(os.path.abspath(__file__))
LOADGEN = os.path.join(HERE, "loadgen")
PORT = int(os.environ.get("LOADGEN_API_PORT", "8088"))
MAX_DURATION = int(os.environ.get("LOADGEN_MAX_DURATION", "120"))

def run_loadgen(q):
    def g(k, d): return (q.get(k, [d])[0])
    host = g("host", "127.0.0.1")
    port = int(g("port", "31"))
    rate = float(g("rate", "1000"))
    conns = int(g("conns", "0"))          # >0 => closed-loop concurrency mode
    dur = min(float(g("duration", "5")), MAX_DURATION)
    threads = int(g("threads", "8"))
    sample = int(g("sample_pct", "5"))
    # basic sanity to avoid abuse
    if not host.replace(".", "").replace(":", "").replace("-", "").isalnum():
        raise ValueError("bad host")
    cmd = [LOADGEN, "--host", host, "--port", str(port),
           "--duration", str(dur), "--threads", str(threads), "--sample-pct", str(sample)]
    cmd += (["--conns", str(conns)] if conns > 0 else ["--rate", str(rate)])
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=dur + 30)
    if out.returncode != 0:
        return {"error": "loadgen failed", "stderr": out.stderr[:400], "cmd": " ".join(map(shlex.quote, cmd))}
    return json.loads(out.stdout.strip().splitlines()[-1])

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        # compact separators => byte-identical to the C loadgen's stdout, so run.sh's sed
        # parsers (which assume no space after ':') work the same for local and remote.
        b = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/health":
            self._send(200, {"ok": True, "loadgen_present": os.path.exists(LOADGEN),
                             "max_duration": MAX_DURATION, "cores": os.cpu_count() or 1})
        elif u.path == "/run":
            try: self._send(200, run_loadgen(parse_qs(u.query)))
            except Exception as e: self._send(500, {"error": str(e)})
        else:
            self._send(404, {"error": "not found"})
    do_POST = do_GET  # accept POST too

if __name__ == "__main__":
    if not os.path.exists(LOADGEN):
        print(f"WARNING: loadgen binary not found at {LOADGEN} — run `make -C loadgen` first", flush=True)
    print(f"loadgen-server on :{PORT}  (binary={LOADGEN}, max_duration={MAX_DURATION}s)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
