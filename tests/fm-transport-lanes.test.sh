#!/usr/bin/env bash
# Behavioral tests for the two-lane transport refactor and duplicate ring deduplication:
# - Fast-lane event delivery without slow-lane sweep (ring recorded, zero cycle exits).
# - Fast-lane event arriving while session is down delivered once on recovery from durable record.
# - Slow lane still finds slow events and slow pass does not delay fast-lane events.
# - Structured consumption strips DOM snapshots and redundant instructions.
# - Pi primary extension delivers fast-lane rings directly.
# - One wake per event identity across pending, delivered, and acknowledged states.
# - Deduplication never swallows real events or sequences across mid-turn and restart.
# - A delivered wake is consumed once; a later arrival of the same text is ordinary input.
# - A captain paste of a wake is ordinary input and does not retire the pending wake.
# - A captain message naming an event is not an event.
# - A fast-lane wake the branch took is settled instead of being offered again.
# - A refused fast-lane delivery keeps its ring.
# - The ring log records what the supervisor doorbell and the consumer actually did.
# - The ring log names the ring command channel and what it did.
# - The fast lane's pane wake names the event and carries the drain instruction.
# - The slow lane's announcement retires the fast lane's ring file.
# - The Pi consumer recognizes the slow lane's announcement of the same event.
# - A fast-lane claim that cannot be recorded leaves the event to the slow lane.
# - The fast lane announces each event once, through exactly one consumer.
# - The pane is rung when no live consumer took the event.
# - A reused consumer pid does not read as a live consumer.
# - The consumer's identity and the shell's are the same string for a live pid.
# - The previous build's consumer marker is read as a live consumer.
# - A legacy consumer marker whose pid was reused reads as stale.
# - A legacy consumer marker naming a zombie is not a live consumer.
# - The two consumer marker forms are judged by their own rule.
# - The ring log records a retirement that did not happen as what it was.
# - A confirmed pane delivery retires the consumer's ring file and the slow
#   lane stays off the event.
# - No ring in this suite can reach a live pane.
# - The fast-lane ring file is always valid JSON, whatever the home path holds.
# - A shell-side surfaced marker does not suppress the Pi consumer's own ring.
# - The procevent library loads in a deployment without the pane delivery path.
# - The fast-lane scan defers an event the replacement handoff already owns.
# - A fast-lane wake the branch holds in flight is not offered to it again.
# - Repetition stopped at source (one ring per event).
# - Lost rings rescued by slow lane (surfaced marker not stamped at ring time).
# - An acknowledged result is not surfaced by the slow lane again.
# - One event is announced once in a Pi home, even when the watcher's cycle
#   sweeps the queue in the same cycle the fast lane delivers.
# - The slow lane delivers an event whose fast-lane delivery did not complete.
# - A stale consumer marker leaves the event to the slow lane.
# - The trimmed fast-lane ring log holds only complete records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-transport-lanes)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
export NODE_NO_WARNINGS=1

# The fast lane's doorbell resolves the supervisor pane from the MACHINE, not
# from the test home, so the suite pins a target that does not exist: a test
# must never type into the captain's live pane. The doorbell-specific cases
# override the target inline, which keeps their meaning.
export FM_SUPERVISOR_TARGET=unused
export FM_SUPERVISOR_BACKEND=tmux

# The slow-lane independence case drives a real watcher pass, so it needs the
# hermetic fake tmux and fake crew state the wake suites share. The root stays
# this checkout so the shared harness leaves it alone.
FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$ROOT}"
export FM_ROOT_OVERRIDE
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'EOF'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
EOF
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'EOF'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
EOF
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'EOF'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
EOF
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'EOF'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
EOF
  cat > "$repo/node_modules/typebox/package.json" <<'EOF'
{"name":"typebox","type":"module","exports":"./index.js"}
EOF
  cat > "$repo/node_modules/typebox/index.js" <<'EOF'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
EOF
}

new_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/projects"
}

wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -e "$f" ] && return 0; sleep 0.05; done
  return 1
}

wait_for_text() {  # <file> <needle> [tries]
  local f=$1 needle=$2 n=${3:-100}
  for _ in $(seq 1 "$n"); do
    [ -f "$f" ] && grep -q -- "$needle" "$f" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

wait_gone() {  # <path> [tries]
  local p=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ ! -e "$p" ] && return 0; sleep 0.05; done
  return 1
}

# live_consumer_marker <state>: the marker a live Pi consumer writes: its pid
# and that process's identity, which the shell verifies against the live
# process.
live_consumer_marker() {  # <state>
  local identity
  identity=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$$")
  printf '%s\n%s\n' "$$" "$identity" > "$1/fast-lane/.consumer"
}

# ring_with_stubbed_doorbell <home> <state> <id> <verdict>: run the production
# ring path with the pane interaction stubbed, because a test must never type
# into a live pane. The stub records that the pane was rung and returns the
# supplied verdict.
ring_with_stubbed_doorbell() {  # <home> <state> <id> <verdict>
  FM_HOME="$1" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fm-test-pane bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    verdict=$2; state_dir=$3; event_id=$4
    fm_procevent_ring_doorbell() { printf "called\n" > "$state_dir/.doorbell-called"; printf "%s\n" "$verdict"; }
    fm_procevent_ring_primary "$state_dir" lavish "$event_id" 1 "$state_dir/procevent-inbox/$event_id.1.result" "check: procevent lavish $event_id 1"
  ' _ "$ROOT" "$4" "$2" "$3"
}

