#!/usr/bin/env bash
# Behavior tests for harness capacity admission: a harness that declares how
# many workers it admits at once on this machine never gets a fresh worker
# launched beyond that number (bin/fm-harness-capacity-lib.sh owns the
# contract; bin/fm-spawn.sh runs the check).
#
# Every case drives the real bin/fm-spawn.sh against a real project clone with
# an origin, fake tmux and treehouse binaries that log every call, and a real
# markdown backlog when tasks-axi is installed. A deferred spawn is judged by
# what it left behind - no task record, no rendered launch brief, no endpoint,
# no worktree allocation, and a backlog item still queued - never by wording
# alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-capacity)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run tests for $2.

## Firstmate spec
Exercise harness capacity admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

# A Firstmate home with its own backlog (when tasks-axi is installed) and a
# brief for every named task.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*)
    if [ -n "${FM_FAKE_HOLD:-}" ]; then
      : > "$FM_FAKE_HOLD.reached"
      i=0
      while [ ! -f "$FM_FAKE_HOLD.release" ]; do
        i=$((i + 1))
        [ "$i" -lt 400 ] || exit 1
        sleep 0.05
      done
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  *"#{pane_current_command}"*)
    printf 'bash\n'
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows)
    if [ -n "${FM_FAKE_WINDOWS:-}" ]; then
      printf '%s\n' "$FM_FAKE_WINDOWS"
    else
      printf 'firstmate\n'
    fi
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes codex agy
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  fm_git_init_commit "$case_dir/other-project"
  fm_git_add_origin "$case_dir/other-project" "$case_dir/other-project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

declare_capacity() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/harness-capacity"
}

write_live() {  # <home> <id> <project-dir> [harness] [extra-line...]
  local home=$1 id=$2 project=$3 harness=${4:-codex}
  if [ $# -ge 4 ]; then
    shift 4
  else
    shift 3
  fi
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/absent-worktree-$id" \
    "project=$project" \
    "harness=$harness" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-$id" \
    "$@"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    add_item "$home" "$id"
    tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  fi
}

new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <case-dir> <id> [pane-path] [harness]
  local case_dir=$1 id=$2 pane=${3:-} harness=${4:-codex}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" "$harness" --mode no-mistakes --yolo off
}

assert_nothing_created() {  # <case-dir> <home> <id> <calls-before> <worktrees-before>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 after
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }

# --- cases ------------------------------------------------------------------

test_undeclared_capacity_keeps_dispatch_uncapped() {
  local case_dir home out rc=0
  case_dir=$(make_case undeclared task-c)
  home="$case_dir/home"
  write_live "$home" live-a "$case_dir/project" codex
  write_live "$home" live-b "$case_dir/project" codex
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "an undeclared harness refused a spawn: $out"
  assert_contains "$out" "spawned task-c" "an undeclared harness did not launch the worker"
  assert_present "$home/state/task-c.meta" "an undeclared harness's spawn published no record"
  pass "a harness with no declared capacity keeps today's uncapped dispatch"
}

test_available_capacity_admits_the_worker() {
  local case_dir home out rc=0
  case_dir=$(make_case available task-c)
  home="$case_dir/home"
  declare_capacity "$home" "# limit codex concurrency" "codex 2" "agy 1"
  write_live "$home" live-a "$case_dir/project" codex
  out=$(spawn_ship "$case_dir" task-c "" codex) || rc=$?
  expect_code 0 "$rc" "a spawn with a free place was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn with a free place did not launch"
  assert_not_contains "$out" "deferred:" "a spawn with a free place reported a deferral"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" task-c)" = in_flight ] || fail "an admitted spawn did not move its item In flight"
  fi
  pass "a spawn is admitted while its harness still has a free place"
}

