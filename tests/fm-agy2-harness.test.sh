#!/usr/bin/env bash
# Behavior tests for the agy2 (second Antigravity identity) crewmate/scout adapter.
#
# The facts pinned here are the ones a wrong guess would make dangerous:
#   1. agy2 is the same `agy` binary, so the live process name cannot tell the
#      two identities apart. Detection is therefore the Firstmate-owned launch
#      marker FM_AGY2_HARNESS=agy2 in the pi-signed shape: the marker names the
#      identity, ancestry still proves the family, and a marker that leaked into
#      a different harness must never rename it.
#   2. Every control-plane, busy-state, and delivery table that is keyed by `agy`
#      must apply to agy2 unchanged, without a second copy of any table.
#   3. The wrapper refuses a caller-supplied --gemini_dir, and refuses to launch
#      while its store holds no distinct identity, so a spawn cannot stand up a
#      pane that parks on an interactive login.
#   4. Trust for an agy2 worker must land in agy2's own settings store; writing
#      the fleet's store would both leave the dialog in place and touch the
#      first identity's file.
#   5. The store isolation itself is real: the private Secret Service on the
#      wrapper's bus cannot see the fleet's antigravity slot, and a private slot
#      holding the fleet account is refused before any TUI starts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry, and a suite run
# from inside another harness inherits those markers, which would outrank the
# fake ancestry each detection case sets up.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS FM_AGY2_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TRUST="$ROOT/bin/fm-agy-trust.sh"
LAUNCHER="$ROOT/bin/fm-agy2.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy2-harness)
TEST_HOME="$TMP_ROOT/home"
mkdir -p "$TEST_HOME"

# A stub `agy` on PATH so the launcher's binary resolution is satisfied on a host
# with no Antigravity CLI; every case below either refuses before agy would run
# or never reaches it. The launcher refuses a `agy` that is itself the wrapper,
# so the stub is a plain script rather than a symlink to bin/fm-agy2.sh.
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/agy" <<'SH'
#!/usr/bin/env bash
printf 'stub-agy\n'
SH
chmod +x "$STUB_BIN/agy"

launcher() {  # <root> <real-bus> <args...>
  local root=$1 bus=$2
  shift 2
  HOME="$TEST_HOME" PATH="$STUB_BIN:$PATH" FM_AGY2_ROOT="$root" FM_AGY2_REAL_BUS="$bus" \
    "$LAUNCHER" "$@"
}

# A stand-in bus plus keyring, so a case can present a KNOWN "fleet" identity
# instead of the developer's real keyring. Prints the bus address.
start_private_bus() {  # <dir>
  local dir=$1
  mkdir -p "$dir/data" "$dir/run" "$dir/control"
  chmod 700 "$dir/control"
  dbus-daemon --session --fork --address="unix:path=$dir/bus" \
    --print-address=1 --print-pid=1 > "$dir/bus.out" 2>/dev/null || return 1
  tail -n 1 "$dir/bus.out" > "$dir/bus.pid"
  printf 'test-pass' |
    DBUS_SESSION_BUS_ADDRESS="unix:path=$dir/bus" XDG_DATA_HOME="$dir/data" \
      GNOME_KEYRING_CONTROL="$dir/control" \
      gnome-keyring-daemon --unlock --components=secrets \
      --control-directory="$dir/control" --daemonize >/dev/null 2>&1
  local _
  for _ in $(seq 1 50); do
    dbus-send --bus="unix:path=$dir/bus" --print-reply --reply-timeout=2000 \
      --dest=org.freedesktop.DBus /org/freedesktop/DBus \
      org.freedesktop.DBus.GetNameOwner string:org.freedesktop.secrets >/dev/null 2>&1 &&
      break
    sleep 0.1
  done
  printf 'unix:path=%s/bus\n' "$dir"
}

