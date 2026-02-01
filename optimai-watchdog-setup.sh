#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# OptimAI Watchdog Setup v3 (tmux send-keys based)
# - tmux session ALWAYS alive
# - start node via send-keys (no auto-exit)
# - child-process check
# - Telegram alert
# - restart rate-limit
# =========================================================

### -------- DEFAULT CONFIG --------
TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"
CLI_BIN="optimai-cli"

TG_BOT_TOKEN=""
TG_CHAT_ID=""

MAX_RESTARTS=3
WINDOW_SECONDS=600   # 10 minutes

WATCHDOG_PATH="/usr/local/bin/optimai-watchdog.sh"
SERVICE_PATH="/etc/systemd/system/optimai-watchdog.service"
TIMER_PATH="/etc/systemd/system/optimai-watchdog.timer"

STATE_DIR="/var/lib/optimai-watchdog"
WATCHDOG_LOG="/var/log/optimai-watchdog.log"
NODE_LOG="/var/log/optimai-node.log"

### -------- HELP --------
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
EOF
}

### -------- PRECHECK --------
must_be_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[!] Run as root"; exit 1; }
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
      *) echo "[!] Unknown arg: $1"; usage; exit 1 ;;
    esac
  done

  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]] || {
    echo "[!] Missing --token or --chat-id"; exit 1;
  }
}

ensure_deps() {
  command -v systemctl >/dev/null || { echo "[!] systemd required"; exit 1; }
  command -v tmux >/dev/null || { echo "[!] tmux required"; exit 1; }
  command -v curl >/dev/null || { echo "[!] curl required"; exit 1; }
  [[ -x "$CLI_PATH" ]] || { echo "[!] optimai-cli not found at $CLI_PATH"; exit 1; }
}

### -------- WRITE WATCHDOG --------
write_watchdog() {
echo "[*] Writing watchdog v3..."

mkdir -p "$STATE_DIR"
touch "$WATCHDOG_LOG" "$NODE_LOG"

cat > "$WATCHDOG_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

TMUX_SESSION="${TMUX_SESSION}"
CLI_PATH="${CLI_PATH}"
CLI_BIN="${CLI_BIN}"

TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

MAX_RESTARTS=${MAX_RESTARTS}
WINDOW_SECONDS=${WINDOW_SECONDS}

STATE_DIR="${STATE_DIR}"
STATE_FILE="\$STATE_DIR/restarts.log"
WATCHDOG_LOG="${WATCHDOG_LOG}"
NODE_LOG="${NODE_LOG}"

ts(){ date "+%Y-%m-%d %H:%M:%S"; }
now(){ date +%s; }

send_tg(){
  curl -s -X POST "https://api.telegram.org/bot\${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="\${TG_CHAT_ID}" \
    -d text="\$1" \
    -d disable_web_page_preview=true >/dev/null 2>&1 || true
}

log(){ echo "[\$(ts)] \$1" >> "\$WATCHDOG_LOG"; }

command -v tmux >/dev/null || exit 0
[[ -x "\$CLI_PATH" ]] || exit 0

mkdir -p "\$STATE_DIR"
touch "\$STATE_FILE"

cleanup(){
  local cutoff=\$((\$(now)-WINDOW_SECONDS))
  awk -v c="\$cutoff" '\$1>=c' "\$STATE_FILE" > "\$STATE_FILE.tmp" || true
  mv "\$STATE_FILE.tmp" "\$STATE_FILE"
}

can_restart(){
  cleanup
  [[ \$(wc -l < "\$STATE_FILE") -lt "\$MAX_RESTARTS" ]]
}

record_restart(){ echo "\$(now)" >> "\$STATE_FILE"; }

start_tmux(){
  log "Starting node via tmux send-keys"
  tmux kill-session -t "\$TMUX_SESSION" 2>/dev/null || true
  sleep 1
  tmux new-session -d -s "\$TMUX_SESSION"
  sleep 1
  tmux send-keys -t "\$TMUX_SESSION" \
    "exec \$CLI_PATH node start 2>&1 | tee -a \$NODE_LOG" C-m
}

restart_node(){
  if ! can_restart; then
    log "Restart blocked by rate limit"
    send_tg "🚨 OptimAI Watchdog BLOCKED

Server: \$(hostname)
Reason: restart limit exceeded
Action: manual check required"
    exit 0
  fi

  record_restart
  start_tmux

  send_tg "🔄 OptimAI Node Restarted

Server: \$(hostname)
Time: \$(ts)
Session: \$TMUX_SESSION"
}

# -------- CHECK TMUX --------
if ! tmux has-session -t "\$TMUX_SESSION" 2>/dev/null; then
  log "tmux session missing"
  restart_node
  exit 0
fi

# -------- CHECK PROCESS --------
FOUND=0
for p in \$(tmux list-panes -t "\$TMUX_SESSION" -F '#{pane_pid}'); do
  if pgrep -P "\$p" -fa "\$CLI_BIN.*node start" >/dev/null; then
    FOUND=1; break
  fi
done

[[ "\$FOUND" -eq 1 ]] && exit 0

log "tmux alive but node process missing"
restart_node
EOF

chmod +x "$WATCHDOG_PATH"
}

### -------- SYSTEMD --------
write_systemd() {
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=OptimAI Watchdog v3
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_PATH}
EOF

cat > "$TIMER_PATH" <<'EOF'
[Unit]
Description=Run OptimAI Watchdog every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=optimai-watchdog.service

[Install]
WantedBy=timers.target
EOF
}

enable_timer() {
  systemctl daemon-reload
  systemctl enable --now optimai-watchdog.timer
}

### -------- MAIN --------
main(){
  must_be_root
  parse_args "$@"
  ensure_deps
  write_watchdog
  write_systemd
  enable_timer

  echo "✅ OptimAI Watchdog v3 installed"
  echo "Logs:"
  echo "  Watchdog: $WATCHDOG_LOG"
  echo "  Node:     $NODE_LOG"
  echo "tmux:"
  echo "  tmux ls"
  echo "  tmux attach -t $TMUX_SESSION"
}

main "$@"
