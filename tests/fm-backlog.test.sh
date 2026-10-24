#!/usr/bin/env bash
# Tests for bin/fm-backlog.sh and backlog-axi integration
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKLOG_SH="$ROOT/bin/fm-backlog.sh"
TMP_DIR=$(fm_test_tmproot fm-backlog)

setup_test_backlog() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cat <<'EOF' > "$target"
# Test Backlog

## In flight
- [ ] task-doing - Active task (kind: ship)

## Queued
- [ ] task-todo - Queued task (kind: scout)
- [ ] task-blocked - Blocked task blocked-by: task-doing (kind: ship)

## Done
- [x] task-done - Finished work (kind: ship)
EOF
}

test_help() {
  local out
  out=$("$BACKLOG_SH" --help)
  assert_contains "$out" "Firstmate interactive backlog cockpit" "fm-backlog.sh help"
  assert_contains "$out" "bin/fm-backlog.sh summary" "fm-backlog.sh summary mentioned"
}

test_summary_mode() {
  local test_file="$TMP_DIR/data/backlog.md"
  setup_test_backlog "$test_file"

  local out
  out=$(TASKS_AXI_FILE="$test_file" "$BACKLOG_SH" summary)
  assert_contains "$out" "backlog-axi Summary Receipt" "receipt rendered"
  assert_contains "$out" "Total Tasks:" "task count present"
}

test_list_mode() {
  local test_file="$TMP_DIR/data/backlog.md"
  setup_test_backlog "$test_file"

  local out
  out=$(TASKS_AXI_FILE="$test_file" "$BACKLOG_SH" list)
  assert_contains "$out" "tasks[" "TOON tasks array"
  assert_contains "$out" "task-doing" "in flight task present"
  assert_contains "$out" "task-todo" "queued task present"
}

test_help
test_summary_mode
test_list_mode

echo "All fm-backlog.sh tests passed."
