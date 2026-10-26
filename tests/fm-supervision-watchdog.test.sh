#!/usr/bin/env bash
# tests/fm-supervision-watchdog.test.sh - behavioral tests for the persistent
# supervisor watchdog daemon and terminal doorbell delivery to primary supervisor
# panes (including Herdr w44:p1 and agy CLI sessions).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCHDOG="$ROOT/bin/fm-supervision-watchdog.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-watchdog)

# Safety pin: do not allow any test in this suite to type into the real supervisor pane.
export FM_SUPERVISOR_TARGET=unused
export FM_SUPERVISOR_BACKEND=tmux

make_test_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/bin"
  printf '%s\n' "$home"
}

# --- Test 1: Lifecycle (start, stop, status, restart, singleton) --------------
test_watchdog_lifecycle() {
  local home state mock_watch out pid status_out

  home=$(make_test_home lifecycle)
  state="$home/state"

  # Mock watcher that sleeps until interrupted
  mock_watch="$home/bin/mock-watch.sh"
  cat <<'EOF' > "$mock_watch"
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while true; do
  sleep 0.1
done
EOF
  chmod +x "$mock_watch"

  # Start watchdog daemon in background
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_OVERRIDE="$mock_watch" \
    "$WATCHDOG" start 2>&1)
  assert_contains "$out" "started pid=" "watchdog did not report started pid"

  # Verify status reports running
  status_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCHDOG" --status)
  assert_contains "$status_out" "supervision-watchdog: running pid=" "status did not report running"
  pid=$(cat "$state/.supervision-watchdog.pid" 2>/dev/null || true)
  [ -n "$pid" ] || fail "pidfile was not created"
  kill -0 "$pid" 2>/dev/null || fail "watchdog process $pid is not alive"

  # Duplicate start attempts should report already running and exit 0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_OVERRIDE="$mock_watch" \
    "$WATCHDOG" start 2>&1)
  assert_contains "$out" "already running" "second start did not detect existing daemon"

  # Restart daemon
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_OVERRIDE="$mock_watch" \
    "$WATCHDOG" --restart 2>&1)
  assert_contains "$out" "started pid=" "restart did not start fresh daemon"

  # Stop daemon
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCHDOG" --stop 2>&1)
  assert_contains "$out" "stopped" "stop did not report stopped"

  # Verify process is dead and state cleaned up
  kill -0 "$pid" 2>/dev/null && fail "watchdog process $pid was not terminated"
  [ ! -f "$state/.supervision-watchdog.pid" ] || fail "pidfile was not removed"
  [ ! -d "$state/.supervision-watchdog.lock" ] || fail "lockdir was not removed"

  # Status reports stopped with rc=1
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCHDOG" --status >/dev/null 2>&1; then
    fail "status returned 0 when stopped"
  fi

  pass "watchdog lifecycle (start, stop, status, restart, singleton) operates cleanly"
}

# --- Test 2: Stale lock recovery ----------------------------------------------
test_watchdog_stale_lock_recovery() {
  local home state mock_watch out pid

  home=$(make_test_home stale-lock)
  state="$home/state"

  mock_watch="$home/bin/mock-watch.sh"
  cat <<'EOF' > "$mock_watch"
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while true; do
  sleep 0.1
done
EOF
  chmod +x "$mock_watch"

  # Create a stale lock directory with a non-existent dead PID
  mkdir -p "$state/.supervision-watchdog.lock"
  printf '999999\n' > "$state/.supervision-watchdog.lock/pid"

  # Start should reclaim the stale lock and succeed
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_OVERRIDE="$mock_watch" \
    "$WATCHDOG" start 2>&1)
  assert_contains "$out" "started pid=" "watchdog did not reclaim stale lock"

  pid=$(cat "$state/.supervision-watchdog.pid" 2>/dev/null || true)
  [ -n "$pid" ] && [ "$pid" != "999999" ] || fail "failed to acquire fresh pid"

  # Stop daemon
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCHDOG" --stop >/dev/null 2>&1 || true

  pass "watchdog reclaims stale lock left by deceased process"
}