stop_private_bus() {  # <dir>
  local dir=$1 owner pid
  owner=$(dbus-send --bus="unix:path=$dir/bus" --print-reply --reply-timeout=2000 \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.GetNameOwner string:org.freedesktop.secrets 2>/dev/null |
    sed -n 's/.*string "\(.*\)"/\1/p')
  if [ -n "$owner" ]; then
    pid=$(dbus-send --bus="unix:path=$dir/bus" --print-reply --reply-timeout=2000 \
      --dest=org.freedesktop.DBus /org/freedesktop/DBus \
      org.freedesktop.DBus.GetConnectionUnixProcessID "string:$owner" 2>/dev/null |
      sed -n 's/.*uint32 \([0-9]*\)/\1/p')
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  fi
  [ ! -s "$dir/bus.pid" ] || kill "$(cat "$dir/bus.pid")" 2>/dev/null || true
}

store_token() {  # <bus> <email-json>
  printf '%s' "$2" |
    DBUS_SESSION_BUS_ADDRESS="$1" secret-tool store --label=probe \
      service gemini username antigravity 2>/dev/null
}

# shellcheck disable=SC2317  # reached from the EXIT trap installed by tests/lib.sh
cleanup_agy2_buses() {
  local dir
  for dir in "$TMP_ROOT"/fleet-bus "$TMP_ROOT"/root-live; do
    [ -d "$dir" ] && stop_private_bus "$dir"
  done
}
trap 'cleanup_agy2_buses' EXIT

fake_agy_ancestry() {  # <dir> <comm>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"comm="*) printf '%s\n' '$2'; exit 0 ;;
  *"args="*) printf '%s\n' '$2 --prompt-interactive hi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_detection_marker_names_the_second_identity() {
  local fakebin out
  fakebin=$(fake_agy_ancestry "$TMP_ROOT/anc-agy2" /usr/local/bin/agy)
  out=$(FM_AGY2_HARNESS=agy2 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = agy2 ] \
    || fail "the agy2 launch marker over a real agy ancestor must detect agy2, got '$out'"

  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = agy ] \
    || fail "an agy ancestor with no agy2 marker must stay agy, got '$out'"
  pass "fm-harness.sh: the marker names agy2 and an unmarked agy stays agy"
}

test_detection_marker_never_renames_another_harness() {
  local fakebin out
  fakebin=$(fake_agy_ancestry "$TMP_ROOT/anc-leak" /usr/local/bin/claude)
  out=$(FM_AGY2_HARNESS=agy2 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = claude ] \
    || fail "a leaked agy2 marker must never rename a claude session, got '$out'"
  pass "fm-harness.sh: a leaked agy2 marker never renames another harness"
}

test_control_plane_folds_agy2_onto_agy() {
  # The tables below are keyed by FAMILY, and bin/fm-control.sh folds the
  # recorded harness through fm_control_harness_family before it reads them, so
  # the contract this pins is: the fold resolves agy2 to agy, and the agy tables
  # then drive it unchanged. A raw recorded value still has to pass the
  # capability table, which is why agy2 is listed there itself.
  local family
  assert_equals agy "$(fm_control_harness_family agy2)" "agy2 must fold onto the agy control family"
  fm_control_harness_supported agy2 || fail "agy2 must be a supported control harness"
  family=$(fm_control_harness_family agy2)
  assert_equals Escape "$(fm_control_interrupt_key "$family")" "agy2 must interrupt like agy"
  assert_equals 1 "$(fm_control_interrupt_repeat "$family")" "agy2 must interrupt once like agy"
  assert_equals /quit "$(fm_control_exit_command "$family")" "agy2 must exit like agy"
  assert_equals key "$(fm_control_interrupt_transport "$family")" "agy2 must interrupt through the keyplane"
  fm_control_harness_supports_kind agy2 secondmate ||
    fail "agy2 must support secondmate"
  fm_control_harness_supports_kind agy secondmate ||
    fail "agy must support secondmate"
  pass "fm-control-lib: agy2 rides the agy control tables"
}

