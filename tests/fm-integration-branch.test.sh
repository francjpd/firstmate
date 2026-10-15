#!/usr/bin/env bash
# Regression tests for a home-declared integration branch.
#
# A home may keep its own work on a local integration branch while the repo's
# default branch stays a pristine mirror of upstream. `config/integration-branch`
# declares that branch, and four places must honour it: the primary-checkout
# tangle guard, the local landing target, the base a fresh spawn starts from,
# and the self-update path (bin/fm-update.sh).
# These tests cover the shared resolution and prove the spawn base end to end.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-integration-branch)

# A scratch repo with a default branch, an upstream remote, and an optional
# local-only integration branch. Echoes "<repo>|<origin>|<default-tip>|<integ-tip>".
make_repo() {
  local name=$1 integration=${2:-} dir origin
  dir="$TMP_ROOT/$name/repo"
  origin="$TMP_ROOT/$name/origin.git"
  mkdir -p "$TMP_ROOT/$name"
  git init --quiet -b main "$dir"
  printf 'base\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$origin"
  git -C "$dir" remote add origin "file://$origin"
  git -C "$dir" fetch --quiet origin
  local default_tip integ_tip
  default_tip=$(git -C "$dir" rev-parse HEAD)
  integ_tip=
  if [ -n "$integration" ]; then
    git -C "$dir" checkout --quiet -b "$integration"
    printf 'own work\n' > "$dir/own.txt"
    git -C "$dir" add own.txt
    git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'own work'
    integ_tip=$(git -C "$dir" rev-parse HEAD)
    git -C "$dir" checkout --quiet main
  fi
  printf '%s|%s|%s|%s\n' "$dir" "$origin" "$default_tip" "$integ_tip"
}

# Resolve the shared helpers against one scratch repo and print four answers.
resolve_all() { # <repo> <config-dir>
  local repo=$1 config_dir=$2
  bash -c '
    set -u
    . "$1/bin/fm-tangle-lib.sh"
    printf "default=%s\n" "$(fm_default_branch "$2")"
    printf "integration=%s\n" "$(fm_integration_branch "$2" "$3" || echo -)"
    printf "local-only=%s\n" "$(fm_local_integration_branch "$2" "$3" || echo -)"
    printf "tangle=%s\n" "$(fm_primary_tangle_branch "$2" "$3" || echo -)"
  ' _ "$ROOT" "$repo" "$config_dir"
}

test_absent_declaration_changes_nothing() {
  local rec repo config_dir out
  rec=$(make_repo absent)
  IFS='|' read -r repo _ _ _ <<EOF
$rec
EOF
  config_dir="$TMP_ROOT/absent/config"
  mkdir -p "$config_dir"
  out=$(resolve_all "$repo" "$config_dir")
  assert_contains "$out" "default=main" "the default branch should resolve to main"
  assert_contains "$out" "integration=main" \
    "an undeclared home must keep resolving its integration branch to the default"
  assert_contains "$out" "local-only=-" \
    "no declared local-only branch should be reported"
  assert_contains "$out" "tangle=-" \
    "a primary on its default branch must not be reported as tangled"
  pass "an absent integration-branch declaration changes nothing"
}

test_declared_branch_is_the_expected_branch() {
  local rec repo config_dir out
  rec=$(make_repo declared own)
  IFS='|' read -r repo _ _ integ_tip <<EOF
$rec
EOF
  config_dir="$TMP_ROOT/declared/config"
  mkdir -p "$config_dir"
  printf 'own\n' > "$config_dir/integration-branch"
  git -C "$repo" checkout --quiet own
  out=$(resolve_all "$repo" "$config_dir")
  assert_contains "$out" "integration=own" \
    "a declared integration branch must win over the default branch"
  assert_contains "$out" "local-only=own" \
    "a declared branch absent from origin must resolve as local-only"
  assert_contains "$out" "tangle=-" \
    "a primary on the declared integration branch must not be reported as tangled"
  assert_equals "$integ_tip" "$(git -C "$repo" rev-parse own)" \
    "the scratch integration branch should sit on its own commit"
  pass "a declared integration branch is the branch the primary is expected on"
}

