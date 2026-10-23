#!/usr/bin/env bash
# bin/fm-deck.sh - multiplexer-aware launcher for deck-axi deliberation cockpit
#
# Detects the active terminal multiplexer (herdr, tmux, zellij) and splits a
# neighboring pane to run deck-axi within the captain's existing terminal window.
# Falls back to standalone terminal emulators only when no multiplexer is present.
#
# Usage:
#   bin/fm-deck.sh [options] [deck-axi args...]
#   bin/fm-deck.sh detect
#
# Options:
#   --direction <right|down>  Split direction (default: right)
#   --standalone              Force standalone execution, bypassing multiplexer
#   --dry-run                 Print resolved command and multiplexer without launching
#   -h, --help                Show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

detect_multiplexer() {
  if { [ -n "${HERDR_PANE_ID:-}" ] || [ -n "${HERDR_ENV:-}" ]; } && command -v herdr >/dev/null 2>&1; then
    echo "herdr"
  elif [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    echo "tmux"
  elif [ -n "${ZELLIJ:-}" ] && command -v zellij >/dev/null 2>&1; then
    echo "zellij"
  else
    echo "standalone"
  fi
}

cmd_detect() {
  detect_multiplexer
}

show_help() {
  cat <<'EOF'
fm-deck.sh - multiplexer-aware launcher for deck-axi

Usage:
  bin/fm-deck.sh [options] [args...]
  bin/fm-deck.sh detect

Options:
  --direction <right|down>  Split direction (default: right)
  --standalone              Force standalone execution, bypassing multiplexer
  --dry-run                 Print resolved execution plan without running
  -h, --help                Show this help

Multiplexer priority:
  1. herdr  (splits active tab right/down and focuses)
  2. tmux   (tmux split-window -h / -v)
  3. zellij (zellij action new-pane)
  4. standalone fallback (in-place TTY or GUI terminal emulator)
EOF
}

DIRECTION="right"
FORCE_STANDALONE=0
DRY_RUN=0
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    detect)
      cmd_detect
      exit 0
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    --direction)
      if [ $# -lt 2 ]; then
        echo "Error: --direction requires 'right' or 'down'" >&2
        exit 1
      fi
      DIRECTION="$2"
      shift 2
      ;;
    --standalone)
      FORCE_STANDALONE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        ARGS+=("$1")
        shift
      done
      break
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [ ${#ARGS[@]} -eq 0 ]; then
  ARGS=("bearings")
fi

MUX="standalone"
if [ "$FORCE_STANDALONE" -eq 0 ]; then
  MUX="$(detect_multiplexer)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "multiplexer: $MUX"
  echo "direction: $DIRECTION"
  echo "args: ${ARGS[*]}"
  exit 0
fi

case "$MUX" in
  herdr)
    TARGET_PANE="${HERDR_PANE_ID:-}"
    SPLIT_CMD=(herdr pane split --direction "$DIRECTION" --focus)
    if [ -n "$TARGET_PANE" ]; then
      SPLIT_CMD+=(--pane "$TARGET_PANE")
    fi

    SPLIT_JSON="$("${SPLIT_CMD[@]}")"
    NEW_PANE=$(printf '%s\n' "$SPLIT_JSON" | grep -o '"pane_id":"[^"]*"' | head -n1 | cut -d'"' -f4)
    if [ -z "$NEW_PANE" ]; then
      echo "Failed to split Herdr pane: $SPLIT_JSON" >&2
      exit 1
    fi

    herdr pane run "$NEW_PANE" deck-axi "${ARGS[@]}"
    echo "Launched deck-axi in Herdr pane $NEW_PANE"
    ;;

  tmux)
    TMUX_FLAG="-h"
    if [ "$DIRECTION" = "down" ]; then
      TMUX_FLAG="-v"
    fi
    tmux split-window "$TMUX_FLAG" deck-axi "${ARGS[@]}"
    echo "Launched deck-axi in tmux pane (split $DIRECTION)"
    ;;

  zellij)
    zellij action new-pane --direction "$DIRECTION" -- deck-axi "${ARGS[@]}"
    echo "Launched deck-axi in zellij pane (split $DIRECTION)"
    ;;

  standalone)
    if [ -t 0 ] && [ -t 1 ]; then
      exec deck-axi "${ARGS[@]}"
    else
      TERMINAL_BIN=""
      for candidate in "${TERMINAL:-}" foot wezterm alacritty kitty xterm; do
        if [ -n "$candidate" ] && command -v "$candidate" >/dev/null 2>&1; then
          TERMINAL_BIN="$candidate"
          break
        fi
      done

      if [ -n "$TERMINAL_BIN" ]; then
        "$TERMINAL_BIN" -e deck-axi "${ARGS[@]}" &
        echo "Launched deck-axi in standalone terminal ($TERMINAL_BIN)"
      else
        echo "No terminal emulator found. Running deck-axi directly in background." >&2
        deck-axi "${ARGS[@]}" &
      fi
    fi
    ;;
esac
