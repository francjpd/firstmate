#!/usr/bin/env bash
# fm-backlog.sh - Interactive task & backlog visual cockpit launcher for Firstmate
#
# Launches backlog-axi in Herdr/tmux/zellij modal zoom, connecting Firstmate's
# data/backlog.md to deck-axi's 4-column responsive Kanban cockpit.
#
# Usage:
#   bin/fm-backlog.sh [options] [backlog-path]
#   bin/fm-backlog.sh summary
#   bin/fm-backlog.sh list
#   bin/fm-backlog.sh ready
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG_FILE="${TASKS_AXI_FILE:-$DATA_DIR/backlog.md}"

case "${1:-}" in
  summary)
    exec backlog-axi --non-interactive "$BACKLOG_FILE"
    ;;
  list)
    exec backlog-axi --toon "$BACKLOG_FILE"
    ;;
  ready)
    exec "$SCRIPT_DIR/fm-tasks-axi.sh" ready
    ;;
  -h|--help)
    cat <<'EOF'
fm-backlog.sh - Firstmate interactive backlog cockpit

Usage:
  bin/fm-backlog.sh [options] [backlog-file]
  bin/fm-backlog.sh summary
  bin/fm-backlog.sh list
  bin/fm-backlog.sh ready

Options:
  --sidecar     Split side-by-side rather than full-screen modal zoom
  --standalone  Run in-place without multiplexer pane split
  -h, --help    Show this help
EOF
    exit 0
    ;;
  *)
    # Default: launch interactive cockpit through fm-deck.sh
    if [ -x "$SCRIPT_DIR/fm-deck.sh" ]; then
      exec "$SCRIPT_DIR/fm-deck.sh" backlog "$BACKLOG_FILE" "$@"
    else
      exec backlog-axi "$BACKLOG_FILE" "$@"
    fi
    ;;
esac
