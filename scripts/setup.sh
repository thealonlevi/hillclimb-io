#!/usr/bin/env bash
# scripts/setup.sh — one-shot, idempotent bring-up of accept-bench on a fresh Ubuntu 24.04 box.
# Distilled from docs/BUILD_LOG.md (a real run). Re-runnable: every step guards against re-doing
# work. Run as root on an ISOLATED box (it tunes sysctls, cgroups, and runs claude as root).
#
#   sudo bash scripts/setup.sh            # full install + build + verify
#   sudo bash scripts/setup.sh --no-claude-check   # skip the claude/MCP smoke (offline)
#
# Single-box dev/functional topology (loadgen + SUT co-resident on distinct cpusets over
# loopback). Production 2-box measurement (second loadgen box, 10GbE, NIC IRQ pinning, no_turbo)
# is NOT configured here — see docs/ENVIRONMENT.md (Track B).
set -uo pipefail
GO_VERSION="${GO_VERSION:-1.25.11}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok(){  printf '   \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '   \033[33m!\033[0m %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }

# ---------------------------------------------------------------------------
say "0. preflight: kernel + cgroup v2"
KREL="$(uname -r)"; ok "kernel $KREL"
case "$KREL" in 5.1[0-8]*|4.*|5.[0-9].*) warn "kernel < 5.19: io_uring multishot accept unavailable";; esac
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || { echo "cgroup v2 not mounted"; exit 1; }
ok "cgroup v2 present"

# ---------------------------------------------------------------------------
say "1. toolchain (apt: build-essential, liburing, python venv, utils)"
export DEBIAN_FRONTEND=noninteractive
need_apt=0
for p in gcc make pkg-config; do command -v $p >/dev/null || need_apt=1; done
[ -f /usr/include/liburing.h ] || need_apt=1
if [ "$need_apt" = 1 ]; then
  apt-get update -qq
  apt-get install -y -qq build-essential pkg-config liburing-dev python3-venv python3-pip \
                        curl ca-certificates git iproute2 procps >/dev/null
fi
ok "gcc $(gcc -dumpversion), liburing $(pkg-config --modversion liburing 2>/dev/null || echo '?')"

# ---- Go (not in apt at this version) --------------------------------------
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
fi
grep -q '/usr/local/go/bin' /etc/profile.d/go.sh 2>/dev/null || \
  echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' > /etc/profile.d/go.sh
export PATH="$PATH:/usr/local/go/bin"
ok "$(go version)"