test_busy_and_delivery_ride_the_agy_signature() {
  local verdict
  verdict=$(fm_busy_classify herdr agy2-label agy2 id "$TMP_ROOT" '  esc to cancel')
  assert_equals "busy agy-regex" "$verdict" "agy2's pinned status row must read busy"
  verdict=$(fm_busy_classify herdr agy2-label agy2 id "$TMP_ROOT" '? for shortcuts')
  assert_equals "unknown agy-regex" "$verdict" "agy2 without the pinned row must never read idle"
  printf '%s\n' '  esc to cancel' | fm_busy_lines_match agy2 ||
    fail "agy2 must share the agy delivery signature"
  pass "fm-busy-lib and fm-composer-lib: agy2 rides the agy signature"
}

test_trust_targets_the_second_store_only() {
  local home wt proj root fleet_store
  home="$TMP_ROOT/trust-home"
  root="$TMP_ROOT/trust-root"
  mkdir -p "$home"
  proj="$TMP_ROOT/trust-proj"
  wt="$TMP_ROOT/trust-wt"
  fm_git_worktree "$proj" "$wt" fm/agy2-trust-test

  HOME="$home" "$TRUST" "$wt" "$proj" --gemini-dir "$root" >/dev/null ||
    fail "the trust helper must accept an explicit agy2 state root"
  assert_grep "$wt" "$root/antigravity-cli/settings.json" \
    "trust must land in agy2's own settings store"
  fleet_store="$home/.gemini/antigravity-cli/settings.json"
  [ ! -e "$fleet_store" ] ||
    fail "the trust helper must not create the fleet settings store when a root is given"
  pass "fm-agy-trust.sh: agy2 trust lands in agy2's store, never the fleet's"
}