test_exhausted_capacity_defers_without_leaving_anything_behind() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case exhausted task-c)
  home="$case_dir/home"
  declare_capacity "$home" "codex 2"
  write_live "$home" live-a "$case_dir/project" codex
  write_live "$home" live-b "$case_dir/project" codex
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused" codex) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn beyond capacity was not deferred: $out"
  assert_contains "$out" "deferred: harness codex admits 2 worker(s) at once on this machine ($home/config/harness-capacity) and 2 already hold a place (live-a, live-b)" \
    "the deferral did not name the capacity and its holders"
  assert_contains "$out" "task task-c was not launched and its backlog item stays queued" \
    "the deferral did not say the task stays queued"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "a spawn beyond capacity is deferred before any record, brief, endpoint, worktree, or backlog move exists"
}

test_differing_harness_does_not_hold_a_place() {
  local case_dir home out rc=0
  case_dir=$(make_case differing task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" "codex 1"
  write_live "$home" live-agy "$case_dir/project" agy
  out=$(spawn_ship "$case_dir" task-c "" codex) || rc=$?
  expect_code 0 "$rc" "a record with a different harness took a place: $out"
  assert_contains "$out" "spawned task-c" "a free place was not admitted"
  rc=0
  out=$(spawn_ship "$case_dir" task-d "$case_dir/unused" codex) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "second worker was not deferred: $out"
  assert_contains "$out" "1 already hold a place (task-c)" "differing harness was counted as holder"
  assert_not_contains "$out" "live-agy" "agy worker was counted as codex holder"
  pass "a record whose harness differs does not hold a place"
}

test_relaunch_and_secondmate_are_exempt() {
  local case_dir home out rc=0
  case_dir=$(make_case exempt task-r task-blocked)
  home="$case_dir/home"
  declare_capacity "$home" "codex 1"
  write_live "$home" live-a "$case_dir/project" codex

  # Confirm ordinary spawn defers because capacity is 1 and live-a holds it
  out=$(spawn_ship "$case_dir" task-blocked "$case_dir/unused" codex) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "fresh spawn was not deferred: $out"

  # Secondmate spawn is exempt
  mkdir -p "$home/data/sm-exempt"
  printf 'You are a secondmate.\n' > "$home/data/sm-exempt/brief.md"
  rc=0
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" sm-exempt "$home" --secondmate --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -ne "$DEFER_EXIT" ] || fail "a secondmate was deferred by harness capacity: $out"
  assert_not_contains "$out" "deferred:" "a secondmate reported a deferral"

  # Relaunch is exempt
  write_live "$home" task-r "$case_dir/project" codex
  rc=0
  FM_FAKE_WINDOWS="fm-task-r" \
    out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-r --relaunch) || rc=$?
  [ "$rc" -ne "$DEFER_EXIT" ] || fail "a relaunch was deferred by harness capacity: $out"
  assert_not_contains "$out" "deferred:" "a relaunch reported a deferral"
  pass "a relaunch and a secondmate are exempt from harness capacity"
}

test_release_frees_a_place() {
  local case_dir home out rc=0
  case_dir=$(make_case release task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" "codex 2"
  write_live "$home" live-a "$case_dir/project" codex
  write_live "$home" live-b "$case_dir/project" codex
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused" codex) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the full harness admitted a worker: $out"

  # PR handoff: the line bin/fm-pr-check.sh records for a ready PR.
  printf 'pr=%s\n' "https://github.com/o/r/pull/7" >> "$home/state/live-a.meta"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "" codex) || rc=$?
  expect_code 0 "$rc" "a recorded PR handoff did not free a place: $out"
  rc=0
  out=$(spawn_ship "$case_dir" task-d "$case_dir/unused" codex) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "one freed place admitted two workers: $out"
  assert_contains "$out" "2 already hold a place (live-b, task-c)" "the new worker did not take the freed place"

  # Cleanup: teardown removes the record, which frees its place.
  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" live-b 2>&1) || rc=$?
  expect_code 0 "$rc" "cleanup of a live worker failed: $out"
  assert_absent "$home/state/live-b.meta" "cleanup left the worker's record"
  rc=0
  out=$(spawn_ship "$case_dir" task-d "" codex) || rc=$?
  expect_code 0 "$rc" "cleanup did not free a place: $out"
  pass "a recorded PR handoff or a cleanup each frees exactly one place"
}