# write_pi_consumer_script <path>: a node harness that loads the Pi primary
# watch extension against a fake Pi and records every wake the extension
# delivers. PI_CONSUMER_MODE=inflight keeps the delivery in flight;
# PI_CONSUMER_MODE=refuse throws instead of delivering.
write_pi_consumer_script() {  # <path>
  cat > "$1" <<'EOF'
import { appendFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mode = process.env.PI_CONSUMER_MODE || "inflight";
const promptsFile = process.env.PROMPTS_FILE;

function makePi() {
  const handlers = new Map();
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => {
      appendFileSync(promptsFile, `${message}\n`);
      if (mode === "refuse") throw new Error("pi refused the wake");
      await new Promise(() => {});
    },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers };
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
setInterval(() => {}, 1000);
EOF
}

test_pi_home_announces_one_event_once() {
  local repo home plugin node_pid out event_id control_id prompts count
  repo="$TMP_ROOT/pi-once-root"
  home="$TMP_ROOT/pi-once-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/procevent" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  event_id="announced-once"
  control_id="sweep-control"
  prompts="$home/prompts.log"

  # The extension is the live fast-lane consumer. Its delivery stays in
  # flight, so the slow lane meets a fast lane that is handling the event.
  write_pi_consumer_script "$home/consumer.mjs"
  PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" PROMPTS_FILE="$prompts" \
    PI_CONSUMER_MODE=inflight node "$home/consumer.mjs" >"$home/extension.out" 2>&1 &
  node_pid=$!
  wait_for "$home/state/fast-lane/.consumer" 200 \
    || fail "the Pi consumer never became live: $(cat "$home/extension.out" 2>/dev/null)"

  cat > "$home/state/procevent-inbox/$event_id.1.result" <<'EOF'
session:
  file: /announced-once.html
  status: feedback
feedback[1]{prompt,target}:
  "Announced once feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$event_id.1.adapter"

  # A second queued event the fast lane never rings. The slow lane announces
  # it, which proves the sweep ran in the watcher's own cycle.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_append check "procevent:$2:1" "check: procevent lavish $2 1"
  ' _ "$ROOT" "$control_id" || fail "the control event was not queued"

  # The watcher's own cycle: it reconciles, which publishes the event and
  # rings the fast lane, and then it sweeps the same queue in that cycle.
  out="$home/watch.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true

  assert_contains "$(cat "$out")" "procevent:$control_id:1" \
    "the watcher's cycle never swept the queue"

  # The event the fast lane is delivering is left to the fast lane.
  assert_not_contains "$(cat "$out")" "procevent:$event_id:1" \
    "the slow lane announced an event the fast lane was delivering"

  # The fast lane announced it once.
  wait_for_text "$prompts" "$event_id" 200 \
    || fail "the fast lane never delivered the event: $(cat "$prompts" 2>/dev/null)"
  count=$(grep -c -- "$event_id" "$prompts" 2>/dev/null || echo 0)
  [ "$count" -eq 1 ] || fail "the fast lane announced the event $count times"

  kill -TERM "$node_pid" 2>/dev/null || true
  wait "$node_pid" 2>/dev/null || true

  pass "one event is announced once in a Pi home, even when the watcher's cycle sweeps the queue in the same cycle"
}

test_slow_lane_delivers_an_event_the_fast_lane_did_not() {
  local repo home plugin node_pid out event_id prompts live_marker surfaced_marker
  repo="$TMP_ROOT/pi-rescue-root"
  home="$TMP_ROOT/pi-rescue-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/procevent-inbox" "$home/state/fast-lane"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  event_id="fast-lane-refused"
  prompts="$home/prompts.log"
  live_marker="$home/state/.live-procevent-$(printf 'procevent:%s:1' "$event_id" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
  surfaced_marker="$home/state/.seen-procevent-$(printf 'procevent:%s:1' "$event_id" | LC_ALL=C od -An -tx1 | tr -d ' \n')"

  cat > "$home/state/procevent-inbox/$event_id.1.result" <<'EOF'
session:
  file: /fast-lane-refused.html
  status: feedback
feedback[1]{prompt,target}:
  "Fast lane refused feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$event_id.1.adapter"

  # The event is published and the fast lane's ring file is the consumer's
  # copy of it.
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  [ -f "$home/state/fast-lane/$event_id.1.ring.json" ] \
    || fail "the fast lane wrote no ring file for the consumer"

  # The extension is the live fast-lane consumer, and it refuses the wake.
  write_pi_consumer_script "$home/consumer.mjs"
  PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" PROMPTS_FILE="$prompts" \
    PI_CONSUMER_MODE=refuse node "$home/consumer.mjs" >"$home/extension.out" 2>&1 &
  node_pid=$!
  wait_for "$home/state/fast-lane/.consumer" 200 \
    || fail "the Pi consumer never became live: $(cat "$home/extension.out" 2>/dev/null)"

  # The fast lane's delivery does not complete: the consumer refuses it.
  wait_for_text "$prompts" "$event_id" 200 \
    || fail "the fast lane never attempted the delivery: $(cat "$home/extension.out" 2>/dev/null)"
  # The ring file is the requeue, so the consumer would offer the event again
  # on its next scan; this case is about the record the failed delivery left.
  rm -f "$home/state/fast-lane/$event_id.1.ring.json"
  # The fast lane is done with the event, so the slow lane may take it over.
  wait_gone "$live_marker" 200 \
    || fail "the fast lane's live record outlived its failed delivery"

  # Nothing was delivered, so nothing claims the event as surfaced.
  [ ! -e "$surfaced_marker" ] \
    || fail "a fast-lane delivery that never completed stamped the surfaced marker"

  out="$home/watch.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true
  assert_contains "$(cat "$out")" "procevent:$event_id:1" \
    "the slow lane did not deliver the event the fast lane did not"

  kill -TERM "$node_pid" 2>/dev/null || true
  wait "$node_pid" 2>/dev/null || true

  pass "the slow lane delivers an event whose fast-lane delivery did not complete"
}

test_fast_lane_ring_log_keeps_only_complete_records() {
  local home ring_log id row_len cap published n rows
  home="$TMP_ROOT/ring-log-rows-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  ring_log="$home/state/.fast-lane-ring.log"
  mkdir -p "$home/state/procevent-inbox"

  # One source id of one length keeps every row the same length, so the byte
  # cut lands inside a row's epoch instead of on a row boundary.
  id="trim-$(printf 'x%.0s' $(seq 1 45))"
  make_result() {  # <sequence>
    cat > "$home/state/procevent-inbox/$id.$1.result" <<EOF
session:
  file: /trim.html
  status: feedback
feedback[1]{prompt,target}:
  "Trim feedback", "#target"
EOF
    printf 'lavish\n' > "$home/state/procevent-inbox/$id.$1.adapter"
  }

  make_result 1
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  row_len=$(head -n 1 "$ring_log" 2>/dev/null | wc -c | tr -d ' ')
  [ "$row_len" -gt 3 ] || fail "the fast lane wrote no ring log row"

  # A cap the byte cut cannot land on: every cut starts inside a row.
  cap=$(( row_len * 3 - 3 ))
  published=8
  n=2
  while [ "$n" -le "$published" ]; do
    make_result "$n"
    n=$((n + 1))
  done
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" FM_FAST_LANE_RING_LOG_MAX_BYTES="$cap" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  rows=$(wc -l < "$ring_log" 2>/dev/null | tr -d ' ')
  [ "$rows" -lt "$published" ] || fail "the ring log was never trimmed ($rows rows)"
  # Every row the log kept is a whole record: a full epoch and every field.
  awk -F'\t' 'length($1) != 10 || NF != 10 { bad = 1 } END { exit bad ? 1 : 0 }' "$ring_log" \
    || fail "the trimmed ring log holds a row that is not a complete record: $(cat "$ring_log")"

  pass "the trimmed fast-lane ring log holds only complete records"
}

test_stale_consumer_marker_leaves_the_event_to_the_slow_lane() {
  local home ring_file live_marker out dead_pid
  home="$TMP_ROOT/stale-consumer-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  mkdir -p "$home/state/procevent-inbox" "$home/state/fast-lane"

  # A consumer marker left behind by a session that was killed: the process it
  # names is gone, so nothing will ever deliver the event it claims. The pid
  # sits above every kernel's process ceiling, so the kernel cannot hand it
  # out again while this test runs.
  dead_pid=2147483647
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  printf '%s\n%s\n' "$dead_pid" "linux-starttime=1 cmdline-hex=00" \
    > "$home/state/fast-lane/.consumer"

  cat > "$home/state/procevent-inbox/stale-consumer.1.result" <<'EOF'
session:
  file: /stale-consumer.html
  status: feedback
feedback[1]{prompt,target}:
  "Stale consumer feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/stale-consumer.1.adapter"

  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  ring_file="$home/state/fast-lane/stale-consumer.1.ring.json"
  [ -f "$ring_file" ] || fail "the fast lane wrote no ring file"
  live_marker="$home/state/.live-procevent-$(printf 'procevent:%s:1' "stale-consumer" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
  [ ! -e "$live_marker" ] \
    || fail "a dead consumer claimed the event and silenced the slow lane"

  out="$home/watch.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true
  assert_contains "$(cat "$out")" "procevent:stale-consumer:1" \
    "the slow lane did not deliver an event whose fast-lane consumer was dead"

  pass "a stale consumer marker leaves the event to the slow lane"
}

test_fast_lane_delivered_without_slow_lane_sweep() {
  local home arm_pid watcher_pid initial_exits current_exits ring_log consumer
  home="$TMP_ROOT/fast-lane-home"
  new_home "$home"
  fm_test_track_procevent_home "$home"

  # Acquire session lock for home first
  printf '%s\n' "$$" > "$home/state/.lock"

  # Start watcher in background
  FM_HOME="$home" "$ROOT/bin/fm-watch-arm.sh" > "$home/arm.log" 2>&1 &
  arm_pid=$!

  wait_for "$home/state/.watch.lock/pid" 50 || fail "watcher never acquired lock: $(cat "$home/arm.log" 2>/dev/null)"
  watcher_pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$watcher_pid" ] || fail "watcher pid empty"
  kill -0 "$watcher_pid" 2>/dev/null || fail "watcher pid $watcher_pid not alive"

  initial_exits=0
  if [ -f "$home/state/.watch-cycle-exits.log" ]; then
    initial_exits=$(wc -l < "$home/state/.watch-cycle-exits.log" | tr -d ' ')
  fi

  ring_log="$home/state/.fast-lane-ring.log"

  # The Pi primary watch extension owns the fast-lane directory: without a
  # consumer there is nobody to ring.
  mkdir -p "$home/state/fast-lane"

  # Create an unhandled lavish result
  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/board-test.1.result" <<'EOF'
session:
  file: /board.html
  status: feedback
feedback[1]{prompt,target}:
  "Captain approved the plan", "#decision-btn"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/board-test.1.adapter"

  # Publish the result
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  # Assert 1: The fast-lane ring was recorded immediately
  [ -f "$ring_log" ] || fail "fast-lane ring log was not created"
  grep -q "ring"$'\t'"fast-lane"$'\t'"lavish"$'\t'"board-test"$'\t'"1" "$ring_log" \
    || fail "fast-lane ring was not recorded in $ring_log: $(cat "$ring_log")"

  # Assert 2: The watcher is STILL running (no exit or restart)
  kill -0 "$watcher_pid" 2>/dev/null || fail "watcher died unexpectedly"
  current_exits=0
  if [ -f "$home/state/.watch-cycle-exits.log" ]; then
    current_exits=$(wc -l < "$home/state/.watch-cycle-exits.log" | tr -d ' ')
  fi
  [ "$current_exits" -eq "$initial_exits" ] \
    || fail "watcher had an intervening cycle exit ($current_exits exits vs initial $initial_exits)"

  # Assert 3: The fast-lane directory got the notification
  [ -f "$home/state/fast-lane/board-test.1.ring.json" ] \
    || fail "fast-lane ring JSON was not placed in state/fast-lane/"

  # Assert 3b: The ring log records that the consumer ring file was written
  consumer=$(awk -F'\t' '$2 == "ring" && $5 == "board-test" { print $8 }' "$ring_log")
  [ "$consumer" = written ] \
    || fail "the ring log recorded the consumer outcome '$consumer' for a written ring file"

  # Assert 4: A later reconcile does not ring the same event again
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  ring_count=$(grep -c "board-test"$'\t'"1" "$ring_log" 2>/dev/null || echo 0)
  [ "$ring_count" -eq 1 ] \
    || fail "the same event was ringed $ring_count times"

  # Stop the watcher
  FM_HOME="$home" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
  kill -TERM "$arm_pid" 2>/dev/null || true
  pass "fast-lane event is delivered without waiting for a slow-lane sweep (ring recorded, zero intervening cycles)"
}

test_fast_lane_down_session_recovery() {
  local home drain_out read_out drain_out2
  home="$TMP_ROOT/down-recovery-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"

  # Session is down: no watcher is running
  [ ! -f "$home/state/.watch.lock" ] || fail "watcher should not be running yet"

  # Fast-lane event arrives while down
  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/offline-src.1.result" <<'EOF'
session:
  file: /offline.html
  status: feedback
feedback[1]{prompt,target}:
  "Offline review feedback", "#offline-target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/offline-src.1.adapter"

  # Event is published to durable wake queue and procevent store
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  # Durable record exists
  [ -f "$home/state/procevent-inbox/offline-src.1.result" ] \
    || fail "durable result was not stored"

  drain_err=$(mktemp)
  drain_out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>"$drain_err")
  assert_contains "$drain_out" "procevent lavish offline-src 1" \
    "durable procevent wake was not surfaced on recovery"

  # Structured view is read from durable store
  read_out=$(FM_HOME="$home" "$ROOT/bin/fm-procevent-lavish.sh" read "$home/state/procevent-inbox/offline-src.1.result")
  assert_contains "$read_out" "Offline review feedback" \
    "structured read failed to extract prompt"

  # Mark handled
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" handled offline-src 1 >/dev/null 2>&1

  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*/\1/p' "$drain_err" | tail -1)
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err" | tail -1)
  if [ -n "$sequence" ] && [ -n "$generation" ]; then
    FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1 || true
  else
    FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" --ack-through 1 >/dev/null 2>&1 || true
  fi
  rm -f "$drain_err"

  # Reconcile again: must not resurrect or duplicate the wake
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  drain_out2=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_not_contains "$drain_out2" "procevent lavish offline-src 1" \
    "handled procevent wake was duplicated after handling"

  pass "fast-lane event arriving while session is down is delivered once on recovery from durable record"
}

test_fast_lane_writes_no_ring_without_a_consumer() {
  local home drain_out
  home="$TMP_ROOT/no-consumer-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"

  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/noconsumer.1.result" <<'EOF'
session:
  file: /noconsumer.html
  status: feedback
feedback[1]{prompt,target}:
  "Nobody is listening", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/noconsumer.1.adapter"

  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  [ ! -e "$home/state/fast-lane" ] \
    || fail "the fast lane created a consumer directory nobody asked for"
  [ -z "$(find "$home/state" -maxdepth 2 -name '*.ring.json' -print -quit)" ] \
    || fail "a fast-lane ring file was written without a consumer"

  # The event is still delivered: the slow lane owns it.
  drain_out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_contains "$drain_out" "procevent lavish noconsumer 1" \
    "an event with no fast-lane consumer was not delivered by the slow lane"

  pass "the fast lane writes no ring file when no consumer directory exists"
}

