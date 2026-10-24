#!/usr/bin/env bash
# fm-deck-ingress.sh - centralized ingress processor and two-way reply router for deck-axi
#
# Listens to ~/.local/state/deck-axi/ingress.jsonl, tracks read offset via
# ~/.local/state/deck-axi/ingress.cursor, routes replies back to per-session
# chat files, updates message status badges (sent -> received -> answered),
# and performs bounded safe rotation.
#
# Usage:
#   fm-deck-ingress.sh poll [--limit <n>]
#   fm-deck-ingress.sh reply <chat-file> "<message>"
#   fm-deck-ingress.sh ack <chat-file> [message-id]
#   fm-deck-ingress.sh watch
#   fm-deck-ingress.sh status
#   fm-deck-ingress.sh rotate [--max-lines <n>]
#   fm-deck-ingress.sh path
set -euo pipefail

INGRESS_FILE="${DECK_INGRESS_FILE:-$HOME/.local/state/deck-axi/ingress.jsonl}"
CURSOR_FILE="${DECK_INGRESS_CURSOR:-$HOME/.local/state/deck-axi/ingress.cursor}"

ensure_dirs() {
  mkdir -p "$(dirname "$INGRESS_FILE")"
  mkdir -p "$(dirname "$CURSOR_FILE")"
  [ -f "$INGRESS_FILE" ] || touch "$INGRESS_FILE"
}

get_cursor() {
  if [ -f "$CURSOR_FILE" ]; then
    local val
    val=$(head -n 1 "$CURSOR_FILE" 2>/dev/null || echo "0")
    case "$val" in
      ''|*[!0-9]*) echo "0" ;;
      *) echo "$val" ;;
    esac
  else
    echo "0"
  fi
}

set_cursor() {
  local new_val="$1"
  printf '%s\n' "$new_val" > "$CURSOR_FILE"
}

cmd_path() {
  echo "$INGRESS_FILE"
}

cmd_status() {
  ensure_dirs
  local cursor total pending
  cursor=$(get_cursor)
  total=$(wc -l < "$INGRESS_FILE" | tr -d ' ')
  if [ "$total" -ge "$cursor" ]; then
    pending=$((total - cursor))
  else
    pending=0
  fi
  printf 'ingress: %s\n' "$INGRESS_FILE"
  printf 'cursor:  %s\n' "$cursor"
  printf 'total:   %s\n' "$total"
  printf 'pending: %s\n' "$pending"
}

update_message_status() {
  local chat_file="$1"
  local target_id="${2:-}"
  local new_status="${3:-received}"

  python3 -c '
import os, sys, json, tempfile
chat_file = sys.argv[1]
target_id = sys.argv[2]
new_status = sys.argv[3]

if not chat_file or not os.path.exists(chat_file):
    sys.exit(0)

lines = []
updated = False
with open(chat_file, "r", encoding="utf-8") as f:
    for line in f:
        line_str = line.strip()
        if not line_str:
            continue
        try:
            data = json.loads(line_str)
            if data.get("role") == "captain":
                if not target_id or data.get("id") == target_id:
                    if data.get("status") != new_status:
                        data["status"] = new_status
                        updated = True
            lines.append(json.dumps(data))
        except Exception:
            lines.append(line_str)

if updated:
    dir_name = os.path.dirname(chat_file)
    fd, tmp = tempfile.mkstemp(dir=dir_name if dir_name else None, prefix=".chat_tmp_")
    with open(fd, "w", encoding="utf-8") as f:
        for l in lines:
            f.write(l + "\n")
    os.replace(tmp, chat_file)
' "$chat_file" "$target_id" "$new_status"
}

cmd_poll() {
  ensure_dirs
  local limit=100
  if [ "${1:-}" = "--limit" ] && [ -n "${2:-}" ]; then
    limit="$2"
  fi

  local cursor total
  cursor=$(get_cursor)
  total=$(wc -l < "$INGRESS_FILE" | tr -d ' ')

  if [ "$cursor" -ge "$total" ]; then
    return 0
  fi

  local start_line=$((cursor + 1))
  local count=0
  local current_line=$cursor

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    current_line=$((current_line + 1))
    printf '%s\n' "$line"

    # Automatically mark message received in destination chat file
    python3 -c '
import sys, json, os, tempfile
try:
    payload = json.loads(sys.argv[1])
    chat_file = payload.get("chatFile")
    msg_id = payload.get("id")
    if chat_file and os.path.exists(chat_file):
        lines = []
        updated = False
        with open(chat_file, "r", encoding="utf-8") as f:
            for l in f:
                l_str = l.strip()
                if not l_str:
                    continue
                try:
                    d = json.loads(l_str)
                    if d.get("id") == msg_id and d.get("status") == "sent":
                        d["status"] = "received"
                        updated = True
                    lines.append(json.dumps(d))
                except Exception:
                    lines.append(l_str)
        if updated:
            dname = os.path.dirname(chat_file)
            fd, tmp = tempfile.mkstemp(dir=dname if dname else None, prefix=".chat_tmp_")
            with open(fd, "w", encoding="utf-8") as f:
                for l in lines:
                    f.write(l + "\n")
            os.replace(tmp, chat_file)
except Exception:
    pass
' "$line"

    count=$((count + 1))
    if [ "$count" -ge "$limit" ]; then
      break
    fi
  done < <(tail -n +"$start_line" "$INGRESS_FILE")

  set_cursor "$current_line"
}