test_launcher_refuses_foreign_state_root_flags() {
  local out rc
  out=$(launcher "$TMP_ROOT/root-foreign" unix:path=/nonexistent-fleet-bus \
    --print hi --gemini_dir=/tmp/elsewhere 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a caller-supplied --gemini_dir must be refused"
  assert_contains "$out" "owned by agy2" "the refusal must name the reason"
  pass "fm-agy2.sh: a caller-supplied state root is refused"
}

test_launcher_reports_root_and_refuses_without_identity() {
  local root out rc
  root="$TMP_ROOT/root-empty"
  out=$(launcher "$root" unix:path=/nonexistent-fleet-bus --agy2-root)
  assert_equals "$root" "$out" "--agy2-root must print the resolved root"

  out=$(launcher "$root" unix:path=/nonexistent-fleet-bus --agy2-ready 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an empty second store must not report ready"
  assert_contains "$out" "no second Antigravity identity" \
    "the refusal must name the missing credential"
  pass "fm-agy2.sh: an empty second store refuses before any TUI starts"
}

test_private_store_is_separate_and_refuses_the_fleet_account() {
  if ! command -v dbus-daemon >/dev/null 2>&1 ||
    ! command -v gnome-keyring-daemon >/dev/null 2>&1 ||
    ! command -v secret-tool >/dev/null 2>&1; then
    pass "fm-agy2.sh: no bus or keyring tools here, so the store cases skipped"
    return 0
  fi
  local fleet_dir fleet_bus root out rc
  fleet_dir="$TMP_ROOT/fleet-bus"
  fleet_bus=$(start_private_bus "$fleet_dir") || {
    pass "fm-agy2.sh: no private bus could be started here, so the store cases skipped"
    return 0
  }
  store_token "$fleet_bus" '{"id_token_email":"fleet@example.invalid"}'

  root="$TMP_ROOT/root-live"
  # --agy2-status brings up the private bus and keyring without launching agy,
  # and must not see the stand-in fleet slot.
  out=$(launcher "$root" "$fleet_bus" --agy2-status 2>&1) ||
    fail "the launcher must be able to report status on a clean root: $out"
  assert_contains "$out" "identity:    none stored yet" \
    "a fresh private store must hold no identity"
  [ -f "$root/data/keyrings/login.keyring" ] ||
    fail "the wrapper must keep its keyring store inside its own root"

  # The isolation assertion itself: a probe written on the private bus must not
  # be visible on the fleet bus.
  printf 'probe-value' |
    DBUS_SESSION_BUS_ADDRESS="unix:path=$root/bus" \
      secret-tool store --label=probe fm-agy2-test probe-value 2>/dev/null ||
    fail "the private store must be writable"
  out=$(DBUS_SESSION_BUS_ADDRESS="$fleet_bus" secret-tool lookup fm-agy2-test probe-value 2>/dev/null)
  [ -z "$out" ] || fail "the fleet bus must never see the private store's items"
  DBUS_SESSION_BUS_ADDRESS="unix:path=$root/bus" secret-tool clear fm-agy2-test probe-value \
    >/dev/null 2>&1 || true

  # A private slot holding the fleet account must refuse to start a TUI.
  store_token "unix:path=$root/bus" '{"id_token_email":"fleet@example.invalid"}'
  out=$(launcher "$root" "$fleet_bus" --print hi 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a private store holding the fleet account must refuse to launch"
  assert_contains "$out" "holds the FLEET account" "the refusal must name the fleet account"
  pass "fm-agy2.sh: the private store is its own, and a fleet-account slot is refused"
}

test_detection_marker_names_the_second_identity
test_detection_marker_never_renames_another_harness
test_control_plane_folds_agy2_onto_agy
test_busy_and_delivery_ride_the_agy_signature
test_trust_targets_the_second_store_only
test_launcher_refuses_foreign_state_root_flags
test_launcher_reports_root_and_refuses_without_identity
test_private_store_is_separate_and_refuses_the_fleet_account

# ---------------------------------------------------------------------------
# Spawn path: fm-spawn resolves the agy2 launcher, validates the model through
# it, pre-registers trust in agy2's own store, and refuses the launch outright
# when the launcher reports no second identity. Driven through the real
# bin/fm-spawn.sh with a fake tmux endpoint and a fake agy2 script, the same
# shape tests/fm-agy-harness.test.sh uses for agy.
# ---------------------------------------------------------------------------

SPAWN="$ROOT/bin/fm-spawn.sh"
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

make_agy2_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_AGY_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    dialog)
      printf 'Accessing workspace:\n\n%s\n\nDo you trust the contents of this project?\n\nAntigravity CLI requires permission to read, edit, and execute files here.\n\n> Yes, I trust this folder\n  No, exit\n' "$FM_FAKE_PANE_PATH"
      ;;
    busy)
      printf 'Generating...\n└ Tip: press f to see the full diff.\n\nesc to cancel                                Gemini 3.8 Flash · low\n'
      ;;
    racing)
      printf 'esc to cancel                                Gemini 3.8 Flash · low\n'
      printf 'dialog\n' > "$FM_FAKE_AGY_STATE"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_path_trusted() {
  [ "${FM_FAKE_AGY_ASSUME_TRUSTED:-0}" = 1 ] && return 0
  [ "${FM_FAKE_AGY_IGNORE_TRUST:-0}" = 1 ] && return 1
  node -e 'const fs=require("node:fs");let j={};try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){process.exit(1);}process.exit(Array.isArray(j.trustedWorkspaces)&&j.trustedWorkspaces.includes(process.argv[2])?0:1);' \
    "$FM_FAKE_AGY_SETTINGS" "$FM_FAKE_PANE_PATH"
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ ! -s "$FM_FAKE_AGY_STATE.window" ] || cat "$FM_FAKE_AGY_STATE.window"
    exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$FM_FAKE_AGY_STATE.window"
    exit 0 ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys)
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
      esac
      case "$literal" in
        *--prompt-interactive*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_AGY_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if fake_path_trusted; then
              printf 'busy\n' > "$FM_FAKE_AGY_STATE"
            elif [ "${FM_FAKE_AGY_RACE:-0}" = 1 ]; then
              printf 'racing\n' > "$FM_FAKE_AGY_STATE"
            else
              printf 'dialog\n' > "$FM_FAKE_AGY_STATE"
            fi
            ;;
          dialog)
            if [ "${FM_FAKE_AGY_ANSWER:-works}" = works ]; then
              printf 'busy\n' > "$FM_FAKE_AGY_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane) fake_screen; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
