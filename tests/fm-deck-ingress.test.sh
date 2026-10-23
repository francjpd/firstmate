#!/usr/bin/env bash
# tests/fm-deck-ingress.test.sh - tests for fm-deck-ingress.sh
set -euo pipefail

echo "1..5"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/fm-ingress-test-XXXXXX)"
export DECK_INGRESS_FILE="$TEST_DIR/ingress.jsonl"
export DECK_INGRESS_CURSOR="$TEST_DIR/ingress.cursor"
TEST_CHAT_FILE="$TEST_DIR/session.chat.jsonl"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Test 1: status reports 0 pending
status_out=$("$ROOT/bin/fm-deck-ingress.sh" status)
if echo "$status_out" | grep -q "pending: 0"; then
  echo "ok 1 - status reports initial 0 pending count"
else
  echo "not ok 1 - initial status unexpected: $status_out"
  exit 1
fi

# Test 2: append 2 messages, poll consumes them and updates cursor
echo '{"id":"m1","sessionSlug":"bearings","text":"hello 1","role":"captain"}' >> "$DECK_INGRESS_FILE"
echo '{"id":"m2","sessionSlug":"grill-foo","text":"hello 2","role":"captain"}' >> "$DECK_INGRESS_FILE"

polled=$("$ROOT/bin/fm-deck-ingress.sh" poll)
lines_polled=$(echo "$polled" | wc -l | tr -d ' ')

if [ "$lines_polled" -eq 2 ] && [ "$(cat "$DECK_INGRESS_CURSOR")" -eq 2 ]; then
  echo "ok 2 - poll reads all pending messages and advances cursor"
else
  echo "not ok 2 - poll failed to read messages (lines: $lines_polled)"
  exit 1
fi

# Test 3: subsequent poll returns nothing
polled_again=$("$ROOT/bin/fm-deck-ingress.sh" poll)
if [ -z "$polled_again" ]; then
  echo "ok 3 - subsequent poll yields zero messages when cursor is up to date"
else
  echo "not ok 3 - poll returned unexpected data: $polled_again"
  exit 1
fi

# Test 4: reply writes valid formatted JSON line to destination chat file
"$ROOT/bin/fm-deck-ingress.sh" reply "$TEST_CHAT_FILE" "Aye captain, message received."
if [ -f "$TEST_CHAT_FILE" ] && grep -q "Aye captain, message received." "$TEST_CHAT_FILE"; then
  echo "ok 4 - reply successfully appended valid chat message"
else
  echo "not ok 4 - reply failed to write to chat file"
  exit 1
fi

# Test 5: rotate archives processed lines and resets cursor safely
echo '{"id":"m3","sessionSlug":"bearings","text":"hello 3","role":"captain"}' >> "$DECK_INGRESS_FILE"
rotate_out=$("$ROOT/bin/fm-deck-ingress.sh" rotate --max-lines 1)
if [ -f "${DECK_INGRESS_FILE}.old" ] && grep -q "hello 3" "$DECK_INGRESS_FILE"; then
  echo "ok 5 - rotate preserved unread entries while archiving processed lines"
else
  echo "not ok 5 - rotate failed: $rotate_out"
  exit 1
fi