# ---- ClickHouse (self-contained binary; --noninteractive => empty default password) --------
if ! command -v clickhouse >/dev/null; then
  ( cd /tmp && curl -fsSL https://clickhouse.com/ | sh >/dev/null 2>&1 && ./clickhouse install --noninteractive >/dev/null 2>&1 )
fi
command -v clickhouse >/dev/null && ok "clickhouse $(clickhouse --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || warn "clickhouse install failed"
# start server + wait for it
clickhouse-client --query "SELECT 1" >/dev/null 2>&1 || clickhouse start >/dev/null 2>&1 || true
for i in $(seq 1 20); do clickhouse-client --query "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
clickhouse-client --query "SELECT 1" >/dev/null 2>&1 && ok "clickhouse server up" || warn "clickhouse not responding"

# ---- mcp-clickhouse in an isolated venv (24.04 is PEP-668 externally-managed) --------------
if [ ! -x "$REPO/.mcp-venv/bin/mcp-clickhouse" ]; then
  python3 -m venv "$REPO/.mcp-venv"
  "$REPO/.mcp-venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
  "$REPO/.mcp-venv/bin/pip" install -q mcp-clickhouse >/dev/null 2>&1
fi
[ -x "$REPO/.mcp-venv/bin/mcp-clickhouse" ] && ok "mcp-clickhouse venv ready" || warn "mcp-clickhouse install failed"
# generate the ClickHouse MCP config (env-specific absolute path; gitignored)
cat > harness/mcp-clickhouse.json <<JSON
{ "mcpServers": { "clickhouse": { "command": "$REPO/.mcp-venv/bin/mcp-clickhouse",
  "env": { "CLICKHOUSE_HOST": "localhost", "CLICKHOUSE_PORT": "8123", "CLICKHOUSE_USER": "optimizer",
           "CLICKHOUSE_PASSWORD": "", "CLICKHOUSE_SECURE": "false", "CLICKHOUSE_VERIFY": "false" } } } }
JSON
ok "harness/mcp-clickhouse.json generated"

# ---------------------------------------------------------------------------
say "2. environment: sysctls (single-box loadgen needs wide ports + tw_reuse)"
sysctl -p harness/sysctl-bench.conf >/dev/null 2>&1 && ok "sysctls applied" || warn "sysctl apply failed"

say "3. cgroup v2 cpuset partitions (NOT persistent across reboot — re-run after boot)"
# delegate the cpuset controller into the root subtree (the easy-to-miss prerequisite)
grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control || echo "+cpuset +cpu +memory" > /sys/fs/cgroup/cgroup.subtree_control
bash harness/cgroups.sh && ok "cgroups created (sut=2-5 excl, loadgen=6-11, ch=0-1,12)"

# ---------------------------------------------------------------------------
say "4. ClickHouse schema + optimizer user"
clickhouse-client --multiquery < harness/schema.sql 2>/dev/null && ok "acceptbench.{runs,steps,samples} created"
clickhouse-client --query "CREATE USER IF NOT EXISTS optimizer IDENTIFIED WITH no_password" 2>/dev/null
clickhouse-client --query "GRANT SELECT, INSERT ON acceptbench.* TO optimizer" 2>/dev/null && ok "optimizer user granted"

# ---------------------------------------------------------------------------
say "5. build all three binaries"
make -C loadgen >/dev/null 2>&1 && ok "loadgen built" || warn "loadgen build failed"
( cd control && go build -o accept-control . ) && ok "control/accept-control built" || warn "control build failed"
make -C treatment >/dev/null 2>&1 && ok "treatment/accept-treat built" || warn "treatment build failed"
# the optimizer loop versions treatment/ in THIS monorepo and reverts with `git reset --hard
# HEAD~1`, so ensure a baseline commit exists (a clone already has one; a tarball download won't)
if ! git rev-parse HEAD >/dev/null 2>&1; then
  git init -q
  git -c user.email=opt@accept-bench.local -c user.name=accept-bench add -A
  git -c user.email=opt@accept-bench.local -c user.name=accept-bench commit -q -m "baseline"
  ok "git baseline commit created"
fi
mkdir -p results kbs
[ -f results/BEST.json ] || echo '{"config_hash":null,"score":0,"cores":4,"note":"no champion yet"}' > results/BEST.json
chmod +x harness/*.sh scripts/*.sh 2>/dev/null

# ---------------------------------------------------------------------------
say "6. verify claude -p (optimizer brain) — needs IS_SANDBOX=1 to run skip-perms as root"
if [ "${1:-}" = "--no-claude-check" ]; then warn "skipped (--no-claude-check)"; else
  if command -v claude >/dev/null; then
    R=$(timeout 90 env IS_SANDBOX=1 claude -p "reply with exactly: READY" \
         --dangerously-skip-permissions --output-format json 2>/dev/null \
         | python3 -c "import sys,json;print(json.load(sys.stdin).get('result','').strip())" 2>/dev/null)
    [ "$R" = "READY" ] && ok "claude -p works as root (IS_SANDBOX=1)" \
       || warn "claude -p check inconclusive (got: '$R') — ensure 'claude' is authenticated"
  else warn "claude binary not found — install Claude Code before running the optimizer loop"; fi
fi

# ---------------------------------------------------------------------------
say "DONE — accept-bench is set up"
cat <<EOF
   Smoke-test a single arm:
     WARMUP_OVERRIDE=2 MEASURE_OVERRIDE=3 N_OVERRIDE=1 RAMP_OVERRIDE=harness/ramp.dev.conf \\
       harness/run.sh control-frozen
   One optimizer iteration (claude edits treatment, harness scores, keep/revert):
     MAX_ITERS=1 WARMUP_OVERRIDE=2 MEASURE_OVERRIDE=3 N_OVERRIDE=1 RAMP_OVERRIDE=harness/ramp.dev.conf \\
       harness/loop.sh
   Full autonomous climb (real 10s/30s x N=3 windows):  harness/loop.sh   (stop: touch results/STOP)
EOF
