#!/usr/bin/env bash
# Tests for bin/fm-provider.sh and deck-axi provider integration
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROVIDER_SH="$ROOT/bin/fm-provider.sh"

test_help() {
  local out
  out=$("$PROVIDER_SH" --help)
  assert_contains "$out" "Firstmate provider telemetry & fleet routing cockpit" "fm-provider.sh help"
  assert_contains "$out" "bin/fm-provider.sh assignments" "fm-provider.sh assignments mentioned"
}

test_assignments_mode() {
  local out
  out=$("$PROVIDER_SH" assignments)
  assert_contains "$out" "rules" "dispatch rules present"
  assert_contains "$out" "harness" "harness present"
}

test_dry_run_launch() {
  local out
  out=$("$ROOT/bin/fm-deck.sh" --dry-run provider)
  assert_contains "$out" "args: provider" "provider mode resolved in dry-run"
}

test_help
test_assignments_mode
test_dry_run_launch

echo "All fm-provider.sh tests passed."