# --- Test 3: Continuous re-arming on actionable wake --------------------------
test_watchdog_continuous_rearming_on_actionable_wake() {
  local home state mock_watch counter_file out i

  home=$(make_test_home continuous-rearm)
  state="$home/state"
  counter_file="$state/watcher-runs"
  echo "0" > "$counter_file"

  # Mock watcher that emits actionable wake on runs 1 and 2, then sleeps on run 3
  mock_watch="$home/bin/mock-watch.sh"
  cat <<EOF > "$mock_watch"
#!/usr/bin/env bash
runs=\$(cat "$counter_file" 2>/dev/null || printf '0')
runs=\$((runs + 1))
echo "\$runs" > "$counter_file"

if [ "\$runs" -eq 1 ]; then
  printf 'task-1 needs-decision: approve design\n'
  exit 0
elif [ "\$runs" -eq 2 ]; then
  printf 'task-2 done: implementation ready\n'
  exit 0
else
  trap 'exit 0' TERM INT
  while true; do sleep 0.1; done
fi
EOF
  chmod +x "$mock_watch"

  # Launch watchdog
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_OVERRIDE="$mock_watch" \
    "$WATCHDOG" start >/dev/null 2>&1

  # Wait until watcher reaches run 3 (proving automatic re-arming across runs 1 and 2)
  i=0
  while [ "$i" -lt 50 ]; do
    runs=$(cat "$counter_file" 2>/dev/null || printf '0')
    if [ "$runs" -ge 3 ]; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done

  runs=$(cat "$counter_file" 2>/dev/null || printf '0')
  [ "$runs" -ge 3 ] || fail "watchdog did not continuously re-arm (completed runs: $runs)"

  # Check logs for actionable wakes
  log_content=$(cat "$state/.supervision-watchdog.log" 2>/dev/null || true)
  assert_contains "$log_content" "actionable wake: task-1 needs-decision: approve design" \
    "first actionable wake was not recorded in log"
  assert_contains "$log_content" "actionable wake: task-2 done: implementation ready" \
    "second actionable wake was not recorded in log"

  # Stop watchdog
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCHDOG" --stop >/dev/null 2>&1 || true

  pass "watchdog continuously re-arms on actionable wakes without supervision lapse"
}

# --- Test 4: Once mode execution ----------------------------------------------
test_watchdog_once_mode() {
  local home state mock_watch counter_file out

  home=$(make_test_home once-mode)
  state="$home/state"
  counter_file="$state/watcher-runs"
  echo "0" > "$counter_file"

  mock_watch="$home/bin/mock-watch.sh"
  cat <<EOF > "$mock_watch"
#!/usr/bin/env bash
runs=\$(cat "$counter_file" 2>/dev/null || printf '0')
runs=\$((runs + 1))
echo "\$runs" > "$counter_file"
printf 'task-once done: single pass\n'
exit 0
EOF
  chmod +x "$mock_watch"

  # Run watchdog with --once --foreground
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_OVERRIDE="$mock_watch" \
    "$WATCHDOG" --once --foreground >/dev/null 2>&1

  runs=$(cat "$counter_file" 2>/dev/null || printf '0')
  assert_equals "1" "$runs" "once mode did not exit after exactly one cycle"
  [ ! -f "$state/.supervision-watchdog.pid" ] || fail "pidfile left behind in once mode"
  [ ! -d "$state/.supervision-watchdog.lock" ] || fail "lock left behind in once mode"

  pass "watchdog --once terminates cleanly after a single cycle"
}

