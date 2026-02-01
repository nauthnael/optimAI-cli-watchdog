#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# OptimAI Watchdog Setup v4 (screen based)
# - Start node in screen session "o"
# - Log node to /var/log/optimai-node.log
# - Telegram alert on restart
# - Rate limit restarts
# - systemd timer runs every minute
# =========================================================

# Defaults
SESSION_NAME="o"
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
  --session      screen session name (default: o)
  --cli          optimai-cli path (default: /usr/local/bin/optimai-cli)
  --max          max restarts per window (default: 3)
  --window       window seconds (default: 600)

Example:
  sudo bash optimai-watchdog-setup.sh --token "123:ABC" --chat-id "123456789"
EOF
}

must_be_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "[!] Run as root (sudo)."; exit 1; }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token) TG_BOT_TOKEN="${2:-}"; shift 2 ;;
      --chat-id) TG_CHAT_ID="${2:-}"; shift 2 ;;
      --session) SESSION_NAME="${2:-}"; shift 2 ;;
      --cli) CLI_PATH="${2:-}"; shift 2 ;;
      --max) MAX_RESTARTS="${2:-}"; shift 2 ;;
      --window) WINDOW_SECONDS="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "[!] Unknown arg: $1"; usage; exit 1 ;;
    esac
  done

  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]] || { echo "[!] Missing --token or --chat-id"; usage; exit 1; }
}

ensure_deps() {
  command -v systemctl >/dev/null || { echo "[!] systemd required"; exit 1; }
  command -v curl >/dev/null || { echo "[!] curl required"; exit 1; }
  command -v screen >/dev/null || { echo "[!] screen required. Install: apt-get install -y screen"; exit 1; }
  [[ -x "$CLI_PATH" ]] || { echo "[!] optimai-cli not found at $CLI_PATH"; exit 1; }
}

write_watchdog() {
  echo "[*] Writing watchdog v4 (screen)..."
  mkdir -p "$STATE_DIR"
  touch "$WATCHDOG_LOG" "$NODE_LOG"

  cat > "$WATCHDOG_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SESSION_NAME="${SESSION_NAME}"
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

command -v screen >/dev/null 2>&1 || exit 0
[[ -x "\$CLI_PATH" ]] || exit 0

mkdir -p "\$STATE_DIR"
touch "\$STATE_FILE" "\$WATCHDOG_LOG" "\$NODE_LOG"

cleanup(){
  local cutoff=\$((\$(now)-WINDOW_SECONDS))
  awk -v c="\$cutoff" '\$1>=c' "\$STATE_FILE" > "\$STATE_FILE.tmp" || true
  mv "\$STATE_FILE.tmp" "\$STATE_FILE"
}

can_restart(){
  cleanup
  [[ \$(wc -l < "\$STATE_FILE" 2>/dev/null || echo 0) -lt "\$MAX_RESTARTS" ]]
}

record_restart(){ echo "\$(now)" >> "\$STATE_FILE"; }

screen_exists(){
  screen -ls | grep -q "[.]\\\${SESSION_NAME}[[:space:]]"
}

start_screen(){
  log "Starting node in screen '\$SESSION_NAME'..."
  # kill old session if exists
  if screen_exists; then
    screen -S "\$SESSION_NAME" -X quit || true
    sleep 1
  fi

  # start detached screen session with bash -lc + log
  # NOTE: if node exits, session ends (expected). log will contain the reason.
  screen -dmS "\$SESSION_NAME" bash -lc "\$CLI_PATH node start 2>&1 | tee -a '\$NODE_LOG'"
  sleep 2
}

restart_node(){
  if ! can_restart; then
    log "Restart blocked by rate limit"
    send_tg "🚨 OptimAI Watchdog BLOCKED

Server: \$(hostname)
Reason: restart limit exceeded
Action: manual check required

Tip: tail -n 50 \$NODE_LOG"
    exit 0
  fi

  record_restart
  start_screen

  send_tg "🔄 OptimAI Node Restarted (screen)

Server: \$(hostname)
Time: \$(ts)
Session: \$SESSION_NAME"
}

# -------- CHECK 1: screen session exists? --------
if ! screen_exists; then
  log "screen session '\$SESSION_NAME' not found"
  restart_node
  exit 0
fi

# -------- CHECK 2: optimai process exists? --------
# If screen exists but process died, we restart.
if ! pgrep -fa "\$CLI_BIN.*node start" >/dev/null 2>&1; then
  log "screen alive but node process missing"
  restart_node
  exit 0
fi

exit 0
EOF

  chmod +x "$WATCHDOG_PATH"
}

write_systemd() {
  echo "[*] Writing systemd service + timer..."
  cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=OptimAI Watchdog v4 (screen)
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

main() {
  must_be_root
  parse_args "$@"
  ensure_deps
  write_watchdog
  write_systemd
  enable_timer

  echo "✅ OptimAI Watchdog v4 (screen) installed"
  echo
  echo "Check:"
  echo "  systemctl status optimai-watchdog.timer --no-pager"
  echo "Logs:"
  echo "  tail -n 100 $WATCHDOG_LOG"
  echo "  tail -n 100 $NODE_LOG"
  echo
  echo "Screen:"
  echo "  screen -ls"
  echo "  screen -r $SESSION_NAME"
  echo "Detach screen: Ctrl+a then d"
}

main "$@"
