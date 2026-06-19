#!/usr/bin/env bash
# scripts/setup-loadgen.sh — one-shot setup for BOX 2 (the load generator) in the 2-box (Track B)
# deployment. Idempotent. Run as root on a fresh Ubuntu 22.04/24.04 box.
#
#   sudo bash scripts/setup-loadgen.sh
#
# It builds the loadgen binary, tunes the box as a high-rate *connector*, and starts the loadgen
# HTTP API that box 1's harness drives. See docs/LOADGEN_REMOTE.md for the full tutorial.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
API_PORT="${LOADGEN_API_PORT:-8088}"
say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }; ok(){ printf '   \033[32m✓\033[0m %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

say "1. toolchain (gcc + make + python3)"
export DEBIAN_FRONTEND=noninteractive
command -v gcc >/dev/null && command -v make >/dev/null || { apt-get update -qq; apt-get install -y -qq build-essential python3 curl iproute2 procps >/dev/null; }
ok "$(gcc -dumpversion) / $(python3 --version)"

say "2. build loadgen"
make -C loadgen >/dev/null 2>&1 && ok "loadgen built" || { echo "build failed"; exit 1; }

say "3. connector tuning (box 2 opens millions of short-lived connections)"
cat > /etc/sysctl.d/99-acceptbench-loadgen.conf <<'EOF'
# box 2 is the *connector* — it runs out of ephemeral ports / TIME_WAIT before the SUT unless tuned
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=10
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
EOF
sysctl -p /etc/sysctl.d/99-acceptbench-loadgen.conf >/dev/null 2>&1 && ok "sysctls applied" || echo "   (sysctl apply failed)"
# conntrack fills at high conn churn — drop the module if present (matches production nodes)
modprobe -r nf_conntrack 2>/dev/null && ok "nf_conntrack removed" || true

say "4. start the loadgen API (systemd if available, else nohup)"
if command -v systemctl >/dev/null; then
  cat > /etc/systemd/system/acceptbench-loadgen.service <<EOF
[Unit]
Description=accept-bench loadgen API
After=network.target
[Service]
Environment=LOADGEN_API_PORT=$API_PORT
ExecStart=/usr/bin/python3 $REPO/loadgen/loadgen-server.py
LimitNOFILE=1048576
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now acceptbench-loadgen >/dev/null 2>&1
  ok "systemd service acceptbench-loadgen started"
else
  pkill -f 'loadgen-server.py' 2>/dev/null
  LOADGEN_API_PORT=$API_PORT setsid nohup python3 loadgen/loadgen-server.py >/var/log/acceptbench-loadgen.log 2>&1 < /dev/null &
  ok "loadgen API started (nohup; log /var/log/acceptbench-loadgen.log)"
fi

sleep 1
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
say "DONE — loadgen box ready"
curl -fsS "http://localhost:$API_PORT/health" >/dev/null 2>&1 && ok "API healthy on :$API_PORT" || echo "   (API health check failed — see logs)"
cat <<EOF
   This box's loadgen API:   http://${ip:-<box2-ip>}:$API_PORT
   On BOX 1, set in harness/config (or export before harness/run.sh):
     TARGET_HOST="<box-1 address reachable from box 2>"
     LOADGEN_URL="http://${ip:-<box2-ip>}:$API_PORT"
   Open firewalls: box2:$API_PORT must accept box1; box2 must reach box1:30 and box1:31.
   Verify from box 1:  curl -s http://${ip:-<box2-ip>}:$API_PORT/health
EOF
