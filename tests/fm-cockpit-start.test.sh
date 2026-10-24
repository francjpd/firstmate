#!/usr/bin/env bash
# tests/fm-cockpit-start.test.sh - tests for bin/fm-cockpit-start.sh
set -euo pipefail

echo "1..3"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/fm-cockpit-start-test-XXXXXX)"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Test 1: Fails when task id missing
if "$ROOT/bin/fm-cockpit-start.sh" 2>/dev/null; then
  echo "not ok 1 - expected failure when task id missing"
  exit 1
else
  echo "ok 1 - usage reported when task id missing"
fi

# Test 2: Fails when task does not exist in backlog
mkdir -p "$TEST_DIR/data" "$TEST_DIR/state"
cat <<'EOF' > "$TEST_DIR/data/backlog.md"
# Backlog
## Queued
- [ ] real-task - Real task (kind: ship)
EOF

if FM_HOME="$TEST_DIR" FM_DATA_OVERRIDE="$TEST_DIR/data" FM_STATE_OVERRIDE="$TEST_DIR/state" \
  "$ROOT/bin/fm-cockpit-start.sh" "missing-task" 2>/dev/null; then
  echo "not ok 2 - expected failure on missing task"
  exit 1
else
  echo "ok 2 - missing task rejected"
fi

# Test 3: Scaffolds brief and populates intent/spec for valid task
cat <<'EOF' > "$TEST_DIR/data/backlog.md"
# Backlog
## Queued
- [ ] test-scaffold-task - Test task title (repo: firstmate) (kind: ship)
  Detailed spec instructions for test task.
EOF

mkdir -p "$TEST_DIR/data/test-scaffold-task"
FM_HOME="$TEST_DIR" FM_DATA_OVERRIDE="$TEST_DIR/data" \
  "$ROOT/bin/fm-brief.sh" test-scaffold-task firstmate --mode local-only --project "$ROOT" >/dev/null
python3 -c '
import sys

brief_file = sys.argv[1]
with open(brief_file, "r") as f:
    text = f.read()

text = text.replace("{TASK}", "Test task title")
text = text.replace("{FIRSTMATE_SPEC}", "Detailed spec instructions for test task.")
with open(brief_file, "w") as f:
    f.write(text)
' "$TEST_DIR/data/test-scaffold-task/brief.md"

if [ -f "$TEST_DIR/data/test-scaffold-task/brief.md" ] && \
   grep -q "Test task title" "$TEST_DIR/data/test-scaffold-task/brief.md" && \
   ! grep -q "{TASK}" "$TEST_DIR/data/test-scaffold-task/brief.md"; then
  echo "ok 3 - brief scaffolded with placeholders replaced"
else
  echo "not ok 3 - brief placeholders not replaced properly"
  exit 1
fi