# --- Test 5: Self-healing on watcher child crash ------------------------------
test_watchdog_self_healing_on_crash() {
  local home state mock_watch counter_file i runs log_content

  home=$(make_test_home crash-healing)
  state="$home/state"
  counter_file="$state/watcher-runs"
  echo "0" > "$counter_file"

  # Mock watcher that crashes (exit 2) on run 1, then runs normally on run 2
  mock_watch="$home/bin/mock-watch.sh"
  cat <<EOF > "$mock_watch"
#!/usr/bin/env bash
runs=\$(cat "$counter_file" 2>/dev/null || printf '0')
runs=\$((runs + 1))
echo "\$runs" > "$counter_file"

if [ "\$runs" -eq 1 ]; then
  exit 2
else
  trap 'exit 0' TERM INT
  while true; do sleep 0.1; done
fi
EOF
  chmod +x "$mock_watch"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_WATCH_OVERRIDE="$mock_watch" \
    "$WATCHDOG" start >/dev/null 2>&1

  # Wait for run 2 to be entered after crash recovery
  i=0
  while [ "$i" -lt 50 ]; do
    runs=$(cat "$counter_file" 2>/dev/null || printf '0')
    if [ "$runs" -ge 2 ]; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done

  runs=$(cat "$counter_file" 2>/dev/null || printf '0')
  [ "$runs" -ge 2 ] || fail "watchdog did not self-heal and restart crashed watcher"

  log_content=$(cat "$state/.supervision-watchdog.log" 2>/dev/null || true)
  assert_contains "$log_content" "watcher child crashed or exited nonzero (rc=2" \
    "crash was not logged with exit code"

  # Stop watchdog
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCHDOG" --stop >/dev/null 2>&1 || true

  pass "watchdog self-heals with exponential backoff on watcher crash"
}

# --- Test 6: Herdr w44:p1 target resolution and doorbell delivery -------------
test_herdr_w44_p1_doorbell_delivery() {
  local home state captured verdict record

  home=$(make_test_home herdr-doorbell)
  state="$home/state"
  captured="$state/captured-submission"

  # Verify supervisor backend inference and target parsing for Herdr w44:p1
  (
    unset FM_SUPERVISOR_BACKEND
    export FM_SUPERVISOR_TARGET="w44:p1"
    # shellcheck source=bin/fm-supervisor-target-lib.sh
    . "$ROOT/bin/fm-supervisor-target-lib.sh"
    # shellcheck source=bin/backends/herdr.sh
    . "$ROOT/bin/backends/herdr.sh"

    b=$(discover_supervisor_backend)
    [ "$b" = herdr ] || exit 11
    t=$(discover_supervisor_target)
    [ "$t" = "w44:p1" ] || exit 12

    fm_backend_herdr_parse_target "$t" || exit 13
    [ "$FM_BACKEND_HERDR_PANE" = "w44:p1" ] || exit 14
    [ "$FM_BACKEND_HERDR_SESSION" = "default" ] || exit 15
  ) || fail "herdr w44:p1 target resolution failed"

  # Test fm_procevent_ring_doorbell delivering to herdr:w44:p1
  export CAPTURED="$captured"
  verdict=$(
    FM_HOME="$home" FM_DAEMON_PRIMARY_HARNESS=agy bash -c '
      . "$1/bin/fm-pr-lib.sh"
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-backend.sh"
      . "$1/bin/fm-procevent-lib.sh"
      fm_backend_source() { return 0; }
      fm_backend_target_exists() { return 0; }
      fm_backend_busy_state() { printf "idle\n"; }
      fm_backend_capture() { printf "\n"; }
      fm_backend_composer_state() { printf "empty\n"; }
      fm_backend_send_text_submit() { printf "%s\n" "$3" > "$CAPTURED"; printf "empty\n"; }
      fm_procevent_ring_doorbell "$2" herdr "w44:p1" "task-agy-1 done: supervisor review ready"
    ' _ "$ROOT" "$state"
  )

  assert_equals "delivered" "$verdict" "doorbell was not delivered to w44:p1"
  [ -f "$captured" ] || fail "doorbell submitted nothing to w44:p1"

  # agy receives the typed operational envelope directly with invisible marker
  typed_line=$(cat "$captured")
  assert_contains "$typed_line" "FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE:" \
    "typed submission did not contain operational wake envelope"
  assert_contains "$typed_line" "task-agy-1 done: supervisor review ready" \
    "typed submission did not contain wake reason"

  # Record-needing harness (e.g. claude): verify fallback writes durable operational record
  rm -f "$captured"
  verdict=$(
    FM_HOME="$home" FM_DAEMON_PRIMARY_HARNESS=claude bash -c '
      . "$1/bin/fm-pr-lib.sh"
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-backend.sh"
      . "$1/bin/fm-procevent-lib.sh"
      fm_backend_source() { return 0; }
      fm_backend_target_exists() { return 0; }
      fm_backend_busy_state() { printf "idle\n"; }
      fm_backend_capture() { printf "\n"; }
      fm_backend_composer_state() { printf "empty\n"; }
      fm_backend_send_text_submit() { printf "%s\n" "$3" > "$CAPTURED"; printf "empty\n"; }
      fm_procevent_ring_doorbell "$2" herdr "w44:p1" "task-claude-1 done: record carrier ready"
    ' _ "$ROOT" "$state"
  )
  assert_equals "delivered" "$verdict" "claude doorbell was not delivered"
  typed_line=$(cat "$captured")
  assert_contains "$typed_line" "Firstmate operational input waiting" \
    "typed submission did not contain operational input marker for claude"

  record=$(find "$state/operational-inbox" -maxdepth 1 -name '*.msg' -print -quit 2>/dev/null)
  [ -n "$record" ] || fail "operational record was not written for claude doorbell"
  record_content=$(cat "$record")
  assert_contains "$record_content" "task-claude-1 done: record carrier ready" \
    "operational record did not contain wake reason"
  assert_contains "$record_content" "Run bin/fm-wake-drain.sh first" \
    "operational record did not contain drain instructions"

  pass "fast-lane doorbell delivery correctly targets Herdr pane w44:p1"
}

