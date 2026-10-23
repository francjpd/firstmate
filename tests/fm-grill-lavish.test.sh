#!/usr/bin/env bash
# tests/fm-grill-lavish.test.sh - tests for Grill Me + Lavish and deck-axi integration
set -euo pipefail

echo "1..4"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SLUG="test-grill-run-$$"
STATE_FILE="$ROOT/data/grill/$TEST_SLUG.json"
HTML_FILE="$ROOT/.lavish/grill-$TEST_SLUG.html"

cleanup() {
  rm -f "$STATE_FILE" "$HTML_FILE"
}
trap cleanup EXIT

# Test 1: init creates session and HTML
"$ROOT/bin/fm-grill.sh" init "$TEST_SLUG" "Test Decision Tree" >/dev/null 2>&1
if [ -f "$STATE_FILE" ] && [ -f "$HTML_FILE" ]; then
  echo "ok 1 - fm-grill.sh init created state and HTML files"
else
  echo "not ok 1 - fm-grill.sh init failed"
  exit 1
fi

# Test 2: HTML contains focus-aware polling script and Mermaid container
if grep -q "visibilitychange" "$HTML_FILE" && grep -q "mermaid" "$HTML_FILE" && grep -q "Accept All Recommended" "$HTML_FILE"; then
  echo "ok 2 - HTML contains focus-aware polling, Mermaid whiteboard, and quick action controls"
else
  echo "not ok 2 - HTML missing focus-aware polling or Mermaid whiteboard"
  exit 1
fi

# Test 3: deck-axi executes on session JSON
RECEIPT=$(deck-axi "$STATE_FILE" --non-interactive)
if echo "$RECEIPT" | grep -q "Summary Receipt: $TEST_SLUG"; then
  echo "ok 3 - deck-axi successfully runs against state file and emits summary receipt"
else
  echo "not ok 3 - deck-axi failed to run against state file"
  exit 1
fi

# Test 4: render updates HTML with settled nodes and updated round
cat <<EOF > "$STATE_FILE"
{
  "slug": "$TEST_SLUG",
  "title": "Test Decision Tree",
  "round": 2,
  "status": "active",
  "nodes": [
    { "id": "root", "title": "Architecture Root", "state": "settled", "chosenOutcome": "Option A" },
    { "id": "q2", "title": "Second Decision", "parentId": "root", "state": "frontier" }
  ],
  "frontier": [
    {
      "id": "Q2",
      "title": "Second Decision",
      "body": "Body text for second decision",
      "options": [
        { "key": "1", "label": "Choice 1", "recommended": true },
        { "key": "2", "label": "Choice 2", "recommended": false }
      ]
    }
  ],
  "settled": [
    { "id": "root", "title": "Architecture Root", "chosen": "Option A" }
  ]
}
EOF

"$ROOT/bin/fm-grill.sh" render "$TEST_SLUG" >/dev/null 2>&1
if grep -q "Round 2" "$HTML_FILE" && grep -q "Architecture Root" "$HTML_FILE" && grep -q "Option A" "$HTML_FILE"; then
  echo "ok 4 - fm-grill.sh render updated HTML with Round 2 and settled nodes"
else
  echo "not ok 4 - fm-grill.sh render failed to reflect Round 2"
  exit 1
fi