printf 'stub-agy\n'
SH
  chmod +x "$fakebin/agy"
  cat > "$fakebin/agy2" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --agy2-root) printf '%s\n' "${FM_FAKE_AGY2_ROOT:?}"; exit 0 ;;
  --agy2-ready)
    [ "${FM_FAKE_AGY2_READY:-1}" = 1 ] || {
      printf 'agy2: no second Antigravity identity is stored yet\n' >&2
      exit 1
    }
    printf 'second@example.invalid\n'
    exit 0
    ;;
  models)
    printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'
    printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n'
    exit 0
    ;;
esac
printf '%s\n' "$*" >> "${FM_FAKE_AGY2_LAUNCH_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/agy2"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_agy2_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_agy2_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the agy2 dispatch path.

## Firstmate spec
Verify the launch, the trust store target, and the readiness gate.
EOF
  printf 'agy2\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$case_dir/agy2-root/gemini/antigravity-cli"
  printf '%s\n' '{"trustedWorkspaces":["/home/someone/elsewhere"]}' \
    > "$case_dir/agy2-root/gemini/antigravity-cli/settings.json"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_agy2_spawn() {  # <case-record> <id> [extra args...]
  local rec=$1 id=$2 case_dir home proj wt fakebin
  shift 2
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_AGY2_ROOT="$case_dir/agy2-root" \
    FM_FAKE_AGY2_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_AGY2_READY="${FM_FAKE_AGY2_READY:-1}" \
    FM_FAKE_LAUNCH_LOG="$case_dir/agy-launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_AGY_STATE="$case_dir/agy.state" \
    FM_FAKE_AGY_SETTINGS="$case_dir/agy2-root/gemini/antigravity-cli/settings.json" \
    FM_FAKE_AGY_ASSUME_TRUSTED=0 \
    FM_AGY_READY_POLLS=4 FM_AGY_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness agy2 --mode no-mistakes --yolo off "$@" 2>&1
}

test_spawn_uses_the_agy2_launcher_and_its_own_trust_store() {
  local id rec out rc launch meta fleet_settings
  id="agy2-launch-$$"
  rec=$(make_agy2_spawn_case launch "$id")
  out=$(run_agy2_spawn "$rec" "$id" --model gemini-3.8-flash-low --effort low)
  rc=$?
  expect_code 0 "$rc" "an agy2 spawn with a listed model should succeed: $out"
  case_dir=${rec%%|*}
  launch=$(cat "$case_dir/agy-launch.log")
  assert_contains "$launch" "--prompt-interactive" "the agy2 launch must carry the brief"
  assert_contains "$launch" "--model 'gemini-3.8-flash-low'" "the agy2 launch must carry the model"
  assert_contains "$launch" "--effort 'low'" "the agy2 launch must carry the effort"
  assert_contains "$launch" "--dangerously-skip-permissions" "the agy2 launch must carry autonomy"
  assert_not_contains "$launch" "__AGY2BIN__" "the agy2 launch left its binary placeholder"
  meta="$case_dir/home/state/$id.meta"
  assert_grep 'harness=agy2' "$meta" "agy2 meta must record its own harness"
  assert_grep "\"$case_dir/wt\"" "$case_dir/agy2-root/gemini/antigravity-cli/settings.json" \
    "agy2 trust must land in agy2's own settings store"
  fleet_settings="$case_dir/home/.gemini/antigravity-cli/settings.json"
  [ ! -e "$fleet_settings" ] || fail "the agy2 spawn must not write the fleet trust store"
  pass "fm-spawn: agy2 launches through its launcher and trusts in agy2's own store"
}

