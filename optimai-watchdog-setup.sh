#!/usr/bin/env bash
set -euo pipefail

# ===================== CONFIG =====================
TMUX_SESSION="o"
CLI_PATH="/usr/local/bin/optimai-cli"
CLI_BIN="optimai-cli"

# Telegram
TG_BOT_TOKEN="PUT_YOUR_BOT_TOKEN"
TG_CHAT_ID="PUT_YOUR_CHAT_ID"

# Restart limit
MAX_RESTARTS=3
WINDOW_SECONDS=600   # 10 phút

# Paths
STATE_DIR="/var/lib/optimai-watchdog"
STATE_FILE="${STATE_DIR}/restarts.log"
WATCHDOG_LOG="/var/log/optimai-watchdog.log"
NODE_LOG="/var/log/optimai-node.log"

# ===================== UTILS =====================
ts() { date "+%Y-%m-%d %H:%M:%S"; }
now() { date +%s; }

send_tg() {
  local msg="$1"
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    -d text="$msg" \
    -d disable_web_page_preview=true \
    >/dev/null 2>&1 || true
}

log() {
  echo "[$(ts)] $1" >> "$WATCHDOG_LOG"
}

# ===================== PRECHECK =====================
command -v tmux >/dev/null 2>&1 || exit 0
[[ -x "$CLI_PATH" ]] || exit 0

mkdir -p "$STATE_DIR"
touch "$STATE_FILE" "$WATCHDOG_LOG" "$NODE_LOG"

# ===================== RATE LIMIT =====================
cleanup_old_restarts() {
  local cutoff
  cutoff=$(( $(now) - WINDOW_SECONDS ))
  awk -v c="$cutoff" '$1 >= c' "$STATE_FILE" > "${STATE_FILE}.tmp" || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

can_restart() {
  cleanup_old_restarts
  local count
  count=$(wc -l < "$STATE_FILE" || echo 0)
  [[ "$count" -lt "$MAX_RESTARTS" ]]
}

record_restart() {
  echo "$(now)" >> "$STATE_FILE"
}

# ===================== NODE CONTROL =====================
start_node_tmux() {
  log "Starting OptimAI node in tmux session '$TMUX_SESSION'"

  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  sleep 2

  # QUAN TRỌNG: dùng bash -lc + tee để session KHÔNG chết
  tmux new-session -d -s "$TMUX_SESSION" \
    "bash -lc '$CLI_PATH node start 2>&1 | tee -a $NODE_LOG'"

  sleep 2
}

restart_node() {
  if ! can_restart; then
    log "Restart limit reached. Restart blocked."

    send_tg "🚨 OptimAI Watchdog ALERT

Server: $(hostname)
Status: Restart limit reached (>${MAX_RESTARTS} restarts / 10 minutes)
Action: Node restart BLOCKED

👉 Check node log: $NODE_LOG"
    exit 0
  fi

  record_restart
  start_node_tmux

  send_tg "🔄 OptimAI Node Restarted

Server: $(hostname)
Time: $(ts)
Reason: Node session/process missing

ℹ️ Restart count (10 min): $(wc -l < "$STATE_FILE")/${MAX_RESTARTS}"
}

# ===================== CHECK 1: TMUX SESSION =====================
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  log "tmux session '$TMUX_SESSION' not found"
  restart_node
  exit 0
fi

# ===================== CHECK 2: PROCESS INSIDE TMUX =====================
PANE_PIDS="$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_pid}')"
FOUND=0

for pane_pid in $PANE_PIDS; do
  # Check CHILD process của shell trong pane
  if pgrep -P "$pane_pid" -fa "$CLI_BIN.*node start" >/dev/null 2>&1; then
    FOUND=1
    break
  fi
done

if [[ "$FOUND" -eq 1 ]]; then
  # Node đang chạy bình thường
  exit 0
fi

# Session còn nhưng node chết
log "tmux session exists but optimai-cli process not found"
restart_node