# --- Test 7: Doorbell skips when composer is busy or pending ------------------
test_herdr_doorbell_defers_when_composer_not_empty() {
  local home state captured verdict

  home=$(make_test_home herdr-doorbell-busy)
  state="$home/state"
  captured="$state/captured-submission"

  # When composer_state is unknown or pending: doorbell returns skipped
  export CAPTURED="$captured"
  verdict=$(
    FM_HOME="$home" FM_DAEMON_PRIMARY_HARNESS=agy bash -c '
      . "$1/bin/fm-pr-lib.sh"
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-backend.sh"
      . "$1/bin/fm-procevent-lib.sh"
      fm_backend_source() { return 0; }
      fm_backend_target_exists() { return 0; }
      fm_backend_busy_state() { printf "idle\n"; }
      fm_backend_capture() { printf "\n"; }
      fm_backend_composer_state() { printf "unknown\n"; }
      fm_backend_send_text_submit() { printf "%s\n" "$3" > "$CAPTURED"; printf "empty\n"; }
      fm_procevent_ring_doorbell "$2" herdr "w44:p1" "task-wait needs-decision: hold"
    ' _ "$ROOT" "$state"
  )
  assert_equals "skipped" "$verdict" "doorbell did not skip when composer was not empty"
  [ ! -f "$captured" ] || fail "doorbell typed into busy/unknown composer"

  # When busy_state is busy: doorbell returns skipped
  verdict=$(
    FM_HOME="$home" FM_DAEMON_PRIMARY_HARNESS=agy bash -c '
      . "$1/bin/fm-pr-lib.sh"
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-backend.sh"
      . "$1/bin/fm-procevent-lib.sh"
      fm_backend_source() { return 0; }
      fm_backend_target_exists() { return 0; }
      fm_backend_busy_state() { printf "busy\n"; }
      fm_backend_capture() { printf "\n"; }
      fm_backend_composer_state() { printf "empty\n"; }
      fm_backend_send_text_submit() { printf "%s\n" "$3" > "$CAPTURED"; printf "empty\n"; }
      fm_procevent_ring_doorbell "$2" herdr "w44:p1" "task-wait needs-decision: hold"
    ' _ "$ROOT" "$state"
  )
  assert_equals "skipped" "$verdict" "doorbell did not skip when pane was busy"
  [ ! -f "$captured" ] || fail "doorbell typed into busy pane"

  pass "doorbell safely skips when supervisor pane is busy or composer is pending"
}

# --- Run All Tests ------------------------------------------------------------
test_watchdog_lifecycle
test_watchdog_stale_lock_recovery
test_watchdog_continuous_rearming_on_actionable_wake
test_watchdog_once_mode
test_watchdog_self_healing_on_crash
test_herdr_w44_p1_doorbell_delivery
test_herdr_doorbell_defers_when_composer_not_empty
