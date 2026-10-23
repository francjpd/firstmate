#!/usr/bin/env bash
# fm-deck-ingress.sh - centralized ingress processor and two-way reply router for deck-axi
#
# Listens to ~/.local/state/deck-axi/ingress.jsonl, tracks read offset via
# ~/.local/state/deck-axi/ingress.cursor, routes replies back to per-session
# chat files, and performs bounded safe rotation.
#
# Usage:
#   fm-deck-ingress.sh poll [--limit <n>]
#   fm-deck-ingress.sh reply <chat-file> "<message>"
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
    count=$((count + 1))
    if [ "$count" -ge "$limit" ]; then
      break
    fi
  done < <(tail -n +"$start_line" "$INGRESS_FILE")

  set_cursor "$current_line"
}

cmd_reply() {
  local chat_file="${1:-}"
  shift || true
  local text="$*"

  if [ -z "$chat_file" ] || [ -z "$text" ]; then
    echo "Usage: fm-deck-ingress.sh reply <chat-file> \"<message>\"" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$chat_file")"
  local ts
  ts=$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')
  local msg_id="m_${ts}"

  # Format JSON line safely using python3
  python3 -c '
import sys, json
msg = {
  "id": sys.argv[1],
  "role": "firstmate",
  "text": sys.argv[2],
  "ts": int(sys.argv[3])
}
with open(sys.argv[4], "a", encoding="utf-8") as f:
  f.write(json.dumps(msg) + "\n")
' "$msg_id" "$text" "$ts" "$chat_file"
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
  reply) shift; cmd_reply "$@" ;;
  rotate) shift; cmd_rotate "$@" ;;
  -h|--help)
    echo "Usage: fm-deck-ingress.sh {path|status|poll|reply|rotate}"
    exit 0
    ;;
  *)
    cmd_status
    ;;
esac