make_agy2_secondmate_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home subhome fakebin
  case_dir="$TMP_ROOT/spawn-$name"
  home="$case_dir/home"
  subhome="$case_dir/subhome"
  fakebin=$(make_agy2_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise the agy2 secondmate supervision channel.

## Firstmate spec
Verify turn-end signalling, steering delivery, and lifecycle keys.
EOF
  # Setup secondmate home
  mkdir -p "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/config" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf '# Firstmate\n' > "$subhome/AGENTS.md"
  printf 'charter\n' > "$subhome/data/charter.md"
  cat > "$subhome/bin/fm-guard.sh" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$subhome/bin/fm-guard.sh"
  cat > "$subhome/bin/fm-session-start.sh" <<'SH'
#!/bin/sh
exit 0
SH
  chmod +x "$subhome/bin/fm-session-start.sh"

  git -C "$subhome" init -q
  git -C "$subhome" config user.name "Firstmate Tests"
  git -C "$subhome" config user.email "tests@example.invalid"
  git -C "$subhome" add AGENTS.md bin/
  git -C "$subhome" commit -qm initial

  # Register in primary home
  printf -- '- %s - conformance (home: %s; scope: conformance; projects: alpha; added 2026-10-23)\n' \
    "$id" "$subhome" > "$home/data/secondmates.md"

  mkdir -p "$case_dir/agy2-root/gemini/antigravity-cli"
  printf '%s\n' '{"trustedWorkspaces":["/home/someone/elsewhere"]}' \
    > "$case_dir/agy2-root/gemini/antigravity-cli/settings.json"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  printf '%s|%s|%s|%s\n' "$case_dir" "$home" "$subhome" "$fakebin"
}