test_capacity_is_shared_by_every_local_home() {
  local case_dir root mate out rc=0 mate_project
  case_dir=$(make_case machine)
  root="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate" task-m
  mate_project="$mate/projects/project"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$mate_project"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$root/data/secondmates.md"
  printf -- '- far - a remote mate (host: far.example; root: /srv/fm; home: %s/remote-home; scope: other; projects: project; added 2026-09-01)\n' "$case_dir" \
    >> "$root/data/secondmates.md"
  mkdir -p "$case_dir/remote-home/state"
  fm_write_meta "$case_dir/remote-home/state/far-x.meta" "window=w" "project=$case_dir/project" "harness=codex" "kind=ship"
  declare_capacity "$root" "codex 1"
  write_live "$root" live-a "$case_dir/project" codex
  git -C "$mate_project" worktree add --quiet -b wt-m "$case_dir/wt-m"
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" codex --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a local secondmate launched past the machine's harness capacity: $out"
  assert_contains "$out" "admits 1 worker(s) at once on this machine ($root/config/harness-capacity) and 1 already hold a place (live-a in $root)" \
    "the secondmate did not count the root home's worker against the root's declaration"
  assert_absent "$mate/state/task-m.meta" "the deferred secondmate spawn published a record"
  printf 'pr=%s\n' "https://github.com/o/r/pull/8" >> "$root/state/live-a.meta"
  rc=0
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" codex --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "the remote home's worker, or a handed-off one, took the machine's place: $out"
  pass "every local home shares one declared harness capacity, and remote homes do not count"
}

test_unreadable_declaration_refuses_every_spawn() {
  local case_dir home out rc label body before worktrees
  case_dir=$(make_case unreadable task-c)
  home="$case_dir/home"
  while IFS='|' read -r label body; do
    [ -n "$label" ] || continue
    printf '%b' "$body" > "$home/config/harness-capacity"
    before=$(call_count "$case_dir")
    worktrees=$(worktree_list "$case_dir")
    rc=0
    out=$(spawn_ship "$case_dir" task-c "$case_dir/unused" codex) || rc=$?
    expect_code 1 "$rc" "$label: an unreadable declaration did not refuse: $out"
    assert_contains "$out" "the harness capacity declaration is unreadable" "$label: the refusal did not name the declaration"
    assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  done <<'ROWS'
missing capacity|codex\n
zero capacity|codex 0\n
non-numeric capacity|codex two\n
unverified adapter|unknownharness 2\n
capacity longer than six digits|codex 1234567\n
trailing text|codex 2 # suite\n
named twice|codex 2\ncodex 3\n
ROWS
  rm -f "$home/config/harness-capacity"
  mkdir "$home/config/harness-capacity"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused" codex) || rc=$?
  expect_code 1 "$rc" "a declaration that is not a file did not refuse: $out"
  pass "an unreadable declaration refuses every fresh spawn rather than guessing the limit"
}

test_comments_and_whitespace_are_parsed() {
  local case_dir home out rc=0
  case_dir=$(make_case comments task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" \
    "# comment with number 5" \
    "#not-a-capacity" \
    "   # leading whitespace" \
    "   codex   1   "
  write_live "$home" live-a "$case_dir/project" codex
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused" codex) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "commented and spaced declaration was not enforced: $out"
  assert_contains "$out" "deferred: harness codex admits 1 worker(s) at once" \
    "deferral did not name the parsed capacity"
  pass "comments and whitespace in harness-capacity are handled correctly"
}

test_undeclared_capacity_keeps_dispatch_uncapped
test_available_capacity_admits_the_worker
test_exhausted_capacity_defers_without_leaving_anything_behind
test_differing_harness_does_not_hold_a_place
test_relaunch_and_secondmate_are_exempt
test_release_frees_a_place
test_capacity_is_shared_by_every_local_home
test_unreadable_declaration_refuses_every_spawn
test_comments_and_whitespace_are_parsed