test_handled_event_is_not_surfaced_again() {
  local home out
  home="$TMP_ROOT/handled-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"

  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/handled-src.1.result" <<'EOF'
session:
  file: /handled.html
  status: feedback
feedback[1]{prompt,target}:
  "Handled review feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/handled-src.1.adapter"

  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  out="$home/watch-first.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true
  assert_contains "$(cat "$out")" "procevent:handled-src:1" \
    "the captured result was never surfaced by the slow lane"

  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" handled handled-src 1 >/dev/null 2>&1 \
    || fail "the handled acknowledgement was rejected"

  out="$home/watch-second.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true
  assert_not_contains "$(cat "$out")" "procevent:handled-src:1" \
    "an already handled result was surfaced by the slow lane again"

  pass "an acknowledged result is not surfaced by the slow lane a second time"
}

test_slow_lane_still_finds_slow_events_and_slow_pass_does_not_delay_fast_lane() {
  local home dir state fakebin drain_out t_start t_ring elapsed watch_pid
  home="$TMP_ROOT/slow-lane-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"

  # 3A: Slow lane still finds slow events (status files)
  printf 'needs-decision [at=%s]: captain input required\n' "$(date +%s)" > "$home/state/task-slow.status"
  drain_out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_contains "$drain_out" "task-slow" \
    "slow lane status change was not detected"

  # 3B: A real slow watcher pass runs in an isolated home while the fast lane
  # rings. The fast lane must not wait for the slow cycle to finish.
  dir=$(make_case transport-slow-lane)
  state="$dir/state"; fakebin="$dir/fakebin"
  cat > "$state/slow.check.sh" <<SH
#!/usr/bin/env bash
printf 'started\n' > "$state/.slow-check-started"
sleep 6
printf 'finished\n' > "$state/.slow-check-finished"
SH
  chmod 700 "$state/slow.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" slow >/dev/null \
    || fail "the slow watcher check could not be registered"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2>&1 &
  watch_pid=$!
  wait_for "$state/.slow-check-started" 200 \
    || fail "the slow watcher pass never reached its check: $(cat "$dir/watch.out" 2>/dev/null)"

  mkdir -p "$state/procevent-inbox"
  cat > "$state/procevent-inbox/fast-immediate.1.result" <<'EOF'
session:
  file: /fast.html
  status: feedback
feedback[1]{prompt,target}:
  "Immediate fast ring", "#fast-btn"
EOF
  printf 'lavish\n' > "$state/procevent-inbox/fast-immediate.1.adapter"

  t_start=$(date +%s)
  FM_HOME="$dir" FM_FAST_LANE_RING_LOG="$state/.fast-lane-ring.log" \
    FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  t_ring=$(date +%s)
  elapsed=$((t_ring - t_start))

  [ "$elapsed" -lt 6 ] || fail "the fast lane waited for the slow pass ($elapsed seconds)"
  grep -q "fast-immediate" "$state/.fast-lane-ring.log" \
    || fail "fast-lane ring log missing fast-immediate"
  [ ! -e "$state/.slow-check-finished" ] \
    || fail "the fast lane waited for the slow pass to finish"

  kill -TERM "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true

  pass "slow lane still finds slow events and a real slow pass does not delay the fast lane"
}

test_structured_consumption_strips_dom_snapshot_and_instructions() {
  local result_file read_out
  result_file="$TMP_ROOT/raw-lavish.result"
  cat > "$result_file" <<'EOF'
session:
  file: /review.html
  status: feedback
feedback[1]{prompt,selector,dom_snapshot,next_step}:
  "Please change the heading color to navy", "h1.title", "<html><head><style>...</style></head><body><div id='huge-dom'><div>lots of elements</div></div></body></html>", "next_step: inspect DOM snapshot and reply"
EOF

  read_out=$("$ROOT/bin/fm-procevent-lavish.sh" read "$result_file")

  # Must contain prompt and selector
  assert_contains "$read_out" "Please change the heading color to navy" \
    "structured read dropped user prompt"
  assert_contains "$read_out" "h1.title" \
    "structured read dropped target selector"

  # Must NOT contain raw DOM snapshot or instructions
  assert_not_contains "$read_out" "huge-dom" \
    "structured read leaked raw DOM snapshot into context"
  assert_not_contains "$read_out" "<html>" \
    "structured read leaked HTML tags into context"
  assert_not_contains "$read_out" "next_step: inspect DOM snapshot" \
    "structured read leaked static instructions into context"

  pass "structured consumption strips DOM snapshots and redundant static instructions"
}

test_pi_extension_fast_lane_ringing() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-fast-lane-root"
  home="$TMP_ROOT/pi-fast-lane-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  let tool = null;
  const prompts = [];
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async (message) => {
      prompts.push(message);
    },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, getTool: () => tool, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

// Fast lane directory is watched. Write a fast-lane ring file:
const fastLaneDir = `${process.env.FM_HOME}/state/fast-lane`;
mkdirSync(fastLaneDir, { recursive: true });
const ringPayload = {
  version: 1,
  id: "test-board",
  seq: 1,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/test-board.1.result`,
  reason: "check: procevent lavish test-board 1",
};
writeFileSync(`${fastLaneDir}/test-board.1.ring.json`, JSON.stringify(ringPayload) + "\n");

await waitFor(
  () => inst.prompts.some((p) => p.includes("check: procevent lavish test-board 1")),
  "fast lane wake prompt delivery to Pi",
);
process.exit(0);
EOF
)
  expect_code 0 "$?" "Pi extension fast-lane ringing: $out"
  pass "Pi primary extension watches fast-lane and delivers wake prompt directly"
}

test_one_wake_per_event_identity() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-dedup-root"
  home="$TMP_ROOT/pi-dedup-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => { prompts.push(message); },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

const fastLaneDir = `${process.env.FM_HOME}/state/fast-lane`;
const ringPayload = {
  version: 1,
  id: "test-board",
  seq: 1,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/test-board.1.result`,
  reason: "check: procevent lavish test-board 1",
};

// 1. Initial ring delivers one prompt
writeFileSync(`${fastLaneDir}/test-board.1.ring.json`, JSON.stringify(ringPayload) + "\n");
await waitFor(() => inst.prompts.length === 1, "first ring delivery");

// 2. Repeat ring while still pending: must create neither pending record nor follow-up
writeFileSync(`${fastLaneDir}/test-board.1.ring.json`, JSON.stringify(ringPayload) + "\n");
await new Promise((resolve) => setTimeout(resolve, 100));
if (inst.prompts.length !== 1) throw new Error(`repeat ring while pending created extra prompt: ${inst.prompts.length}`);

// 3. Consume the wake (session reaches before_agent_start)
await inst.handlers.get("before_agent_start")?.({ messageType: "user", prompt: inst.prompts[0] }, {});

// 4. Repeat ring after delivered: must create neither pending record nor follow-up
writeFileSync(`${fastLaneDir}/test-board.1.ring.json`, JSON.stringify(ringPayload) + "\n");
await new Promise((resolve) => setTimeout(resolve, 100));
if (inst.prompts.length !== 1) throw new Error(`repeat ring after delivered created extra prompt: ${inst.prompts.length}`);

// 5. Mark handled (.handled file written)
writeFileSync(`${process.env.FM_HOME}/state/procevent-inbox/test-board.1.handled`, "\n");

// 6. Repeat ring after handled/acknowledged: must create neither pending record nor follow-up
writeFileSync(`${fastLaneDir}/test-board.1.ring.json`, JSON.stringify(ringPayload) + "\n");
await new Promise((resolve) => setTimeout(resolve, 100));
if (inst.prompts.length !== 1) throw new Error(`repeat ring after handled created extra prompt: ${inst.prompts.length}`);

process.exit(0);
EOF
)
  expect_code 0 "$?" "one wake per event identity: $out"
  pass "one wake per event identity across pending, delivered, and acknowledged states"
}

test_deduplication_never_swallows_real_event() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-real-events-root"
  home="$TMP_ROOT/pi-real-events-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  let streaming = false;
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => {
      prompts.push(message);
    },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts, setStreaming: (s) => { streaming = s; } };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

const fastLaneDir = `${process.env.FM_HOME}/state/fast-lane`;

// Case A: Event arrives and is delivered
const ringPayload1 = {
  version: 1,
  id: "test-board",
  seq: 1,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/test-board.1.result`,
  reason: "check: procevent lavish test-board 1",
};
writeFileSync(`${fastLaneDir}/test-board.1.ring.json`, JSON.stringify(ringPayload1) + "\n");
await waitFor(() => inst.prompts.length === 1, "first event delivery");

// Case B: Mid-turn arrival of distinct second sequence for same source
const ringPayload2 = {
  version: 1,
  id: "test-board",
  seq: 2,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/test-board.2.result`,
  reason: "check: procevent lavish test-board 2",
};
inst.setStreaming(true);
writeFileSync(`${fastLaneDir}/test-board.2.ring.json`, JSON.stringify(ringPayload2) + "\n");
await waitFor(() => inst.prompts.length === 2, "second sequence delivery during streaming");

// Repeat of sequence 2 while streaming must be dropped
writeFileSync(`${fastLaneDir}/test-board.2.ring.json`, JSON.stringify(ringPayload2) + "\n");
await new Promise((resolve) => setTimeout(resolve, 100));
if (inst.prompts.length !== 2) throw new Error("duplicate of sequence 2 was not dropped during streaming");

// Stream ends, message consumed
inst.setStreaming(false);
await inst.handlers.get("message_start")?.({ message: { role: "user", content: [{ type: "text", text: inst.prompts[1] }] } }, {});

// Case C: Distinct source id arrives and is delivered
const ringPayload3 = {
  version: 1,
  id: "other-board",
  seq: 1,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/other-board.1.result`,
  reason: "check: procevent lavish other-board 1",
};
writeFileSync(`${fastLaneDir}/other-board.1.ring.json`, JSON.stringify(ringPayload3) + "\n");
await waitFor(() => inst.prompts.length === 3, "distinct source id delivery");

process.exit(0);
EOF
)
  expect_code 0 "$?" "deduplication never swallows real events: $out"
  pass "deduplication delivers real events and sequences across mid-turn and distinct identities"
}

test_delivered_wake_is_consumed_once() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-duplicate-cost-root"
  home="$TMP_ROOT/pi-duplicate-cost-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => { prompts.push(message); },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

const fastLaneDir = `${process.env.FM_HOME}/state/fast-lane`;
const ringPayload = {
  version: 1,
  id: "test-board",
  seq: 1,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/test-board.1.result`,
  reason: "check: procevent lavish test-board 1",
};
writeFileSync(`${fastLaneDir}/test-board.1.ring.json`, JSON.stringify(ringPayload) + "\n");
await waitFor(() => inst.prompts.length === 1, "the fast-lane wake delivery");
const wakePrompt = inst.prompts[0];

