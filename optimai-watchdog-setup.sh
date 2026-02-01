#!/usr/bin/env bash
set -euo pipefail

# ==============================
# OptimAI Watchdog Setup (PROD)
# - Watchdog: tmux + child-process check
# - Node log to /var/log/optimai-node.log
# - Telegram alert on restart
# - Rate limit: max 3 restarts / 10 minutes (configurable)
# - Installs systemd service + timer
# ==============================

# Defaults
TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"
CLI_BIN="optimai-cli"

TG_BOT_TOKEN=""
TG_CHAT_ID=""

MAX_RESTARTS=3
WINDOW_SECONDS=600

WATCHDOG_PATH="/usr/local/bin/optimai-watchdog.sh"
SERVICE_PATH="/etc/systemd/system/optimai-watchdog.service"
TIMER_PATH="/etc/systemd/system/optimai-watchdog.timer"

STATE_DIR="/var/lib/optimai-watchdog"
WATCHDOG_LOG="/var/log/optimai-watchdog.log"
NODE_LOG="/var/log/optimai-node.log"

usage() {
  cat <<'EOF'
Usage:
  sudo bash optimai-watchdog-setup.sh --token "<BOT_TOKEN>" --chat-id "<CHAT_ID>" [options]

Required:
  --token        Telegram bot token
  --chat-id      Telegram chat id

Optional:
  --session      tmux session name (default: o)
  --cli          optimai-cli path (default: /usr/local/bin/optimai-cli)
  --max          max restarts per window (default: 3)
  --window       window seconds (default: 600)

Example:
  sudo bash optimai-watchdog-setup.sh --token "123:ABC" --chat-id "123456789"

Notes:
- Requires: systemd, tmux, curl
- Logs:
  - Watchdog: /var/log/optimai-watchdog.log
  - Node:     /var/log/optimai-node.log
EOF
}

must_be_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "[!] Please run as root (sudo)."
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token) TG_BOT_TOKEN="${2:-}"; shift 2 ;;
      --chat-id) TG_CHAT_ID="${2:-}"; shift 2 ;;
      --session) TMUX_SESSION="${2:-}"; shift 2 ;;
      --cli) CLI_PATH="${2:-}"; shift 2 ;;
      --max) MAX_RESTARTS="${2:-}"; shift 2 ;;
      --window) WINDOW_SECONDS="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "[!] Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
    echo "[!] Missing --token or --chat-id"
    usage
    exit 1
  fi
}

ensure_deps() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[!] systemctl not found. This setup requires systemd."
    exit 1
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    echo "[!] tmux not found. Install it first (e.g. apt-get install -y tmux)."
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "[!] curl not found. Install it first (e.g. apt-get install -y curl)."
    exit 1
  fi

  if [[ ! -x "$CLI_PATH" ]]; then
    echo "[!] optimai-cli not found/executable at: $CLI_PATH"
    echo "    Fix path with: --cli /path/to/optimai-cli"
    exit 1
  fi
}