test_unknown_declaration_falls_back() {
  local rec repo config_dir out
  rec=$(make_repo unknown)
  IFS='|' read -r repo _ _ _ <<EOF
$rec
EOF
  config_dir="$TMP_ROOT/unknown/config"
  mkdir -p "$config_dir"
  printf 'not-a-branch\n' > "$config_dir/integration-branch"
  out=$(resolve_all "$repo" "$config_dir")
  assert_contains "$out" "integration=main" \
    "a declaration naming no local branch must fall back to the default branch"
  assert_contains "$out" "local-only=-" \
    "a declaration naming no local branch must not resolve as local-only"
  assert_contains "$out" "tangle=-" \
    "an unusable declaration must not make a healthy primary look tangled"
  pass "an unusable integration-branch declaration falls back to the default"
}

test_other_feature_branch_still_alarms() {
  local rec repo config_dir out
  rec=$(make_repo other own)
  IFS='|' read -r repo _ _ _ <<EOF
$rec
EOF
  config_dir="$TMP_ROOT/other/config"
  mkdir -p "$config_dir"
  printf 'own\n' > "$config_dir/integration-branch"
  git -C "$repo" checkout --quiet -b fm/stray-feature
  out=$(resolve_all "$repo" "$config_dir")
  assert_contains "$out" "tangle=fm/stray-feature" \
    "the guard must still report a primary stranded on some other feature branch"
  pass "a primary on an unrelated feature branch still trips the tangle guard"
}

test_pushed_declaration_is_not_local_only() {
  local rec repo origin config_dir out
  rec=$(make_repo pushed own)
  IFS='|' read -r repo origin _ _ <<EOF
$rec
EOF
  git -C "$repo" push --quiet origin own
  git -C "$repo" fetch --quiet origin
  config_dir="$TMP_ROOT/pushed/config"
  mkdir -p "$config_dir"
  printf 'own\n' > "$config_dir/integration-branch"
  out=$(resolve_all "$repo" "$config_dir")
  assert_contains "$out" "integration=own" \
    "a declared branch is still the expected branch when origin also has it"
  assert_contains "$out" "local-only=-" \
    "a branch origin also carries is not local-only and must not take the local spawn path"
  pass "a declared branch that origin also carries is not treated as local-only"
}

test_spawn_base_is_the_local_integration_branch() {
  local case_dir home project origin pool fakebin id out status expected actual
  id='integration-base-r1'
  case_dir="$TMP_ROOT/spawn"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  local rec
  rec=$(make_repo spawncase own)
  IFS='|' read -r project origin _ expected <<EOF
$rec
EOF
  pool="$case_dir/pool"
  git -C "$project" worktree add --quiet --detach "$pool" "$(git -C "$project" rev-parse main)"
  printf 'own\n' > "$home/config/integration-branch"

  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --scout)
  status=$?
  expect_code 0 "$status" \
    "a home with a local integration branch should still spawn"$'\n'"$out"
  actual=$(git -C "$pool" rev-parse HEAD)
  assert_equals "$expected" "$actual" \
    "the fresh spawn must start from the local integration branch tip, not origin/main"
  assert_equals "$(git -C "$project" rev-parse main)" "$(git -C "$project" rev-parse refs/remotes/origin/main)" \
    "the scratch default branch should still match origin, so the assertion is meaningful"
  pass "a fresh spawn starts from the home's local integration branch"
}

test_absent_declaration_spawns_from_origin() {
  local case_dir home project origin pool fakebin id out status expected actual
  id='integration-base-absent-r1'
  case_dir="$TMP_ROOT/spawn-absent"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  local rec publisher
  rec=$(make_repo spawnabsent own)
  IFS='|' read -r project origin _ _ <<EOF
$rec
EOF
  pool="$case_dir/pool"
  git -C "$project" worktree add --quiet --detach "$pool" "$(git -C "$project" rev-parse main)"

  publisher="$case_dir/publisher"
  git clone --quiet "file://$origin" "$publisher"
  printf 'advanced\n' > "$publisher/advanced.txt"
  git -C "$publisher" add advanced.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance
  git -C "$publisher" push --quiet origin main
  expected=$(git -C "$publisher" rev-parse HEAD)

  out=$(fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --scout)
  status=$?
  expect_code 0 "$status" \
    "a home with no integration-branch declaration should still spawn"$'\n'"$out"
  actual=$(git -C "$pool" rev-parse HEAD)
  assert_equals "$expected" "$actual" \
    "without a declaration the spawn base must stay the fetched origin tip"
  pass "without a declaration a fresh spawn still starts from origin"
}

test_absent_declaration_changes_nothing
test_declared_branch_is_the_expected_branch
test_unknown_declaration_falls_back
test_other_feature_branch_still_alarms
test_pushed_declaration_is_not_local_only
test_spawn_base_is_the_local_integration_branch
test_absent_declaration_spawns_from_origin
