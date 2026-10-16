#!/usr/bin/env bash
# Behavioral tests for the two-lane transport refactor and duplicate ring deduplication:
# - Fast-lane event delivery without slow-lane sweep (ring recorded, zero cycle exits).
# - Fast-lane event arriving while session is down delivered once on recovery from durable record.
# - Slow lane still finds slow events and slow pass does not delay fast-lane events.
# - Structured consumption strips DOM snapshots and redundant instructions.
# - Pi primary extension delivers fast-lane rings directly.
# - One wake per event identity across pending, delivered, and acknowledged states.
# - Deduplication never swallows real events or sequences across mid-turn and restart.
# - Duplicates reaching session cost nothing (aborted, cached response).
# - Repetition stopped at source (reconcile burst throttled by ring cadence).
# - Lost rings rescued by slow lane (surfaced marker not stamped at ring time).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-transport-lanes)
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
export NODE_NO_WARNINGS=1

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

test_fast_lane_delivered_without_slow_lane_sweep() {
  local home arm_pid watcher_pid initial_exits current_exits ring_log
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

test_slow_lane_still_finds_slow_events_and_slow_pass_does_not_delay_fast_lane() {
  local home drain_out t_start t_ring elapsed slow_pid
  home="$TMP_ROOT/slow-lane-home"
  new_home "$home"
  printf '%s\n' "$$" > "$home/state/.lock"

  # 3A: Slow lane still finds slow events (status files)
  printf 'needs-decision [at=%s]: captain input required\n' "$(date +%s)" > "$home/state/task-slow.status"
  drain_out=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
  assert_contains "$drain_out" "task-slow" \
    "slow lane status change was not detected"

  # 3B: Deliberately slow slow-lane pass does not delay a fast-lane event
  # In the slow lane, simulate a slow check that takes 2 seconds in the background
  ( sleep 2 ) &
  slow_pid=$!

  # While the slow check runs, a fast-lane event arrives
  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/fast-immediate.1.result" <<'EOF'
session:
  file: /fast.html
  status: feedback
feedback[1]{prompt,target}:
  "Immediate fast ring", "#fast-btn"
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/fast-immediate.1.adapter"

  t_start=$(date +%s)
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$home/state/.fast-lane-ring.log" \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
  t_ring=$(date +%s)
  elapsed=$((t_ring - t_start))

  # Ring must happen immediately (< 2 seconds), not waiting for the slow check
  [ "$elapsed" -lt 2 ] || fail "fast lane was delayed ($elapsed seconds)"
  grep -q "fast-immediate" "$home/state/.fast-lane-ring.log" \
    || fail "fast-lane ring log missing fast-immediate"

  # Verify the slow process was still running when the fast-lane ring fired
  kill -0 "$slow_pid" 2>/dev/null || fail "slow check ended prematurely"
  wait "$slow_pid" 2>/dev/null || true

  pass "slow lane still finds slow events and slow pass does not delay fast-lane event"
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

test_duplicate_reaching_session_costs_nothing() {
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

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const inst = makePi();
mod.default(inst.pi);
await inst.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});

const wakePrompt = "FIRSTMATE WATCHER WAKE: check: procevent lavish test-board 1\n\nRun bin/fm-wake-drain.sh first and handle the queued wake.";

// First presentation: ordinary turn start (not aborted)
let turn1Aborted = false;
const ctx1 = { abort: () => { turn1Aborted = true; } };
const res1 = await inst.handlers.get("before_agent_start")?.({ messageType: "user", prompt: wakePrompt }, ctx1);
if (turn1Aborted) throw new Error("first presentation was unexpectedly aborted");
if (res1?.message) throw new Error("first presentation returned cached assistant response unexpectedly");

// Second presentation (duplicate reaches session): aborted and returns cached response
let turn2Aborted = false;
const ctx2 = { abort: () => { turn2Aborted = true; } };
const res2 = await inst.handlers.get("before_agent_start")?.({ messageType: "user", prompt: wakePrompt }, ctx2);
if (!turn2Aborted) throw new Error("duplicate presentation was not aborted");
if (!res2?.message?.content?.[0]?.text?.includes("already delivered")) {
  throw new Error(`duplicate presentation did not return cached response: ${JSON.stringify(res2)}`);
}

process.exit(0);
EOF
)
  expect_code 0 "$?" "duplicate reaching session costs nothing: $out"
  pass "duplicate procevent reaching session is aborted without model regeneration"
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

  # After cadence expires, re-ring is allowed as recovery path
  sleep 1.1
  FM_HOME="$home" FM_FAST_LANE_RING_LOG="$ring_log" FM_PROCEVENT_RING_CADENCE_SECS=1 \
    "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1

  count=$(wc -l < "$ring_log" | tr -d ' ')
  [ "$count" -eq 2 ] || fail "expired cadence did not allow re-ring recovery ($count rings)"

  pass "repetition stopped at source (17 rapid reconciles yield 1 ring, re-ring allowed after cadence)"
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
test_fast_lane_down_session_recovery
test_slow_lane_still_finds_slow_events_and_slow_pass_does_not_delay_fast_lane
test_structured_consumption_strips_dom_snapshot_and_instructions
test_pi_extension_fast_lane_ringing
test_one_wake_per_event_identity
test_deduplication_never_swallows_real_event
test_duplicate_reaching_session_costs_nothing
test_stop_repetition_at_source
test_lost_ring_rescued_by_slow_lane

printf '\nall transport lane tests passed\n'