// First presentation: the session consumes the wake (no abort, no answer).
let turn1Aborted = false;
const res1 = await inst.handlers.get("before_agent_start")?.({ messageType: "user", prompt: wakePrompt }, { abort: () => { turn1Aborted = true; } });
if (turn1Aborted) throw new Error("first presentation was unexpectedly aborted");
if (res1?.message) throw new Error("first presentation returned an answer unexpectedly");

// A later arrival of the same text is ordinary input: it is not cancelled.
let turn2Aborted = false;
const res2 = await inst.handlers.get("before_agent_start")?.({ messageType: "user", prompt: wakePrompt }, { abort: () => { turn2Aborted = true; } });
if (turn2Aborted) throw new Error("a later arrival of the delivered wake was aborted");
if (res2?.message) throw new Error("a later arrival of the delivered wake was answered");

// The consumed wake is recorded: the same event is not offered again.
writeFileSync(`${fastLaneDir}/test-board.1.ring.json`, JSON.stringify(ringPayload) + "\n");
await new Promise((resolve) => setTimeout(resolve, 200));
if (inst.prompts.length !== 1) throw new Error(`the consumed event was offered again: ${inst.prompts.length}`);

process.exit(0);
EOF
)
  expect_code 0 "$?" "delivered wake is consumed once: $out"
  pass "a delivered wake is consumed once and a later arrival of the same text is ordinary input"
}

test_captain_paste_of_a_wake_is_ordinary_input() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-paste-root"
  home="$TMP_ROOT/pi-paste-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => { prompts.push(message); },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

const state = `${process.env.FM_HOME}/state`;
const fastLaneDir = `${state}/fast-lane`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

const ring = (id, seq) => ({
  version: 1,
  id,
  seq,
  adapter: "lavish",
  result: `${state}/procevent-inbox/${id}.${seq}.result`,
  reason: `check: procevent lavish ${id} ${seq}`,
});

// An event the session ran, whose handling the agent has not acknowledged.
writeFileSync(`${fastLaneDir}/paste-handled.1.ring.json`, JSON.stringify(ring("paste-handled", 1)) + "\n");
await waitFor(() => inst.prompts.length === 1, "the first wake delivery");
const handledWake = inst.prompts[0];
await inst.handlers.get("before_agent_start")?.({ messageType: "user", prompt: handledWake }, {});

// The captain pastes that wake text: the event is unacknowledged, and the
// paste is ordinary input.
let pasteAborted = false;
const pasteResult = await inst.handlers.get("before_agent_start")?.(
  { messageType: "user", prompt: handledWake },
  { abort: () => { pasteAborted = true; } },
);
if (pasteAborted) throw new Error("a captain paste of a delivered wake was aborted");
if (pasteResult?.message) throw new Error("a captain paste of a delivered wake was answered");

// An event the session has not presented yet: a paste of its wake text must
// not consume it, so a session replacement still carries it.
writeFileSync(`${fastLaneDir}/paste-inflight.1.ring.json`, JSON.stringify(ring("paste-inflight", 1)) + "\n");
await waitFor(() => inst.prompts.length === 2, "the second wake delivery");
const inflightWake = inst.prompts[1];
let inflightAborted = false;
const inflightResult = await inst.handlers.get("before_agent_start")?.(
  { messageType: "user", prompt: `${inflightWake}\n\nplease re-run this` },
  { abort: () => { inflightAborted = true; } },
);
if (inflightAborted) throw new Error("a captain paste of an in-flight wake was aborted");
if (inflightResult?.message) throw new Error("a captain paste of an in-flight wake was answered");

await inst.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "reload" }, {});
const handoff = JSON.parse(readFileSync(`${state}/extensions/pi-primary-watch/session-replacement-actionable.json`, "utf8"));
if (!handoff.pending.some((item) => item.eventIdentity === "paste-inflight:1")) {
  throw new Error(`the captain paste retired the pending wake: ${JSON.stringify(handoff)}`);
}

process.exit(0);
EOF
)
  expect_code 0 "$?" "captain paste of a wake is ordinary input: $out"
  pass "a captain paste of a wake is ordinary input and does not retire the pending wake"
}

test_captain_text_naming_an_event_is_not_an_event() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-captain-text-root"
  home="$TMP_ROOT/pi-captain-text-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => { prompts.push(message); },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

const fastLaneDir = `${process.env.FM_HOME}/state/fast-lane`;

// The captain asks about an event by name in ordinary text.
let aborted = false;
const ctx = { abort: () => { aborted = true; } };
const captainText = "remind me what procevent lavish captain-board 2 said";
const res = await inst.handlers.get("before_agent_start")?.({ messageType: "user", prompt: captainText }, ctx);
if (aborted) throw new Error("a captain message naming an event was aborted");
if (res?.message) throw new Error("a captain message naming an event was answered as a duplicate");
await inst.handlers.get("message_start")?.({ message: { role: "user", content: [{ type: "text", text: captainText }] } }, {});

// The event the captain named is still delivered.
const ringPayload = {
  version: 1,
  id: "captain-board",
  seq: 2,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/captain-board.2.result`,
  reason: "check: procevent lavish captain-board 2",
};
writeFileSync(`${fastLaneDir}/captain-board.2.ring.json`, JSON.stringify(ringPayload) + "\n");
await waitFor(() => inst.prompts.length === 1, "the delivery of the event the captain named");
if (!inst.prompts[0].includes("check: procevent lavish captain-board 2")) {
  throw new Error(`the wrong wake was delivered: ${inst.prompts[0]}`);
}

// The captain pastes the wake line they see in the transcript. Without the
// canonical envelope shape it is captain text, not an event.
const pastedWake = "FIRSTMATE WATCHER WAKE: check: procevent lavish captain-board 2";
let pasteAborted = false;
const pasteResult = await inst.handlers.get("before_agent_start")?.(
  { messageType: "user", prompt: pastedWake },
  { abort: () => { pasteAborted = true; } },
);
if (pasteAborted) throw new Error("a pasted wake line was aborted as a duplicate event");
if (pasteResult?.message) throw new Error("a pasted wake line was answered as a duplicate event");

// The delivered wake for that event must still reach the model.
let wakeAborted = false;
await inst.handlers.get("before_agent_start")?.(
  { messageType: "user", prompt: inst.prompts[0] },
  { abort: () => { wakeAborted = true; } },
);
if (wakeAborted) throw new Error("a pasted wake line retired the pending event wake");

// The captain pastes the full wake text of another event: the encoded
// envelope the extension delivered, and the legacy plain-text shape. Once the
// agent has handled that event its wake line is captain input: not aborted,
// and not answered as a duplicate.
const secondRing = {
  version: 1,
  id: "captain-board-2",
  seq: 3,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/captain-board-2.3.result`,
  reason: "check: procevent lavish captain-board-2 3",
};
writeFileSync(`${fastLaneDir}/captain-board-2.3.ring.json`, JSON.stringify(secondRing) + "\n");
await waitFor(() => inst.prompts.length === 2, "the delivery of the second event");
const deliveredWake = inst.prompts[1];
if (!deliveredWake.includes("check: procevent lavish captain-board-2 3")) {
  throw new Error(`the wrong wake was delivered: ${deliveredWake}`);
}
// The session runs that wake, and the agent handles the event.
await inst.handlers.get("before_agent_start")?.({ messageType: "user", prompt: deliveredWake }, {});
writeFileSync(`${process.env.FM_HOME}/state/procevent-inbox/captain-board-2.3.handled`, "\n");
const pastedWakes = [
  ["encoded envelope", deliveredWake],
  ["legacy plain text", deliveredWake.replace(/^\u2063FIRSTMATE_OP: v1 watcher: /, "")],
];
for (const [label, pasted] of pastedWakes) {
  let fullAborted = false;
  const fullResult = await inst.handlers.get("before_agent_start")?.(
    { messageType: "user", prompt: pasted },
    { abort: () => { fullAborted = true; } },
  );
  if (fullAborted) throw new Error(`a captain paste of the ${label} wake was aborted`);
  if (fullResult?.message) throw new Error(`a captain paste of the ${label} wake was answered as a duplicate`);
}

process.exit(0);
EOF
)
  expect_code 0 "$?" "captain text naming an event is not an event: $out"
  pass "a captain message naming an event is neither swallowed nor treated as a delivered event"
}

test_refused_fast_lane_delivery_keeps_the_ring() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-refused-root"
  home="$TMP_ROOT/pi-refused-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => {
      if (message.includes("lavish refused 1")) throw new Error("pi refused the wake");
      prompts.push(message);
    },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

const fastLaneDir = `${process.env.FM_HOME}/state/fast-lane`;
const refusedRing = `${fastLaneDir}/refused.1.ring.json`;
writeFileSync(refusedRing, JSON.stringify({
  version: 1,
  id: "refused",
  seq: 1,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/refused.1.result`,
  reason: "check: procevent lavish refused 1",
}) + "\n");

// The refused delivery must neither end the process nor drop the ring.
await new Promise((resolve) => setTimeout(resolve, 300));
if (!existsSync(refusedRing)) throw new Error("the refused ring was dropped instead of requeued");
if (inst.prompts.some((p) => p.includes("lavish refused 1"))) {
  throw new Error("a refused wake was delivered anyway");
}

// The extension is still alive and delivers the next event.
writeFileSync(`${fastLaneDir}/after-refusal.1.ring.json`, JSON.stringify({
  version: 1,
  id: "after-refusal",
  seq: 1,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/after-refusal.1.result`,
  reason: "check: procevent lavish after-refusal 1",
}) + "\n");
await waitFor(() => inst.prompts.length === 1, "the delivery after a refused wake");
if (!inst.prompts[0].includes("check: procevent lavish after-refusal 1")) {
  throw new Error(`the wrong wake was delivered: ${inst.prompts[0]}`);
}

process.exit(0);
EOF
)
  expect_code 0 "$?" "refused fast-lane delivery keeps the ring: $out"
  pass "a refused fast-lane delivery neither ends the session nor drops the ring"
}

