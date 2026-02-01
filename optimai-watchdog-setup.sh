#!/usr/bin/env bash
set -euo pipefail

# ==============================
# OptimAI Watchdog Setup (tmux + process check)
# - Auto restart node if tmux session/process missing
# - Telegram alert on restart
# - Rate limit: max 3 restarts / 10 minutes
# ==============================

TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"

TG_BOT_TOKEN=""
TG_CHAT_ID=""

MAX_RESTARTS=3
WINDOW_SECONDS=600

WATCHDOG_PATH="/usr/local/bin/optimai-watchdog.sh"
SERVICE_PATH="/etc/systemd/system/optimai-watchdog.service"
TIMER_PATH="/etc/systemd/system/optimai-watchdog.timer"

usage() {
  cat <<'EOF'
Usage:
  sudo bash optimai-watchdog-setup.sh --token "<BOT_TOKEN>" --chat-id "<CHAT_ID>" [options]

Options:
  --token        Telegram bot token (required)
  --chat-id      Telegram chat id (required)
  --session      tmux session name (default: o)
  --cli          optimai-cli path (default: /usr/local/bin/optimai-cli)
  --max          max restarts per window (default: 3)
  --window       window seconds (default: 600)

Example:
  sudo bash optimai-watchdog-setup.sh --token "123:ABC" --chat-id "123456789"
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

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[!] systemctl not found. This setup requires systemd."
    exit 1
  fi
}

write_watchdog() {
  echo "[*] Writing watchdog to $WATCHDOG_PATH ..."

  # Note: avoid printing token/chat_id to stdout
  cat > "$WATCHDOG_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TMUX_SESSION="${TMUX_SESSION}"
CLI_PATH="${CLI_PATH}"
CLI_BIN="optimai-cli"

TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

MAX_RESTARTS=${MAX_RESTARTS}
WINDOW_SECONDS=${WINDOW_SECONDS}

STATE_DIR="/var/lib/optimai-watchdog"
STATE_FILE="\${STATE_DIR}/restarts.log"
LOG_FILE="/var/log/optimai-watchdog.log"

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

command -v tmux >/dev/null 2>&1 || exit 0
[[ -x "\$CLI_PATH" ]] || exit 0

mkdir -p "\$STATE_DIR"
touch "\$STATE_FILE"

cleanup_old_restarts() {
  local cutoff
  cutoff=\$(( \$(now) - WINDOW_SECONDS ))
  awk -v c="\$cutoff" '\$1 >= c' "\$STATE_FILE" > "\${STATE_FILE}.tmp" || true
  mv "\${STATE_FILE}.tmp" "\$STATE_FILE"
}

can_restart() {
  cleanup_old_restarts
  local count
  count=\$(wc -l < "\$STATE_FILE" || echo 0)
  [[ "\$count" -lt "\$MAX_RESTARTS" ]]
}

record_restart() {
  echo "\$(now)" >> "\$STATE_FILE"
}

restart_node() {
  if ! can_restart; then
    echo "[\$(ts)] Restart limit reached. Node will NOT be restarted." >> "\$LOG_FILE"
    send_tg "🚨 OptimAI Watchdog ALERT

Server: \$(hostname)
Status: Restart limit reached (>\${MAX_RESTARTS} restarts / 10 minutes)
Action: Node restart BLOCKED

👉 Please check logs manually."
    exit 0
  fi

  record_restart

  {
    echo "[\$(ts)] Restarting OptimAI node..."
    tmux kill-session -t "\$TMUX_SESSION" 2>/dev/null || true
    sleep 2
    tmux new-session -d -s "\$TMUX_SESSION" "\$CLI_PATH node start"
    echo "[\$(ts)] Node restarted in tmux session '\$TMUX_SESSION'."
  } >> "\$LOG_FILE" 2>&1

  send_tg "🔄 OptimAI Watchdog Restarted Node

Server: \$(hostname)
Time: \$(ts)
Reason: Node process/session missing

ℹ️ Restart count (last 10 min): \$(wc -l < "\$STATE_FILE")/\${MAX_RESTARTS}"
}

# 1) tmux session exists?
if ! tmux has-session -t "\$TMUX_SESSION" 2>/dev/null; then
  echo "[\$(ts)] tmux session '\$TMUX_SESSION' not found." >> "\$LOG_FILE"
  restart_node
  exit 0
fi

# 2) process inside tmux pane exists?
PANE_PIDS="\$(tmux list-panes -t "\$TMUX_SESSION" -F '#{pane_pid}')"
FOUND=0
for pid in \$PANE_PIDS; do
  if ps -eo pid,cmd | grep -E "^\s*\$pid\s" | grep -q "\$CLI_BIN node start"; then
    FOUND=1
    break
  fi
done

if [[ "\$FOUND" -eq 1 ]]; then
  exit 0
fi

echo "[\$(ts)] tmux session exists but optimai-cli process not found." >> "\$LOG_FILE"
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
  echo "Check timer:"
  echo "  systemctl status optimai-watchdog.timer --no-pager"
  echo
  echo "Watchdog log:"
  echo "  tail -n 100 /var/log/optimai-watchdog.log"
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