cmd_ack() {
  local chat_file="${1:-}"
  local msg_id="${2:-}"

  if [ -z "$chat_file" ]; then
    echo "Usage: fm-deck-ingress.sh ack <chat-file> [message-id]" >&2
    exit 1
  fi
  update_message_status "$chat_file" "$msg_id" "received"
}

cmd_reply() {
  local chat_file="${1:-}"
  shift || true
  local text="$*"

  if [ -z "$chat_file" ] || [ -z "$text" ]; then
    echo "Usage: fm-deck-ingress.sh reply <chat-file> \"<message>\"" >&2
    exit 1
  fi

  local ts
  ts=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')
  local msg_id="m_${ts}"

  # Safely mark captain messages answered and append Firstmate response atomically
  python3 -c '
import os, sys, json, tempfile
chat_file = sys.argv[1]
msg_id = sys.argv[2]
text = sys.argv[3]
ts = int(sys.argv[4])

dir_name = os.path.dirname(chat_file)
if dir_name:
    os.makedirs(dir_name, exist_ok=True)

lines = []
if os.path.exists(chat_file):
    with open(chat_file, "r", encoding="utf-8") as f:
        for line in f:
            line_str = line.strip()
            if not line_str:
                continue
            try:
                data = json.loads(line_str)
                if data.get("role") == "captain" and data.get("status") in ("sent", "received", "seen"):
                    data["status"] = "answered"
                lines.append(json.dumps(data))
            except Exception:
                lines.append(line_str)

new_msg = {
    "id": msg_id,
    "role": "firstmate",
    "text": text,
    "ts": ts
}
lines.append(json.dumps(new_msg))

fd, tmp = tempfile.mkstemp(dir=dir_name if dir_name else None, prefix=".chat_tmp_")
with open(fd, "w", encoding="utf-8") as f:
    for l in lines:
        f.write(l + "\n")
os.replace(tmp, chat_file)
' "$chat_file" "$msg_id" "$text" "$ts"
}

cmd_wait() {
  ensure_dirs
  local timeout="${1:-}"

  local cursor total
  cursor=$(get_cursor)
  total=$(wc -l < "$INGRESS_FILE" | tr -d ' ')

  if [ "$total" -gt "$cursor" ]; then
    cmd_poll --limit 1
    return 0
  fi

  if command -v inotifywait >/dev/null 2>&1; then
    while [ "$total" -le "$cursor" ]; do
      if [ -n "$timeout" ]; then
        if ! inotifywait -t "$timeout" -q -e modify "$INGRESS_FILE" >/dev/null 2>&1; then
          return 0
        fi
      else
        inotifywait -q -e modify "$INGRESS_FILE" >/dev/null 2>&1 || true
      fi
      total=$(wc -l < "$INGRESS_FILE" | tr -d ' ')
    done
  else
    local elapsed=0
    while [ "$total" -le "$cursor" ]; do
      sleep 1
      elapsed=$((elapsed + 1))
      if [ -n "$timeout" ] && [ "$elapsed" -ge "$timeout" ]; then
        return 0
      fi
      total=$(wc -l < "$INGRESS_FILE" | tr -d ' ')
    done
  fi

  cmd_poll --limit 1
}

cmd_watch() {
  ensure_dirs
  echo "Watching $INGRESS_FILE for incoming deck messages..."
  # Drain pending initially
  cmd_poll || true

  if command -v inotifywait >/dev/null 2>&1; then
    while inotifywait -q -e modify "$INGRESS_FILE" >/dev/null 2>&1; do
      cmd_poll || true
    done
  else
    while true; do
      cmd_poll || true
      sleep 1
    done
  fi
}

cmd_rotate() {
  ensure_dirs
  local max_lines=1000
  if [ "${1:-}" = "--max-lines" ] && [ -n "${2:-}" ]; then
    max_lines="$2"
  fi

  local cursor total
  cursor=$(get_cursor)
  total=$(wc -l < "$INGRESS_FILE" | tr -d ' ')

  if [ "$total" -gt "$max_lines" ] && [ "$cursor" -gt 0 ]; then
    local archive="${INGRESS_FILE}.old"
    # Keep lines after cursor
    local remaining_lines=$((total - cursor))
    if [ "$remaining_lines" -gt 0 ]; then
      tail -n "$remaining_lines" "$INGRESS_FILE" > "${INGRESS_FILE}.tmp"
      mv "$INGRESS_FILE" "$archive"
      mv "${INGRESS_FILE}.tmp" "$INGRESS_FILE"
      set_cursor 0
      echo "Rotated $cursor processed lines to $archive. Remaining: $remaining_lines"
    else
      mv "$INGRESS_FILE" "$archive"
      touch "$INGRESS_FILE"
      set_cursor 0
      echo "Rotated all $cursor processed lines to $archive. File reset."
    fi
  else
    echo "Rotation not needed (total: $total, max: $max_lines, cursor: $cursor)"
  fi
}

case "${1:-}" in
  path) cmd_path ;;
  status) cmd_status ;;
  poll) shift; cmd_poll "$@" ;;
  ack) shift; cmd_ack "$@" ;;
  reply) shift; cmd_reply "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  watch) cmd_watch ;;
  rotate) shift; cmd_rotate "$@" ;;
  -h|--help)
    echo "Usage: fm-deck-ingress.sh {path|status|poll|ack|reply|watch|rotate}"
    exit 0
    ;;
  *)
    cmd_status
    ;;
esac