test_branch_taken_fast_lane_wake_is_settled() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-branch-root"
  home="$TMP_ROOT/pi-branch-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  let offers = 0;
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => { prompts.push(message); },
    events: {
      on() {},
      emit(event, data) {
        if (event === "fm-branch-supervision:dispatch" && data?.accept) {
          offers += 1;
          data.accept();
        }
      },
    },
  };
  return { pi, handlers, prompts, offers: () => offers };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

const fastLaneDir = `${process.env.FM_HOME}/state/fast-lane`;
writeFileSync(`${fastLaneDir}/branch-board.1.ring.json`, JSON.stringify({
  version: 1,
  id: "branch-board",
  seq: 1,
  adapter: "lavish",
  result: `${process.env.FM_HOME}/state/procevent-inbox/branch-board.1.result`,
  reason: "check: procevent lavish branch-board 1",
}) + "\n");

// The branch takes the wake.
await waitFor(() => inst.offers() === 1, "the branch dispatch offer");
if (inst.prompts.length !== 0) throw new Error("the branch took the wake but Pi still received it");

// A session replacement must not replay a wake the branch already handled.
await inst.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "reload" }, {});
const handoff = `${process.env.FM_HOME}/state/extensions/pi-primary-watch/session-replacement-actionable.json`;
if (existsSync(handoff)) throw new Error("a wake the branch handled was persisted for a replacement session");

process.exit(0);
EOF
)
  expect_code 0 "$?" "branch-taken fast-lane wake is settled: $out"
  pass "a fast-lane wake the branch took is settled instead of being offered again"
}

test_in_flight_fast_lane_wake_is_not_offered_again() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-inflight-root"
  home="$TMP_ROOT/pi-inflight-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  let tool = null;
  let offers = 0;
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
    sendUserMessage: async (message) => { prompts.push(message); },
    events: {
      on() {},
      emit(event, data) {
        if (event === "fm-branch-supervision:dispatch" && data?.accept) {
          offers += 1;
          // The branch takes the wake, but its settlement never arrives: the
          // fast-lane delivery stays in flight.
          data.accept(new Promise(() => {}));
        }
      },
    },
  };
  return { pi, handlers, prompts, getTool: () => tool, offers: () => offers };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

writeFileSync(`${state}/fast-lane/inflight.1.ring.json`, JSON.stringify({
  version: 1,
  id: "inflight",
  seq: 1,
  adapter: "lavish",
  result: `${state}/procevent-inbox/inflight.1.result`,
  reason: "check: procevent lavish inflight 1",
}) + "\n");
await waitFor(() => inst.offers() === 1, "the branch dispatch offer");

// An arm cycle must not deliver the wake the branch already holds.
await inst.getTool().execute("arm-inflight", {}, undefined, undefined, {});
await new Promise((resolve) => setTimeout(resolve, 500));
if (inst.offers() !== 1) {
  throw new Error(`the in-flight wake was offered to the branch ${inst.offers()} times`);
}

process.exit(0);
EOF
)
  expect_code 0 "$?" "in-flight fast-lane wake is not offered again: $out"
  pass "a fast-lane wake the branch holds in flight is not offered to it again"
}

test_fast_lane_scan_defers_to_the_replacement_handoff() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-handoff-root"
  home="$TMP_ROOT/pi-handoff-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => { prompts.push(message); },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

const state = `${process.env.FM_HOME}/state`;

// The replacement session already owns this event through the durable handoff.
mkdirSync(`${state}/extensions/pi-primary-watch`, { recursive: true });
writeFileSync(
  `${state}/extensions/pi-primary-watch/session-replacement-actionable.json`,
  JSON.stringify({
    version: 2,
    pending: [{
      version: 1,
      token: "1-2-3",
      message: "check: procevent lavish board-handoff 1",
      predecessorArmPid: "",
      eventIdentity: "board-handoff:1",
    }],
  }),
);

// The ring for the same event is still on disk.
writeFileSync(`${state}/fast-lane/board-handoff.1.ring.json`, JSON.stringify({
  version: 1,
  id: "board-handoff",
  seq: 1,
  adapter: "lavish",
  result: `${state}/procevent-inbox/board-handoff.1.result`,
  reason: "check: procevent lavish board-handoff 1",
}) + "\n");

writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

const wakes = () => inst.prompts.filter((prompt) => prompt.includes("procevent lavish board-handoff 1"));
await waitFor(() => wakes().length >= 1, "the replayed handoff wake");
// The ring for the same event must not produce a second wake.
await new Promise((resolve) => setTimeout(resolve, 300));
if (wakes().length !== 1) {
  throw new Error(`the session received ${wakes().length} wakes for one handoff-owned event`);
}
process.exit(0);
EOF
)
  expect_code 0 "$?" "fast-lane scan defers to the replacement handoff: $out"
  pass "the fast-lane scan defers an event the replacement handoff already owns"
}

test_fast_lane_library_loads_without_the_pane_delivery_path() {
  local root err out
  root="$TMP_ROOT/minimal-root"
  mkdir -p "$root/bin" "$root/state"
  cp "$ROOT/bin/fm-procevent-lib.sh" "$ROOT/bin/fm-pr-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$root/bin/"

  # A deployment that ships this library without the pane delivery path loads
  # it silently, and the doorbell declines instead of failing.
  err=$(bash -c '. "$1/bin/fm-procevent-lib.sh"; echo loaded' _ "$root" 2>&1 >/dev/null)
  [ -z "$err" ] || fail "loading the procevent library without the pane delivery path printed: $err"
  out=$(bash -c '. "$1/bin/fm-procevent-lib.sh"; fm_procevent_ring_doorbell "$2" tmux "fm-sess:0" "check: procevent x 1"' _ "$root" "$root/state" 2>/dev/null)
  [ "$out" = skipped ] || fail "the doorbell did not decline without the pane delivery path: $out"

  pass "the procevent library loads in a deployment without the pane delivery path"
}

test_pi_consumer_delivers_a_ring_a_shell_stamp_did_not_take() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-shell-stamp-root"
  home="$TMP_ROOT/pi-shell-stamp-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => { prompts.push(message); },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts };
}

async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

const state = `${process.env.FM_HOME}/state`;
// The shell stamped the slow lane's surfaced marker for this event, because a
// pane doorbell delivered it. That stamp is not the Pi consumer's own
// delivery record, so the Pi consumer must still deliver its ring.
const hex = Buffer.from("procevent:shell-stamp:1", "utf8").toString("hex");
writeFileSync(`${state}/.seen-procevent-${hex}`, "");
writeFileSync(`${state}/fast-lane/shell-stamp.1.ring.json`, JSON.stringify({
  version: 1,
  id: "shell-stamp",
  seq: 1,
  adapter: "lavish",
  result: `${state}/procevent-inbox/shell-stamp.1.result`,
  reason: "check: procevent lavish shell-stamp 1",
}) + "\n");

writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await waitFor(() => inst.prompts.length === 1, "the ring delivery behind a shell-side surfaced marker");
if (!inst.prompts[0].includes("check: procevent lavish shell-stamp 1")) {
  throw new Error(`the wrong wake was delivered: ${inst.prompts[0]}`);
}
process.exit(0);
EOF
)
  expect_code 0 "$?" "Pi consumer delivers a ring a shell stamp did not take: $out"
  pass "a shell-side surfaced marker does not suppress the Pi consumer's own ring"
}

