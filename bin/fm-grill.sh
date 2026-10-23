#!/usr/bin/env bash
# fm-grill.sh - CLI wrapper for Grill Me + Lavish integration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-grill.js" "$@"
