#!/usr/bin/env bash
# Deck-axi process-event adapter for Firstmate.
#
# Usage:
#   fm-procevent-deck.sh arm [--timeout <secs>]
#   fm-procevent-deck.sh poll [--timeout <secs>]
#   fm-procevent-deck.sh classify <result-file>
#   fm-procevent-deck.sh terminal <result-file>
#   fm-procevent-deck.sh silent <result-file>
#   fm-procevent-deck.sh relisten [result-file]
#   fm-procevent-deck.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-deck.sh answers <result-file>
#   fm-procevent-deck.sh read <result-file>
#   fm-procevent-deck.sh source-id
#   fm-procevent-deck.sh retire
#
# arm        Register the deck-ingress source with bin/fm-procevent.sh and
#            ensure it is listening. Wakes Firstmate immediately whenever an
#            action, vote, message, or decision is submitted in deck-axi.
# poll       The blocking listener command executed by the generic runner;
#            never run this directly in a conversational turn. Blocks on
#            bin/fm-deck-ingress.sh wait until a line arrives or timeout occurs.
# classify   Print the captured event classification: message, submit, task_action, assign, or empty.
# terminal   Exit 1 always: deck-axi ingress is persistent and stays armed.
# silent     Exit 0 when captured output is empty (idle timeout), exit 1 when content present.
# relisten   Exit 0 always: runner maintains continuous listening.
# autohandle Exit 0 always: acknowledge capture for relisten loop continuation.
# answers    Extract structured captain decision key/value if result is a grill round submission.
# read       Print human-readable structured presentation of captured result line.
# source-id  Print the canonical source id: deck-ingress.
# retire     Retire the deck-ingress source from bin/fm-procevent.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

CANONICAL_SOURCE_ID="deck-ingress"

cmd_source_id() {
  printf '%s\n' "$CANONICAL_SOURCE_ID"
}

cmd_classify() {
  local file=${1-}
  [ -n "$file" ] || { echo "Usage: fm-procevent-deck.sh classify <result-file>" >&2; exit 2; }
  [ -f "$file" ] || exit 1
  [ -s "$file" ] || { printf 'empty\n'; return 0; }

  python3 -c '
import sys, json
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        line = f.readline().strip()
        if not line:
            print("empty")
            sys.exit(0)
        data = json.loads(line)
        msg_id = str(data.get("id") or data.get("msg_id") or "")
        mode = str(data.get("mode") or "")
        if msg_id.startswith("submit_"):
            print("submit")
        elif msg_id.startswith("task_"):
            print("task_action")
        elif msg_id.startswith("assign_"):
            print("assign")
        elif mode:
            print(mode)
        else:
            print("message")
except Exception:
    print("unknown")
' "$file"
}

cmd_terminal() {
  # Deck ingress is a persistent event stream; never terminal on ordinary captures
  return 1
}

cmd_silent() {
  local file=${1-}
  [ -n "$file" ] || return 0
  [ -f "$file" ] || return 0
  # If file is empty (e.g. idle timeout with no new ingress lines), be silent
  if [ ! -s "$file" ]; then
    return 0
  fi
  # File has content; publish wake
  return 1
}

cmd_relisten() {
  # Always relisten to keep background watcher armed
  return 0
}

cmd_autohandle() {
  return 0
}

cmd_answers() {
  local file=${1-}
  [ -n "$file" ] && [ -f "$file" ] || exit 1

  python3 -c '
import sys, json, os
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        line = f.readline().strip()
        if not line:
            sys.exit(1)
        data = json.loads(line)
        session_file = data.get("sessionFile") or data.get("session_file")
        if session_file and os.path.exists(session_file):
            with open(session_file, "r", encoding="utf-8") as sf:
                sdata = json.load(sf)
                for item in sdata.get("settled", []):
                    k = item.get("id")
                    ans = item.get("chosen", "")
                    lbl = item.get("title", "")
                    if k and ans:
                        print(f"{k}\t{ans}\t{lbl}")
except Exception:
    pass
' "$file" 2>/dev/null || exit 1
}

cmd_read() {
  local file=${1-}
  [ -n "$file" ] || { echo "Usage: fm-procevent-deck.sh read <result-file>" >&2; exit 2; }
  [ -f "$file" ] || exit 1

  python3 -c '
import sys, json
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.loads(f.readline().strip())
    msg_id = data.get("id") or data.get("msg_id") or "-"
    mode = data.get("mode") or "-"
    role = data.get("role") or "-"
    round_num = data.get("round") if data.get("round") is not None else "-"
    deck_id = data.get("deckId") or data.get("deck_id") or "-"
    text = data.get("text") if data.get("text") is not None else "-"
    ts = data.get("ts") if data.get("ts") is not None else "-"
    print("--- DECK INGRESS EVENT ---")
    print("ID:        " + str(msg_id))
    print("Mode:      " + str(mode))
    print("Role:      " + str(role))
    print("Round:     " + str(round_num))
    print("Deck ID:   " + str(deck_id))
    print("Text:      " + str(text))
    print("Timestamp: " + str(ts))
    print("--------------------------")
except Exception:
    with open(path, "r", encoding="utf-8") as f:
        print("Raw: " + f.read())
' "$file"
}

cmd_poll() {
  local timeout=30
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Run deck ingress wait
  exec "$SCRIPT_DIR/fm-deck-ingress.sh" wait "$timeout"
}

cmd_arm() {
  local timeout=30
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  "$SCRIPT_DIR/fm-procevent.sh" register deck "$CANONICAL_SOURCE_ID" \
    -- "$SCRIPT_DIR/fm-procevent-deck.sh" poll --timeout "$timeout"

  "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$CANONICAL_SOURCE_ID"
}

cmd_retire() {
  "$SCRIPT_DIR/fm-procevent.sh" retire "$CANONICAL_SOURCE_ID"
}

case "${1-}" in
  source-id)   cmd_source_id ;;
  classify)    shift; cmd_classify "$@" ;;
  terminal)    shift; cmd_terminal "$@" ;;
  silent)      shift; cmd_silent "$@" ;;
  relisten)    shift; cmd_relisten "$@" ;;
  autohandle)  shift; cmd_autohandle "$@" ;;
  answers)     shift; cmd_answers "$@" ;;
  read)        shift; cmd_read "$@" ;;
  poll)        shift; cmd_poll "$@" ;;
  arm)         shift; cmd_arm "$@" ;;
  retire)      shift; cmd_retire "$@" ;;
  *)
    printf 'Usage: fm-procevent-deck.sh {arm|poll|classify|terminal|silent|relisten|autohandle|answers|read|source-id|retire}\n' >&2
    exit 2
    ;;
esac