test_fast_lane_ring_file_is_always_valid_json() {
  local home ring_file out
  home="$TMP_ROOT/quote-home/with\"quote"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  mkdir -p "$home/state/procevent-inbox" "$home/state/fast-lane"
  cat > "$home/state/procevent-inbox/board-json.1.result" <<'EOF'
session:
  file: /json.html
  status: feedback
feedback[1]{prompt,target}:
  "Ring payload feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/board-json.1.adapter"

  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  ring_file="$home/state/fast-lane/board-json.1.ring.json"
  [ -f "$ring_file" ] || fail "the fast lane wrote no ring file: $(ls "$home/state/fast-lane" 2>/dev/null)"
  # The ring file is a machine-consumed artifact: it must parse for the
  # consumer, whatever the home's path looks like.
  out=$(node -e '
    const fs = require("node:fs");
    const ring = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (ring.id !== "board-json" || ring.seq !== 1 || ring.adapter !== "lavish") {
      throw new Error("unexpected ring payload: " + JSON.stringify(ring));
    }
    if (!String(ring.reason || "").includes("procevent lavish board-json 1")) {
      throw new Error("unexpected ring reason: " + JSON.stringify(ring));
    }
  ' "$ring_file" 2>&1) || fail "the fast-lane ring file is not valid JSON: $out"

  pass "the fast-lane ring file is always valid JSON, whatever the home path holds"
}

test_fast_lane_announces_each_event_once() {
  local home state id marker_path out
  home="$TMP_ROOT/announce-once-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox"

  # The pane interaction is the one part a test cannot drive, so the doorbell
  # verdict is supplied; every other step is the production ring path.
  ring_with_verdict() {  # <id> <verdict>
    cat > "$state/procevent-inbox/$1.1.result" <<EOF
session:
  file: /announce.html
  status: feedback
feedback[1]{prompt,target}:
  "Announce once feedback", "#target"
EOF
    printf 'lavish\n' > "$state/procevent-inbox/$1.1.adapter"
    ring_with_stubbed_doorbell "$home" "$state" "$1" "$2" \
      || fail "the ring path failed for $1"
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      fm_wake_append check "procevent:$2:1" "check: procevent lavish $2 1"
    ' _ "$ROOT" "$1"
  }

  # A confirmed pane delivery leaves the slow lane's "already surfaced" record,
  # so the slow lane skips the still-queued key.
  id="ring-delivered"
  ring_with_verdict "$id" delivered
  marker_path="$state/.seen-procevent-$(printf 'procevent:%s:1' "$id" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
  [ -f "$marker_path" ] || fail "a confirmed doorbell delivery left no surfaced marker"
  out="$home/watch-delivered.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true
  assert_not_contains "$(cat "$out")" "procevent:$id:1" \
    "the slow lane announced an event the doorbell already delivered"

  # A skipped pane delivery leaves no record, so the slow lane still delivers.
  id="ring-skipped"
  ring_with_verdict "$id" skipped
  marker_path="$state/.seen-procevent-$(printf 'procevent:%s:1' "$id" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
  [ ! -e "$marker_path" ] || fail "a skipped doorbell delivery left a surfaced marker"
  out="$home/watch-skipped.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true
  assert_contains "$(cat "$out")" "procevent:$id:1" \
    "the slow lane did not deliver an event the doorbell skipped"

  # The Pi consumer and the pane are alternative consumers: one publish that
  # reaches a live Pi consumer does not also ring the pane.
  id="ring-pi-consumer"
  mkdir -p "$state/fast-lane"
  live_consumer_marker "$state"
  rm -f "$state/.doorbell-called"
  ring_with_verdict "$id" delivered
  [ ! -e "$state/.doorbell-called" ] \
    || fail "one publish announced the event through the pane and the Pi consumer"

  pass "the fast lane announces each event once, through exactly one consumer"
}

test_reused_consumer_pid_is_not_a_live_consumer() {
  local home state id live_marker out
  home="$TMP_ROOT/reused-consumer-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox" "$state/fast-lane"

  # A marker that names a live pid with another process's identity: the pid
  # was handed out again, so the consumer that wrote the marker is gone.
  printf '%s\n%s\n' "$$" "linux-starttime=1 cmdline-hex=00" \
    > "$state/fast-lane/.consumer"

  id="reused-consumer"
  cat > "$state/procevent-inbox/$id.1.result" <<EOF
session:
  file: /reused-consumer.html
  status: feedback
feedback[1]{prompt,target}:
  "Reused consumer feedback", "#target"
EOF
  printf 'lavish\n' > "$state/procevent-inbox/$id.1.adapter"

  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  live_marker="$state/.live-procevent-$(printf 'procevent:%s:1' "$id" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
  [ ! -e "$live_marker" ] \
    || fail "a reused consumer pid claimed the event and silenced the slow lane"

  out="$home/watch.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true
  assert_contains "$(cat "$out")" "procevent:$id:1" \
    "the slow lane did not deliver an event whose consumer pid was reused"

  pass "a reused consumer pid does not read as a live consumer"
}

test_ring_log_does_not_claim_a_retirement_it_did_not_perform() {
  local home state id ring_file outcome
  home="$TMP_ROOT/ring-retire-fail-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox" "$state/fast-lane"

  id="retire-failed"
  cat > "$state/procevent-inbox/$id.1.result" <<EOF
session:
  file: /retire-failed.html
  status: feedback
feedback[1]{prompt,target}:
  "Retire failed feedback", "#target"
EOF
  printf 'lavish\n' > "$state/procevent-inbox/$id.1.adapter"

  # The pane takes the event, and the ring directory stops accepting removals,
  # so the consumer's copy cannot be retired.
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    state_dir=$2; event_id=$3
    fm_procevent_ring_doorbell() {
      chmod 500 "$state_dir/fast-lane"
      printf "delivered\n"
    }
    fm_procevent_ring_primary "$state_dir" lavish "$event_id" 1 "$state_dir/procevent-inbox/$event_id.1.result" "check: procevent lavish $event_id 1"
  ' _ "$ROOT" "$state" "$id" || fail "the ring path failed for $id"
  chmod 700 "$state/fast-lane"

  ring_file="$state/fast-lane/$id.1.ring.json"
  [ -f "$ring_file" ] || fail "the consumer's ring file was retired after all"
  outcome=$(awk -F'\t' '$2 == "ring" && $5 == "retire-failed" { c = $8 } END { print c }' \
    "$state/.fast-lane-ring.log")
  [ "$outcome" = written ] \
    || fail "the ring record named the consumer outcome '$outcome' for a retirement that did not happen"

  pass "the ring log records a retirement that did not happen as what it was"
}

# legacy_consumer_marker <state>: the marker shape the build before the
# identity line wrote: the consumer's pid alone.
legacy_consumer_marker() {  # <state>
  printf '%s\n' "$$" > "$1/fast-lane/.consumer"
}

# back_date_marker <path> <epoch>: give a marker the write time a caller asks
# for, so a marker written before a process started can be proven.
back_date_marker() {  # <path> <epoch>
  TZ=UTC touch -t "$(date -u -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$2" +%Y%m%d%H%M.%S)" "$1"
}

# consumer_live <state>: what the shell's liveness check answers for a marker.
consumer_live() {  # <state>
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_fast_lane_consumer_live "$2" && printf "yes\n" || printf "no\n"
  ' _ "$ROOT" "$1"
}

test_legacy_consumer_marker_is_read_as_a_live_consumer() {
  local home state id
  home="$TMP_ROOT/legacy-consumer-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox" "$state/fast-lane"

  # A session from the build before the identity line wrote the pid alone.
  legacy_consumer_marker "$state"
  [ "$(consumer_live "$state")" = yes ] \
    || fail "the shell does not read the previous build's marker as a live consumer"

  # The fast lane therefore leaves the pane alone for that consumer.
  id="legacy-consumer"
  cat > "$state/procevent-inbox/$id.1.result" <<EOF
session:
  file: /legacy-consumer.html
  status: feedback
feedback[1]{prompt,target}:
  "Legacy consumer feedback", "#target"
EOF
  printf 'lavish\n' > "$state/procevent-inbox/$id.1.adapter"
  ring_with_stubbed_doorbell "$home" "$state" "$id" delivered \
    || fail "the ring path failed for $id"
  [ ! -e "$state/.doorbell-called" ] \
    || fail "a live consumer in the previous build's shape was ignored and the pane was rung"

  pass "the previous build's consumer marker is read as a live consumer"
}

# can_prove_process_start: whether this platform lets the shell prove a
# process's start time, which is what tells a reused pid from the process that
# wrote the marker.
can_prove_process_start() {
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_process_start_epoch "$$" >/dev/null 2>&1
  ' _ "$ROOT"
}

test_legacy_consumer_marker_with_a_reused_pid_is_stale() {
  local home state sleeper_pid dead_pid
  home="$TMP_ROOT/legacy-reused-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox" "$state/fast-lane"

  if can_prove_process_start; then
    # A process that started after the marker was written is a different
    # process: the pid was handed out again.
    sleep 30 &
    sleeper_pid=$!
    printf '%s\n' "$sleeper_pid" > "$state/fast-lane/.consumer"
    back_date_marker "$state/fast-lane/.consumer" "$(( $(date +%s) - 60 ))"
    [ "$(consumer_live "$state")" = no ] \
      || fail "a legacy marker whose pid was reused after it was written reads as a live consumer"
    kill -TERM "$sleeper_pid" 2>/dev/null || true
    wait "$sleeper_pid" 2>/dev/null || true
    pass "a legacy consumer marker whose pid was reused reads as stale"
    return 0
  fi

  # Where the platform cannot prove a process's start time, the legacy form
  # rests on liveness: a pid that is not a live process at all still reads as
  # stale, and a reused pid is not distinguishable there.
  dead_pid=2147483647
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  printf '%s\n' "$dead_pid" > "$state/fast-lane/.consumer"
  [ "$(consumer_live "$state")" = no ] \
    || fail "a legacy marker naming a pid that is not a live process reads as a live consumer"
  pass "a legacy consumer marker naming a dead pid reads as stale"
}

# can_read_process_cmdline: whether this platform lets the shell read a
# process's command line, which is how a dead process's zombie is told from
# a live one.
can_read_process_cmdline() {
  local proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  [ -r "$proc_root/$$/stat" ] && [ -r "$proc_root/$$/cmdline" ]
}

test_legacy_consumer_marker_with_a_zombie_is_not_a_consumer() {
  local home state zombie_pid parent_pid
  home="$TMP_ROOT/legacy-zombie-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox" "$state/fast-lane"

  # A consumer that was killed without running its cleanup leaves a zombie
  # behind: the pid is still there and the kernel has not reused it.
  perl -e '
    my $pid = fork();
    if ($pid) {
      open(my $fh, ">", $ARGV[0]) or exit 1;
      print $fh "$pid\n";
      close $fh;
      sleep 30;
    } else {
      exit 0;
    }
  ' "$state/.zombie-pid" >/dev/null 2>&1 &
  parent_pid=$!
  zombie_pid=""
  for _ in $(seq 1 100); do
    zombie_pid=$(cat "$state/.zombie-pid" 2>/dev/null || true)
    [ -n "$zombie_pid" ] && break
    sleep 0.05
  done
  [ -n "$zombie_pid" ] || { kill -TERM "$parent_pid" 2>/dev/null || true; fail "the zombie fixture never recorded its pid"; }
  printf '%s\n' "$zombie_pid" > "$state/fast-lane/.consumer"

  if can_read_process_cmdline; then
    # The zombie has no command line left, so it is not a live process and
    # the legacy form must not treat it as the consumer.
    [ "$(consumer_live "$state")" = no ] \
      || fail "a legacy marker naming a zombie process reads as a live consumer"
    pass "a legacy consumer marker naming a zombie is not a live consumer"
  else
    # Where the platform cannot read a process's command line, the legacy form
    # rests on liveness alone, and a zombie still answers as one.
    [ "$(consumer_live "$state")" = yes ] \
      || fail "the legacy form must rest on liveness where the platform cannot read a command line"
    pass "a legacy consumer marker naming a zombie rests on liveness where the platform cannot read a command line"
  fi

  kill -TERM "$parent_pid" 2>/dev/null || true
  wait "$parent_pid" 2>/dev/null || true
}

test_consumer_marker_forms_are_judged_by_their_own_rule() {
  local home state identity
  home="$TMP_ROOT/marker-forms-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox" "$state/fast-lane"

  identity=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$$")

  # The identity form with the matching identity is live.
  printf '%s\n%s\n' "$$" "$identity" > "$state/fast-lane/.consumer"
  [ "$(consumer_live "$state")" = yes ] \
    || fail "the identity form with a matching identity does not read as a live consumer"

  # The same form with an identity that is not the live process's is stale,
  # and it is never judged by the legacy rule that would accept the pid.
  printf '%s\n%s\n' "$$" "linux-starttime=1 cmdline-hex=00" > "$state/fast-lane/.consumer"
  [ "$(consumer_live "$state")" = no ] \
    || fail "the identity form is judged by the legacy rule when its identity does not match"

  # The legacy form for the same pid is live: the two forms are told apart by
  # what the marker carries, not by which one is newer.
  legacy_consumer_marker "$state"
  [ "$(consumer_live "$state")" = yes ] \
    || fail "the legacy form does not read as a live consumer"

  pass "the two consumer marker forms are judged by their own rule"
}

