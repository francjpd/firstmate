#!/usr/bin/env bash
# tests/fm-deck-ingress.test.sh - tests for fm-deck-ingress.sh
set -euo pipefail

echo "1..14"

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

# Test 6: poll updates message status in chat file from sent to received
echo '{"id":"m_status_1","role":"captain","text":"status test","status":"sent"}' > "$TEST_CHAT_FILE"
echo "{\"id\":\"m_status_1\",\"chatFile\":\"$TEST_CHAT_FILE\",\"role\":\"captain\",\"text\":\"status test\"}" >> "$DECK_INGRESS_FILE"
"$ROOT/bin/fm-deck-ingress.sh" poll >/dev/null

if grep -q '"status": "received"' "$TEST_CHAT_FILE"; then
  echo "ok 6 - poll marks captain message status as received in chat file"
else
  echo "not ok 6 - chat file status not updated to received: $(cat "$TEST_CHAT_FILE")"
  exit 1
fi

# Test 7: reply updates captain messages to answered
"$ROOT/bin/fm-deck-ingress.sh" reply "$TEST_CHAT_FILE" "Acknowledged and resolved."
if grep -q '"status": "answered"' "$TEST_CHAT_FILE" && grep -q "Acknowledged and resolved." "$TEST_CHAT_FILE"; then
  echo "ok 7 - reply marks previous captain messages as answered"
else
  echo "not ok 7 - captain message not marked answered after reply: $(cat "$TEST_CHAT_FILE")"
  exit 1
fi

# Test 8: wait command consumes newly appended message
( sleep 0.3 && echo '{"id":"m_wait_1","chatFile":"'"$TEST_CHAT_FILE"'","role":"captain","text":"wait test","status":"sent"}' >> "$DECK_INGRESS_FILE" ) &
wait_out=$("$ROOT/bin/fm-deck-ingress.sh" wait 3)
if echo "$wait_out" | grep -q "wait test"; then
  echo "ok 8 - wait command successfully blocks and captures incoming message"
else
  echo "not ok 8 - wait command failed to capture message: $wait_out"
  exit 1
fi

# Test 9: poll updates message status in chat file when envelope uses snake_case chat_file
echo '{"id":"m_status_snake","role":"captain","text":"snake status test","status":"sent"}' > "$TEST_CHAT_FILE"
echo "{\"id\":\"m_status_snake\",\"chat_file\":\"$TEST_CHAT_FILE\",\"role\":\"captain\",\"text\":\"snake status test\"}" >> "$DECK_INGRESS_FILE"
"$ROOT/bin/fm-deck-ingress.sh" poll >/dev/null

if grep -q '"status": "received"' "$TEST_CHAT_FILE"; then
  echo "ok 9 - poll marks captain message status as received with snake_case chat_file"
else
  echo "not ok 9 - chat file status not updated with snake_case chat_file: $(cat "$TEST_CHAT_FILE")"
  exit 1
fi

# Test 10: fm-procevent-deck.sh classify handles null id and null mode gracefully
test_res_null="$TEST_DIR/null_event.json"
echo '{"id":null,"mode":null,"text":"plain message"}' > "$test_res_null"
classified=$("$ROOT/bin/fm-procevent-deck.sh" classify "$test_res_null")
if [ "$classified" = "message" ]; then
  echo "ok 10 - classify handles null id and null mode gracefully defaulting to message"
else
  echo "not ok 10 - classify returned unexpected: $classified"
  exit 1
fi

# Test 11: fm-procevent-deck.sh answers and read accept snake_case session_file and deck_id
test_session="$TEST_DIR/session.json"
echo '{"settled":[{"id":"q1","chosen":"optA","title":"Option A"}]}' > "$test_session"
test_submit="$TEST_DIR/submit_event.json"
echo "{\"id\":\"submit_1\",\"session_file\":\"$test_session\",\"deck_id\":\"deck_42\",\"mode\":\"submit\"}" > "$test_submit"

answers_out=$("$ROOT/bin/fm-procevent-deck.sh" answers "$test_submit")
read_out=$("$ROOT/bin/fm-procevent-deck.sh" read "$test_submit")
if echo "$answers_out" | grep -q "q1" && echo "$read_out" | grep -q "Deck ID:   deck_42"; then
  echo "ok 11 - answers and read accept snake_case session_file and deck_id"
else
  echo "not ok 11 - answers/read failed on snake_case keys: answers='$answers_out' read='$read_out'"
  exit 1
fi

# Test 12: fm-procevent-deck.sh autohandle returns 0 for relisten loop continuation
if "$ROOT/bin/fm-procevent-deck.sh" autohandle "deck-ingress" "1" "$test_submit"; then
  echo "ok 12 - autohandle returns 0 for continuous relisten"
else
  echo "not ok 12 - autohandle failed"
  exit 1
fi

# Test 13: fm-procevent-deck.sh classify identifies task_start events
test_task_start="$TEST_DIR/task_start.json"
echo '{"id":"task_start_123","action":"start","taskId":"my-cool-task","repo":"firstmate","kind":"ship","mode":"backlog"}' > "$test_task_start"
classified_start=$("$ROOT/bin/fm-procevent-deck.sh" classify "$test_task_start")
if [ "$classified_start" = "task_start" ]; then
  echo "ok 13 - classify identifies task_start events"
else
  echo "not ok 13 - classify returned unexpected for task start: $classified_start"
  exit 1
fi

# Test 14: fm-procevent-deck.sh read outputs structured Action and Task ID
read_task_out=$("$ROOT/bin/fm-procevent-deck.sh" read "$test_task_start")
if echo "$read_task_out" | grep -q "Action:    start" && echo "$read_task_out" | grep -q "Task ID:   my-cool-task"; then
  echo "ok 14 - read outputs structured Action and Task ID for task dispatch"
else
  echo "not ok 14 - read failed on task start event: '$read_task_out'"
  exit 1
fi
