#!/usr/bin/env bash
# tests/fm-deck.test.sh - TAP tests for bin/fm-deck.sh multiplexer-aware launcher
set -euo pipefail

echo "1..8"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/fm-deck.sh"

MOCK_DIR="$(mktemp -d /tmp/fm-deck-mock-XXXXXX)"
cleanup() {
  rm -rf "$MOCK_DIR"
}
trap cleanup EXIT

# Create mock binaries so tests are hermetic
touch "$MOCK_DIR/herdr" "$MOCK_DIR/tmux" "$MOCK_DIR/zellij"
chmod +x "$MOCK_DIR/herdr" "$MOCK_DIR/tmux" "$MOCK_DIR/zellij"
export PATH="$MOCK_DIR:$PATH"

# Test 1: detect reports herdr when HERDR_ENV is set
res_herdr=$(HERDR_ENV=1 HERDR_PANE_ID=w1:p1 TMUX="" ZELLIJ="" "$BIN" detect)
if [ "$res_herdr" = "herdr" ]; then
  echo "ok 1 - detect identifies herdr multiplexer"
else
  echo "not ok 1 - expected herdr, got: $res_herdr"
  exit 1
fi

# Test 2: detect reports tmux when TMUX is set and herdr unset
res_tmux=$(HERDR_ENV="" HERDR_PANE_ID="" TMUX="/tmp/tmux-1000/default,1234,0" ZELLIJ="" "$BIN" detect)
if [ "$res_tmux" = "tmux" ]; then
  echo "ok 2 - detect identifies tmux multiplexer"
else
  echo "not ok 2 - expected tmux, got: $res_tmux"
  exit 1
fi

# Test 3: detect reports zellij when ZELLIJ is set and others unset
res_zellij=$(HERDR_ENV="" HERDR_PANE_ID="" TMUX="" ZELLIJ=1 "$BIN" detect)
if [ "$res_zellij" = "zellij" ]; then
  echo "ok 3 - detect identifies zellij multiplexer"
else
  echo "not ok 3 - expected zellij, got: $res_zellij"
  exit 1
fi

# Test 4: detect reports standalone when no multiplexer env is present
res_standalone=$(HERDR_ENV="" HERDR_PANE_ID="" TMUX="" ZELLIJ="" "$BIN" detect)
if [ "$res_standalone" = "standalone" ]; then
  echo "ok 4 - detect identifies standalone environment"
else
  echo "not ok 4 - expected standalone, got: $res_standalone"
  exit 1
fi

# Test 5: --dry-run prints expected resolution plan
dry_out=$("$BIN" --dry-run bearings)
if echo "$dry_out" | grep -q "args: bearings" && echo "$dry_out" | grep -q "direction: right"; then
  echo "ok 5 - --dry-run resolves bearings mode and right split"
else
  echo "not ok 5 - unexpected dry-run output: $dry_out"
  exit 1
fi

# Test 6: --standalone flag forces standalone even in herdr
dry_standalone=$(HERDR_ENV=1 HERDR_PANE_ID=w1:p1 "$BIN" --standalone --dry-run grill data/test.json)
if echo "$dry_standalone" | grep -q "multiplexer: standalone" && echo "$dry_standalone" | grep -q "args: grill data/test.json"; then
  echo "ok 6 - --standalone overrides detected multiplexer"
else
  echo "not ok 6 - unexpected dry standalone output: $dry_standalone"
  exit 1
fi

# Test 7: modal zoom is enabled by default in dry-run
dry_modal=$("$BIN" --dry-run bearings)
if echo "$dry_modal" | grep -q "modal: 1"; then
  echo "ok 7 - modal zoom enabled by default"
else
  echo "not ok 7 - expected modal: 1, got: $dry_modal"
  exit 1
fi

# Test 8: --sidecar disables modal zoom
dry_sidecar=$("$BIN" --sidecar --dry-run bearings)
if echo "$dry_sidecar" | grep -q "modal: 0"; then
  echo "ok 8 - --sidecar disables modal zoom"
else
  echo "not ok 8 - expected modal: 0, got: $dry_sidecar"
  exit 1
fi