test_consumer_identity_matches_the_shell_identity() {
  local repo home plugin node_pid marker identity current pid live proc_root
  repo="$TMP_ROOT/pi-identity-root"
  home="$TMP_ROOT/pi-identity-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  write_pi_consumer_script "$home/consumer.mjs"

  # Both rules the shell has: the /proc form, and the portable ps fallback
  # for a host whose /proc the shell cannot read.
  for proc_root in "" "$TMP_ROOT/no-such-proc"; do
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" PROMPTS_FILE="$home/prompts.log" \
      PI_CONSUMER_MODE=inflight FM_PROC_ROOT_OVERRIDE="$proc_root" \
      node "$home/consumer.mjs" >"$home/extension.out" 2>&1 &
    node_pid=$!
    wait_for "$home/state/fast-lane/.consumer" 200 \
      || fail "the Pi consumer never became live: $(cat "$home/extension.out" 2>/dev/null)"

    # The consumer's marker and the shell's identity must be the same string
    # for the same live pid, or the consumer never reads as live.
    marker="$home/state/fast-lane/.consumer"
    pid=$(sed -n '1p' "$marker" | tr -d '[:space:]')
    identity=$(sed -n '2,$p' "$marker" | sed 's/^[[:space:]]*//')
    [ -n "$identity" ] || fail "the consumer marker carries no process identity"
    current=$(FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c \
      '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$pid")
    [ "$identity" = "$current" ] \
      || fail "the consumer's identity '$identity' differs from the shell's '$current'"
    live=$(FM_PROC_ROOT_OVERRIDE="$proc_root" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-procevent-lib.sh"
      fm_procevent_fast_lane_consumer_live "$2" && printf "yes\n" || printf "no\n"
    ' _ "$ROOT" "$home/state")
    [ "$live" = yes ] \
      || fail "the shell's liveness check does not judge the live consumer live"

    kill -TERM "$node_pid" 2>/dev/null || true
    wait "$node_pid" 2>/dev/null || true
    rm -f "$marker"
  done

  pass "the consumer's identity and the shell's are the same string for a live pid"
}

test_fast_lane_doorbell_follows_the_consumer_liveness() {
  local home state id
  home="$TMP_ROOT/doorbell-liveness-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox" "$state/fast-lane"

  make_result() {  # <id>
    cat > "$state/procevent-inbox/$1.1.result" <<EOF
session:
  file: /doorbell.html
  status: feedback
feedback[1]{prompt,target}:
  "Doorbell feedback", "#target"
EOF
    printf 'lavish\n' > "$state/procevent-inbox/$1.1.adapter"
  }

  # No live consumer took the event, so the pane is the fast lane's channel.
  id="no-live-consumer"
  make_result "$id"
  rm -f "$state/.doorbell-called"
  ring_with_stubbed_doorbell "$home" "$state" "$id" delivered \
    || fail "the ring path failed for $id"
  [ -e "$state/.doorbell-called" ] \
    || fail "no live consumer took the event, and the pane was not rung"

  # A live consumer holds the event, so the pane is not rung.
  id="live-consumer"
  make_result "$id"
  live_consumer_marker "$state"
  rm -f "$state/.doorbell-called"
  ring_with_stubbed_doorbell "$home" "$state" "$id" delivered \
    || fail "the ring path failed for $id"
  [ ! -e "$state/.doorbell-called" ] \
    || fail "a live consumer held the event, and the pane was rung anyway"

  pass "the pane is rung when no live consumer took the event"
}

test_confirmed_pane_delivery_retires_the_consumer_ring_file() {
  local home state id ring_file out outcome
  home="$TMP_ROOT/doorbell-retire-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox" "$state/fast-lane"

  id="pane-took-it"
  cat > "$state/procevent-inbox/$id.1.result" <<EOF
session:
  file: /pane-took-it.html
  status: feedback
feedback[1]{prompt,target}:
  "Pane took it feedback", "#target"
EOF
  printf 'lavish\n' > "$state/procevent-inbox/$id.1.adapter"

  # The event is published and queued, and the consumer's copy of the event
  # is on disk.
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  ring_file="$state/fast-lane/$id.1.ring.json"
  [ -f "$ring_file" ] || fail "the fast lane wrote no ring file for the consumer"

  # The pane takes the event: the consumer's copy is retired, so a consumer
  # that comes alive right after finds nothing to announce.
  rm -f "$state/.doorbell-called"
  ring_with_stubbed_doorbell "$home" "$state" "$id" delivered \
    || fail "the ring path failed for $id"
  [ -e "$state/.doorbell-called" ] || fail "the pane was not rung"
  [ ! -e "$ring_file" ] \
    || fail "a confirmed pane delivery left the consumer's ring file in place"
  outcome=$(awk -F'\t' '$2 == "ring" && $5 == "pane-took-it" { c = $8 } END { print c }' \
    "$state/.fast-lane-ring.log")
  [ "$outcome" = retired ] \
    || fail "the ring record named the consumer outcome '$outcome' after the pane took the event"

  # The slow lane does not announce the same identity after the pane took it.
  out="$home/watch.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true
  assert_not_contains "$(cat "$out")" "procevent:$id:1" \
    "the slow lane announced an event the pane already took"

  pass "a confirmed pane delivery retires the consumer's ring file and the slow lane stays off the event"
}

test_suite_never_targets_a_live_pane() {
  local home ring_log outcome
  home="$TMP_ROOT/pane-isolation-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  ring_log="$home/state/.fast-lane-ring.log"
  mkdir -p "$home/state/procevent-inbox"

  # The pinned target must not exist as a pane, so no doorbell in this suite
  # can reach a live session.
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_source tmux || exit 1
    fm_backend_target_exists tmux "$2" && exit 1
    exit 0
  ' _ "$ROOT" "$FM_SUPERVISOR_TARGET" \
    || fail "the suite's supervisor target exists as a live pane"

  # A ring in this suite therefore records a doorbell that reached nobody.
  cat > "$home/state/procevent-inbox/isolated.1.result" <<'EOF'
session:
  file: /isolated.html
  status: feedback
feedback[1]{prompt,target}:
  "Isolated feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/isolated.1.adapter"
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  outcome=$(awk -F'\t' '$2 == "ring" && $5 == "isolated" { print $7 }' "$ring_log")
  [ "$outcome" = skipped ] \
    || fail "a ring in this suite recorded the doorbell outcome '$outcome'"

  pass "no ring in this suite can reach a live pane"
}

test_ring_claim_failure_leaves_the_event_to_the_slow_lane() {
  local home ring_log marker_path key hex
  home="$TMP_ROOT/claim-failure-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  mkdir -p "$home/state/procevent-inbox" "$home/state/fast-lane"
  cat > "$home/state/procevent-inbox/claim-fail.1.result" <<'EOF'
session:
  file: /claim.html
  status: feedback
feedback[1]{prompt,target}:
  "Claim failure feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/claim-fail.1.adapter"

  # The claim marker cannot be recorded: a directory occupies its path.
  key="procevent:claim-fail:1"
  hex=$(printf '%s' "$key" | LC_ALL=C od -An -tx1 | tr -d ' \n')
  marker_path="$home/state/.ring-procevent-$hex"
  mkdir -p "$marker_path"

  ring_log="$home/state/.fast-lane-ring.log"
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  [ ! -f "$ring_log" ] \
    || fail "the fast lane announced an event whose claim was not recorded: $(cat "$ring_log")"
  [ ! -e "$home/state/fast-lane/claim-fail.1.ring.json" ] \
    || fail "the fast lane wrote a ring file without a recorded claim"
  grep -q "procevent:claim-fail:1" "$home/state/.wake-queue" \
    || fail "the event was not queued for the slow lane"

  pass "a fast-lane claim that cannot be recorded leaves the event to the slow lane"
}

test_fast_lane_pane_wake_is_actionable() {
  local home state captured
  home="$TMP_ROOT/pane-wake-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  state="$home/state"
  mkdir -p "$state/procevent-inbox"
  captured="$home/captured.txt"

  # The pane interaction is stubbed; the wake the doorbell builds is the
  # production one.
  CAPTURED="$captured"; export CAPTURED
  FM_HOME="$home" FM_DAEMON_PRIMARY_HARNESS=pi bash -c '
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
    fm_procevent_ring_doorbell "$2" tmux "fm-test-pane" "check: procevent lavish pane-wake 1" >/dev/null
  ' _ "$ROOT" "$state"

  [ -f "$captured" ] || fail "the doorbell typed nothing into the pane"
  grep -q "Run bin/fm-wake-drain.sh first and handle the queued wake." "$captured" \
    || fail "the pane wake carries no drain instruction: $(cat "$captured")"
  grep -q "procevent lavish pane-wake 1" "$captured" \
    || fail "the pane wake names no event: $(cat "$captured")"

  # A harness that strips the invisible marker gets the same wake as a durable
  # record, with the constant doorbell line typed instead.
  rm -f "$captured"
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
    fm_procevent_ring_doorbell "$2" tmux "fm-test-pane" "check: procevent lavish pane-wake 1" >/dev/null
  ' _ "$ROOT" "$state"

  grep -q "Firstmate operational input waiting" "$captured" \
    || fail "a record-needing harness did not get the doorbell line: $(cat "$captured")"
  record=$(find "$state/operational-inbox" -maxdepth 1 -name '*.msg' -print -quit 2>/dev/null)
  [ -n "$record" ] || fail "the record-backed carrier wrote no record"
  grep -q "Run bin/fm-wake-drain.sh first and handle the queued wake." "$record" \
    || fail "the record carries no drain instruction: $(cat "$record")"

  pass "the fast lane's pane wake names the event and carries the drain instruction"
}

test_slow_lane_announcement_retires_the_fast_lane_ring() {
  local home ring_file out
  home="$TMP_ROOT/ring-retire-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  mkdir -p "$home/state/procevent-inbox" "$home/state/fast-lane"
  cat > "$home/state/procevent-inbox/ring-retire.1.result" <<'EOF'
session:
  file: /retire.html
  status: feedback
feedback[1]{prompt,target}:
  "Retire the ring feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/ring-retire.1.adapter"

  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  ring_file="$home/state/fast-lane/ring-retire.1.ring.json"
  [ -f "$ring_file" ] || fail "the fast lane wrote no ring file"

  out="$home/watch.out"
  FM_HOME="$home" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 || true
  assert_contains "$(cat "$out")" "procevent:ring-retire:1" \
    "the slow lane did not announce the event"
  [ ! -e "$ring_file" ] \
    || fail "the slow lane's announcement left the fast lane's ring file in place"

  pass "the slow lane's announcement retires the fast lane's ring file"
}

test_pi_consumer_recognizes_the_slow_lanes_announcement() {
  local repo home plugin out
  repo="$TMP_ROOT/pi-slow-lane-root"
  home="$TMP_ROOT/pi-slow-lane-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$home/state/fast-lane" "$home/state/procevent-inbox"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
while :; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"

  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  const prompts = [];
  const pi = {
    on(event, handler) { handlers.set(event, handler); },
    registerCommand() {},
    registerTool() {},
    sendUserMessage: async (message) => { prompts.push(message); },
    events: { on() {}, emit() {} },
  };
  return { pi, handlers, prompts };
}

const state = `${process.env.FM_HOME}/state`;
// The slow lane already announced this event, in its own colon form.
mkdirSync(`${state}/extensions/pi-primary-watch`, { recursive: true });
writeFileSync(
  `${state}/extensions/pi-primary-watch/session-replacement-actionable.json`,
  JSON.stringify({
    version: 2,
    pending: [{
      version: 1,
      token: "1-2-3",
      message: "check: process-event result captured:procevent:slow-lane:1",
      predecessorArmPid: "",
    }],
  }),
);
// The fast lane's ring for the same event is still on disk.
writeFileSync(`${state}/fast-lane/slow-lane.1.ring.json`, JSON.stringify({
  version: 1,
  id: "slow-lane",
  seq: 1,
  adapter: "lavish",
  reason: "check: procevent lavish slow-lane 1",
}) + "\n");

writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
await new Promise((resolve) => setTimeout(resolve, 400));
const forEvent = inst.prompts.filter((prompt) => prompt.includes("procevent lavish slow-lane 1"));
if (forEvent.length !== 0) {
  throw new Error(`the Pi consumer delivered the fast lane's ring for an event the slow lane announced: ${forEvent.length}`);
}
process.exit(0);
EOF
)
  expect_code 0 "$?" "Pi consumer recognizes the slow lane's announcement: $out"
  pass "the Pi consumer recognizes the slow lane's announcement of the same event"
}

