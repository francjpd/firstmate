#!/usr/bin/env bash
# fm-provider.sh - Provider telemetry & fleet worker routing cockpit launcher for Firstmate
#
# Launches deck-axi in provider mode within Herdr/tmux/zellij modal zoom,
# displaying active quota telemetry on the left and the interactive fleet
# role assignment matrix on the right.
#
# Usage:
#   bin/fm-provider.sh [options]
#   bin/fm-provider.sh telemetry
#   bin/fm-provider.sh assignments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"

case "${1:-}" in
  telemetry|quota)
    QUOTA_BIN="quota-axi"
    if [ -x "$HOME/.local/bin/quota-axi" ]; then
      QUOTA_BIN="$HOME/.local/bin/quota-axi"
    fi
    exec "$QUOTA_BIN" --provider agy,agy2
    ;;
  assignments)
    exec cat "$FM_HOME/config/crew-dispatch.json" 2>/dev/null || echo "No dispatch config"
    ;;
  -h|--help)
    cat <<'EOF'
fm-provider.sh - Firstmate provider telemetry & fleet routing cockpit

Usage:
  bin/fm-provider.sh [options]
  bin/fm-provider.sh telemetry
  bin/fm-provider.sh assignments

Options:
  --sidecar     Split side-by-side rather than full-screen modal zoom
  --standalone  Run in-place without multiplexer pane split
  -h, --help    Show this help
EOF
    exit 0
    ;;
  *)
    if [ -x "$SCRIPT_DIR/fm-deck.sh" ]; then
      exec "$SCRIPT_DIR/fm-deck.sh" provider "$@"
    else
      exec deck-axi provider "$@"
    fi
    ;;
esac