test_spawn_refuses_agy2_without_a_second_identity() {
  local id rec out rc
  id="agy2-nocred-$$"
  rec=$(make_agy2_spawn_case nocred "$id")
  out=$(FM_FAKE_AGY2_READY=0 run_agy2_spawn "$rec" "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an agy2 spawn with no second identity must be refused"
  assert_contains "$out" "no second Antigravity identity" \
    "the refusal must name the missing credential"
  case_dir=${rec%%|*}
  [ ! -s "$case_dir/launch.log" ] || fail "a refused agy2 spawn must never launch the CLI"
  pass "fm-spawn: an agy2 spawn with no stored identity is refused before any launch"
}

test_agy2_secondmate_conformance() {
  local id rec case_dir home subhome fakebin out rc
  local meta hook_file hook_cmd hook_out busypath verdict family
  id="agy2-conformance-$$"
  rec=$(make_agy2_secondmate_case conformance "$id")
  IFS='|' read -r case_dir home subhome fakebin <<EOF
$rec
EOF

  out=$(HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$subhome" TMUX="fake,1,0" \
    FM_FAKE_AGY2_ROOT="$case_dir/agy2-root" \
    FM_FAKE_AGY2_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_AGY2_READY="${FM_FAKE_AGY2_READY:-1}" \
    FM_FAKE_LAUNCH_LOG="$case_dir/agy-launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_AGY_STATE="$case_dir/agy.state" \
    FM_FAKE_AGY_SETTINGS="$case_dir/agy2-root/gemini/antigravity-cli/settings.json" \
    FM_FAKE_AGY_ASSUME_TRUSTED=0 \
    FM_AGY_READY_POLLS=4 FM_AGY_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$subhome" --secondmate --harness agy2 2>&1)
  rc=$?
  expect_code 0 "$rc" "agy2 secondmate spawn should succeed: $out"

  # 1. Verify task metadata and trust pre-registration
  meta="$home/state/$id.meta"
  assert_grep 'harness=agy2' "$meta" "secondmate meta must record harness=agy2"
  assert_grep 'kind=secondmate' "$meta" "secondmate meta must record kind=secondmate"
  assert_grep "home=$subhome" "$meta" "secondmate meta must record home path"
  assert_grep "\"$subhome\"" "$case_dir/agy2-root/gemini/antigravity-cli/settings.json" \
    "secondmate home trust must land in agy2's own settings store"
  [ ! -e "$home/.gemini/antigravity-cli/settings.json" ] \
    || fail "secondmate trust pre-registration touched the fleet store"

  # 2. Verify busy wiring and Stop hook installation
  [ -e "$home/state/$id.busy-gen" ] || fail "busy-gen sidecar must be armed"
  busypath="$home/state/$id.busy-state"
  [ -e "$busypath" ] || fail "busy-state record must exist"
  hook_file="$subhome/.agents/hooks.json"
  [ -f "$hook_file" ] || fail "Stop hook was not installed into secondmate home"
  hook_cmd=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(j.firstmate.Stop[0].command);' "$hook_file")
  assert_contains "$hook_cmd" "fm-busy-event.sh" "hook command must invoke fm-busy-event.sh"
  assert_contains "$hook_cmd" "idle" "hook command must apply idle state"
  assert_contains "$hook_cmd" "--source agy-hook" "hook command must specify agy-hook source"
  assert_contains "$hook_cmd" "--event stop" "hook command must specify stop event"

  # 3. Verify turn-end signalling via Stop hook execution
  hook_out=$(sh -c "cd '$subhome/.agents' && $hook_cmd")
  assert_equals '{}' "$hook_out" "Stop hook command must output JSON {}"
  assert_contains "$(cat "$busypath")" "state=idle" "busy-state must transition to idle"
  assert_contains "$(cat "$busypath")" "source=agy-hook" "busy-state must record agy-hook source"
  verdict=$(fm_busy_classify tmux fake agy2 "$id" "$home/state" '')
  assert_equals "idle agy-hook" "$verdict" "classification must report honest idle agy-hook"

  # 4. Verify honest fallback classification (never invent idle)
  verdict=$(fm_busy_classify tmux fake agy2 "$id-other" "$home/state" '  esc to cancel')
  assert_equals "busy agy-regex" "$verdict" "fallback must report busy on pinned row"
  verdict=$(fm_busy_classify tmux fake agy2 "$id-other" "$home/state" 'other text')
  assert_equals "unknown agy-regex" "$verdict" "fallback must report unknown without marker, never idle"

  # 5. Verify lifecycle keys
  family=$(fm_control_harness_family agy2)
  assert_equals Escape "$(fm_control_interrupt_key "$family")" "interrupt key must be Escape"
  assert_equals /quit "$(fm_control_exit_command "$family")" "exit command must be /quit"
  assert_equals 1 "$(fm_control_interrupt_repeat "$family")" "interrupt repeat must be 1"
  assert_equals key "$(fm_control_interrupt_transport "$family")" "interrupt transport must be key"

  # 6. Verify steering delivery
  assert_contains "$(cat "$case_dir/agy-launch.log")" "$id.inbox" "launch command exports FM_TASK_INBOX"
  assert_contains "$(cat "$case_dir/agy-launch.log")" "FM_HOME='$subhome'" "launch command exports secondmate FM_HOME"
  assert_grep 'window=' "$meta" "secondmate has a recorded window"

  # 7. Verify hook teardown cleanly removes what spawn added
  node -e '
    const fs = require("node:fs");
    const file = process.argv[1];
    const data = JSON.parse(fs.readFileSync(file, "utf8"));
    delete data.firstmate;
    if (Object.keys(data).length === 0) fs.unlinkSync(file);
    else fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  ' "$hook_file"
  rmdir "$subhome/.agents" 2>/dev/null || true
  [ ! -e "$hook_file" ] || fail "hooks.json should be removed when empty"
  [ ! -d "$subhome/.agents" ] || fail ".agents dir should be removed when empty"
  [ -f "$subhome/AGENTS.md" ] || fail "AGENTS.md should remain intact"
  [ -f "$subhome/data/charter.md" ] || fail "charter.md should remain intact"

  pass "fm-spawn: agy2 secondmate conformance passed (hook turn-end, classification, lifecycle, steering, trust)"
}

test_spawn_uses_the_agy2_launcher_and_its_own_trust_store
test_spawn_refuses_agy2_without_a_second_identity
test_agy2_secondmate_conformance

echo "fm-agy2-harness.test.sh: all cases passed"