test_ring_log_records_the_doorbell_outcome() {
  local home ring_log outcome consumer
  home="$TMP_ROOT/doorbell-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  ring_log="$home/state/.fast-lane-ring.log"
  mkdir -p "$home/state/procevent-inbox"

  make_result() {  # <id>
    cat > "$home/state/procevent-inbox/$1.1.result" <<EOF
session:
  file: /doorbell.html
  status: feedback
feedback[1]{prompt,target}:
  "Doorbell feedback", "#target"
EOF
    printf 'lavish\n' > "$home/state/procevent-inbox/$1.1.adapter"
  }

  make_result no-pane

  # No supervisor pane resolves in this home: the doorbell is attempted through
  # the canonical resolution and refused, so the ring records no delivery.
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  outcome=$(awk -F'\t' '$2 == "ring" && $5 == "no-pane" { print $7 }' "$ring_log")
  [ "$outcome" = skipped ] \
    || fail "a ring with no supervisor pane recorded the doorbell outcome '$outcome'"

  # A supervisor pane that is gone: the doorbell types nothing, and the ring
  # records that nothing was delivered.
  make_result gone-pane
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
    FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="fm-no-such-session" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  outcome=$(awk -F'\t' '$2 == "ring" && $5 == "gone-pane" { print $7 }' "$ring_log")
  [ "$outcome" = skipped ] \
    || fail "a ring to a gone supervisor pane recorded the doorbell outcome '$outcome'"

  # No Pi consumer in this home either: the ring records that no consumer ring
  # file was written.
  consumer=$(awk -F'\t' '$2 == "ring" && $5 == "gone-pane" { print $8 }' "$ring_log")
  [ "$consumer" = none ] \
    || fail "a ring with no consumer recorded the consumer outcome '$consumer'"

  pass "the ring log records what the supervisor doorbell and the consumer actually did"
}

test_ring_log_records_the_ring_command_channel() {
  local home ring_log hook_out hook_value
  home="$TMP_ROOT/hook-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"
  ring_log="$home/state/.fast-lane-ring.log"
  hook_out="$home/hook.out"
  mkdir -p "$home/state/procevent-inbox"

  make_result() {  # <id>
    cat > "$home/state/procevent-inbox/$1.1.result" <<EOF
session:
  file: /hook.html
  status: feedback
feedback[1]{prompt,target}:
  "Hook feedback", "#target"
EOF
    printf 'lavish\n' > "$home/state/procevent-inbox/$1.1.adapter"
  }

  # No hook command: the record names the channel as not run.
  make_result hook-none
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  hook_value=$(awk -F'\t' '$2 == "ring" && $5 == "hook-none" { print $9 }' "$ring_log")
  [ "$hook_value" = unset ] \
    || fail "a ring without a hook command recorded the hook channel '$hook_value'"

  # A hook command that runs: the record names the channel, and the hook
  # received the event it rings.
  make_result hook-ran
  cat > "$home/hook.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$hook_out"
EOF
  chmod +x "$home/hook.sh"
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" FM_FAST_LANE_RING_COMMAND="$home/hook.sh" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  hook_value=$(awk -F'\t' '$2 == "ring" && $5 == "hook-ran" { print $9 }' "$ring_log")
  [ "$hook_value" = ran ] \
    || fail "a ring with a hook command recorded the hook channel '$hook_value'"
  assert_grep "hook-ran" "$hook_out" "the hook command was not given the event it rings"

  # A hook command that fails: the record names the channel as failed.
  make_result hook-failed
  cat > "$home/hook-fail.sh" <<'SH'
#!/usr/bin/env bash
exit 3
SH
  chmod +x "$home/hook-fail.sh"
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" FM_FAST_LANE_RING_COMMAND="$home/hook-fail.sh" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  hook_value=$(awk -F'\t' '$2 == "ring" && $5 == "hook-failed" { print $9 }' "$ring_log")
  [ "$hook_value" = failed ] \
    || fail "a ring with a failing hook command recorded the hook channel '$hook_value'"

  pass "the ring log names the ring command channel and what it did"
}

test_stop_repetition_at_source() {
  local home ring_log count
  home="$TMP_ROOT/stop-repetition-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"

  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/burst.1.result" <<'EOF'
session:
  file: /burst.html
  status: feedback
feedback[1]{prompt,target}:
  "Burst feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/burst.1.adapter"
  ring_log="$home/state/.fast-lane-ring.log"

  # Run reconcile 17 times in rapid succession
  for _ in $(seq 1 17); do
    FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
      "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  done

  count=$(wc -l < "$ring_log" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "burst of 17 reconciles produced $count rings instead of 1"

  # A later reconcile keeps the event to its one ring: the durable queue row
  # stays the at-least-once authority, the fast lane announces it once.
  sleep 1.1
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  count=$(wc -l < "$ring_log" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "a later reconcile re-ringed the same event ($count rings)"

  pass "repetition stopped at source (17 rapid reconciles yield 1 ring, later reconciles do not re-ring)"
}

test_lost_ring_rescued_by_slow_lane() {
  local home drain_out key hex marker_path
  home="$TMP_ROOT/lost-ring-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"

  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/lost.1.result" <<'EOF'
session:
  file: /lost.html
  status: feedback
feedback[1]{prompt,target}:
  "Lost review feedback", "#target"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/lost.1.adapter"

  # Capture and reconcile (rings fast lane, but session does not receive it)
  FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  # Assert 1: The surfaced marker was NOT stamped at ring time
  key="procevent:lost:1"
  hex=$(printf '%s' "$key" | LC_ALL=C od -An -tx1 | tr -d ' \n')
  marker_path="$home/state/.seen-procevent-$hex"
  [ ! -e "$marker_path" ] || fail "surfaced marker was prematurely stamped at ring time"

  # Assert 2: Slow-lane drain finds and surfaces the lost event
  drain_out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_contains "$drain_out" "procevent lavish lost 1" \
    "slow lane failed to rescue lost event"

  pass "lost fast-lane ring is rescued by slow lane because surfaced marker was not stamped at ring time"
}

test_fast_lane_delivered_without_slow_lane_sweep
test_fast_lane_writes_no_ring_without_a_consumer
test_handled_event_is_not_surfaced_again
test_fast_lane_down_session_recovery
test_slow_lane_still_finds_slow_events_and_slow_pass_does_not_delay_fast_lane
test_structured_consumption_strips_dom_snapshot_and_instructions
test_pi_extension_fast_lane_ringing
test_one_wake_per_event_identity
test_deduplication_never_swallows_real_event
test_delivered_wake_is_consumed_once
test_captain_paste_of_a_wake_is_ordinary_input
test_captain_text_naming_an_event_is_not_an_event
test_branch_taken_fast_lane_wake_is_settled
test_refused_fast_lane_delivery_keeps_the_ring
test_ring_log_records_the_doorbell_outcome
test_ring_log_records_the_ring_command_channel
test_fast_lane_pane_wake_is_actionable
test_slow_lane_announcement_retires_the_fast_lane_ring
test_pi_consumer_recognizes_the_slow_lanes_announcement
test_ring_claim_failure_leaves_the_event_to_the_slow_lane
test_fast_lane_announces_each_event_once
test_fast_lane_doorbell_follows_the_consumer_liveness
test_consumer_identity_matches_the_shell_identity
test_legacy_consumer_marker_is_read_as_a_live_consumer
test_legacy_consumer_marker_with_a_reused_pid_is_stale
test_legacy_consumer_marker_with_a_zombie_is_not_a_consumer
test_consumer_marker_forms_are_judged_by_their_own_rule
test_reused_consumer_pid_is_not_a_live_consumer
test_ring_log_does_not_claim_a_retirement_it_did_not_perform
test_confirmed_pane_delivery_retires_the_consumer_ring_file
test_suite_never_targets_a_live_pane
test_fast_lane_ring_file_is_always_valid_json
test_pi_consumer_delivers_a_ring_a_shell_stamp_did_not_take
test_fast_lane_scan_defers_to_the_replacement_handoff
test_in_flight_fast_lane_wake_is_not_offered_again
test_fast_lane_library_loads_without_the_pane_delivery_path
test_stop_repetition_at_source
test_lost_ring_rescued_by_slow_lane
test_pi_home_announces_one_event_once
test_slow_lane_delivers_an_event_the_fast_lane_did_not
test_stale_consumer_marker_leaves_the_event_to_the_slow_lane
test_fast_lane_ring_log_keeps_only_complete_records

printf '\nall transport lane tests passed\n'