write_watchdog() {
  echo "[*] Writing watchdog to $WATCHDOG_PATH ..."

  mkdir -p "$STATE_DIR"
  touch "$WATCHDOG_LOG" "$NODE_LOG"

  # Write watchdog script (token/chat-id embedded for non-interactive cron/timer usage)
  cat > "$WATCHDOG_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG (generated) =====
TMUX_SESSION="${TMUX_SESSION}"
CLI_PATH="${CLI_PATH}"
CLI_BIN="${CLI_BIN}"

TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

MAX_RESTARTS=${MAX_RESTARTS}
WINDOW_SECONDS=${WINDOW_SECONDS}

STATE_DIR="${STATE_DIR}"
STATE_FILE="\${STATE_DIR}/restarts.log"
WATCHDOG_LOG="${WATCHDOG_LOG}"
NODE_LOG="${NODE_LOG}"

# ===== UTILS =====
ts() { date "+%Y-%m-%d %H:%M:%S"; }
now() { date +%s; }

send_tg() {
  local msg="\$1"
  curl -s -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" \\
    -d chat_id="\${TG_CHAT_ID}" \\
    -d text="\$msg" \\
    -d disable_web_page_preview=true \\
    >/dev/null 2>&1 || true
}

log() {
  echo "[\$(ts)] \$1" >> "\$WATCHDOG_LOG"
}

# ===== PRECHECK =====
command -v tmux >/dev/null 2>&1 || exit 0
[[ -x "\$CLI_PATH" ]] || exit 0

mkdir -p "\$STATE_DIR"
touch "\$STATE_FILE" "\$WATCHDOG_LOG" "\$NODE_LOG"

# ===== RATE LIMIT =====
cleanup_old_restarts() {
  local cutoff
  cutoff=\$(( \$(now) - WINDOW_SECONDS ))
  awk -v c="\$cutoff" '\$1 >= c' "\$STATE_FILE" > "\${STATE_FILE}.tmp" || true
  mv "\${STATE_FILE}.tmp" "\$STATE_FILE"
}

can_restart() {
  cleanup_old_restarts
  local count
  count=\$(wc -l < "\$STATE_FILE" 2>/dev/null || echo 0)
  [[ "\$count" -lt "\$MAX_RESTARTS" ]]
}

record_restart() {
  echo "\$(now)" >> "\$STATE_FILE"
}

# ===== NODE CONTROL =====
start_node_tmux() {
  log "Starting OptimAI node in tmux session '\$TMUX_SESSION'"

  tmux kill-session -t "\$TMUX_SESSION" 2>/dev/null || true
  sleep 2

  # Keep session alive + write node log for debugging
  tmux new-session -d -s "\$TMUX_SESSION" \\
    "bash -lc '\$CLI_PATH node start 2>&1 | tee -a \$NODE_LOG'"

  sleep 2
}

restart_node() {
  if ! can_restart; then
    log "Restart limit reached. Restart blocked."
    send_tg "🚨 OptimAI Watchdog ALERT

Server: \$(hostname)
Status: Restart limit reached (>\${MAX_RESTARTS} restarts / 10 minutes)
Action: Node restart BLOCKED

👉 Check node log: \$NODE_LOG"
    exit 0
  fi

  record_restart
  start_node_tmux

  send_tg "🔄 OptimAI Node Restarted

Server: \$(hostname)
Time: \$(ts)
Reason: Node session/process missing

ℹ️ Restart count (10 min): \$(wc -l < "\$STATE_FILE")/\${MAX_RESTARTS}"
}

# ===== CHECK 1: TMUX SESSION =====
if ! tmux has-session -t "\$TMUX_SESSION" 2>/dev/null; then
  log "tmux session '\$TMUX_SESSION' not found"
  restart_node
  exit 0
fi

# ===== CHECK 2: CHILD PROCESS INSIDE TMUX =====
PANE_PIDS="\$(tmux list-panes -t "\$TMUX_SESSION" -F '#{pane_pid}')"
FOUND=0

for pane_pid in \$PANE_PIDS; do
  # Pane PID is usually a shell; optimai-cli is a child process -> check children
  if pgrep -P "\$pane_pid" -fa "\$CLI_BIN.*node start" >/dev/null 2>&1; then
    FOUND=1
    break
  fi
done

if [[ "\$FOUND" -eq 1 ]]; then
  exit 0
fi

log "tmux session exists but optimai-cli process not found"
restart_node
EOF

  chmod +x "$WATCHDOG_PATH"
}

write_systemd() {
  echo "[*] Writing systemd service to $SERVICE_PATH ..."
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=OptimAI tmux watchdog (restart node if tmux/process missing)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_PATH}
EOF

  echo "[*] Writing systemd timer to $TIMER_PATH ..."
  cat > "$TIMER_PATH" <<'EOF'
[Unit]
Description=Run OptimAI watchdog every 1 minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=optimai-watchdog.service

[Install]
WantedBy=timers.target
EOF
}

enable_timer() {
  echo "[*] Enabling timer..."
  systemctl daemon-reload
  systemctl enable --now optimai-watchdog.timer
}

show_status() {
  echo
  echo "✅ Setup done."
  echo "Watchdog script : $WATCHDOG_PATH"
  echo "Service         : $SERVICE_PATH"
  echo "Timer           : $TIMER_PATH"
  echo
  echo "Status:"
  echo "  systemctl status optimai-watchdog.timer --no-pager"
  echo "  systemctl status optimai-watchdog.service --no-pager"
  echo
  echo "Logs:"
  echo "  tail -n 100 $WATCHDOG_LOG"
  echo "  tail -n 100 $NODE_LOG"
  echo
  echo "tmux:"
  echo "  tmux ls"
  echo "  tmux attach -t $TMUX_SESSION"
  echo
}

main() {
  must_be_root
  parse_args "$@"
  ensure_deps
  write_watchdog
  write_systemd
  enable_timer
  show_status
}

main "$@"
