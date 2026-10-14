#!/usr/bin/env bash
# Behavior tests for Firstmate's model-delay pacing mode: the skill that owns the
# pacing rule, the free-model scope that rule applies to, the config/model-delay
# preference and its /model-delay toggle, and the sandglass indicator drawn beside
# the Calm working boat on Pi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-model-delay)
SKILL="$ROOT/.agents/skills/model-delay/SKILL.md"
DOC="$ROOT/docs/model-delay.md"
CONFIG_DOC="$ROOT/docs/configuration.md"
EXT="$ROOT/.pi/extensions/fm-calm.ts"
ASSISTANT_LAYOUT="$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
PRESERVATION="$ROOT/.pi/extensions/lib/fm-calm-preservation.ts"
OPERATIONAL_USER_LAYOUT="$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
PENDING_OPERATIONAL_LAYOUT="$ROOT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts"
VISIBILITY="$ROOT/.pi/extensions/lib/fm-calm-visibility.ts"
WORKING_SHIP="$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts"
WORKING_SHIP_SPRITE="$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts"
PI_OPERATIONAL_INPUT="$ROOT/.pi/extensions/lib/fm-operational-input.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

# The skill is the one owner of the pacing rule: its always-loaded description must
# carry the load trigger, and its body must name the fixed interval and the free-model
# scope. The launch brief only points at it, so neither may need to appear a second
# time.
test_model_delay_skill_contract() {
  [ -f "$SKILL" ] || fail "model-delay skill is missing at $SKILL"
  assert_grep "name: model-delay" "$SKILL" "model-delay skill has no name frontmatter"
  assert_grep "description:" "$SKILL" "model-delay skill has no description frontmatter"
  assert_grep "Load when" "$SKILL" "model-delay skill description states no load trigger"
  assert_grep "model-delay on" "$SKILL" "model-delay skill trigger does not name its on state"
  assert_grep "45 seconds between model turns" "$SKILL" \
    "model-delay skill does not fix the pacing interval"
  assert_grep "bin/fm-model-delay.sh 45" "$SKILL" \
    "model-delay skill does not point at the harness-agnostic wait helper"
  # The scope is part of the pacing rule, so the skill must state which callers
  # pace and how a caller tells. The firstmate on a paid model reads this skill
  # and must not pace.
  assert_grep "-free" "$SKILL" "model-delay skill does not name the free-model suffix"
  assert_grep "FM_MODEL_DELAY_MODEL" "$SKILL" \
    "model-delay skill does not name the variable that carries the caller's model"
  assert_grep "bin/fm-free-model-lib.sh" "$SKILL" \
    "model-delay skill does not point at the free-model rule owner"
  pass "model-delay skill exists and its trigger, interval, free-model scope, and helper are stated"
}

# The mode must be discoverable where Calm is documented, and the preference contract
# must be routed to its own owner rather than duplicated in the skill.
test_model_delay_documentation_contract() {
  [ -f "$DOC" ] || fail "model-delay documentation is missing at $DOC"
  assert_grep "config/model-delay" "$DOC" "model-delay page does not name the preference"
  assert_grep "../.agents/skills/model-delay/SKILL.md" "$DOC" "model-delay page does not point at the skill owner"
  assert_grep "bin/fm-model-delay.sh" "$DOC" "model-delay page does not point at the wait helper"
  assert_grep "bin/fm-free-model-lib.sh" "$DOC" "model-delay page does not point at the free-model rule owner"
  assert_grep "FM_MODEL_DELAY_MODEL" "$DOC" "model-delay page does not name the variable that carries the caller's model"
  assert_grep "-free" "$DOC" "model-delay page does not state the free-model scope"
  assert_grep "## Token cost" "$DOC" "model-delay page does not document the waiting call's token cost"
  assert_grep "## Model-delay preference (config/model-delay)" "$CONFIG_DOC" \
    "configuration.md has no model-delay preference section"
  assert_grep "model-delay.md" "$CONFIG_DOC" "configuration.md does not link the model-delay page"
  assert_grep "model-delay.md" "$ROOT/docs/calm.md" "calm.md does not link its model-delay sibling"
  pass "model-delay is documented with the preference owned by configuration.md"
}

# The free-model rule is the one owner of which callers pace, and it is shared by
# the helper's gate and the launch-brief section, so an id ending in -free is the
# only free verdict and everything else - a paid id, an unknown id, no id at all -
# is not.
test_free_model_rule_contract() {
  local lib
  lib="$ROOT/bin/fm-free-model-lib.sh"
  [ -f "$lib" ] || fail "the free-model rule lib is missing at $lib"
  # shellcheck source=bin/fm-free-model-lib.sh
  . "$lib"
  fm_model_is_free "opencode-go/step-5-preview-free" \
    || fail "a model id ending in -free was not classified free"
  fm_model_is_free "step-5-preview-free" \
    || fail "a bare free model id was not classified free"
  for model in "some-paid-model" "opus-4.1" "-freeish" "" "free"; do
    if fm_model_is_free "$model"; then
      fail "model '$model' was classified free"
    fi
  done
  pass "the free-model rule classifies exactly the -free suffix as free"
}

# The helper owns the wait: it gates on config/model-delay, blocks in the foreground for
# exactly the interval it is given, and launches neither a background process nor a
# timeout wrapper. A fake timeout on PATH proves the last point behaviorally, and the
# elapsed bound proves the wait was not backgrounded. It spends that wait only on a
# caller whose model is free, so the same matrix must be proven for a free, a paid, and
# an unnamed model.
test_model_delay_helper_contract() {
  local helper dir fakebin start end out rc
  helper="$ROOT/bin/fm-model-delay.sh"
  [ -x "$helper" ] || fail "model-delay helper is missing or not executable at $helper"
  dir="$TMP_ROOT/helper-config"
  fakebin="$TMP_ROOT/helper-fakebin"
  mkdir -p "$dir" "$fakebin"
  cat >"$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
printf 'timeout invoked\n' >>"$FM_MODEL_DELAY_TIMEOUT_LOG"
exit 99
SH
  chmod +x "$fakebin/timeout"

  # Absent and off are inert: immediate, silent, success.
  start=$(date +%s)
  out=$(PATH="$fakebin:$PATH" bash "$helper" 5 "$dir")
  rc=$?
  end=$(date +%s)
  [ "$rc" -eq 0 ] || fail "model-delay helper with no preference exited $rc"
  [ -z "$out" ] || fail "model-delay helper with no preference printed: $out"
  [ "$((end - start))" -lt 2 ] || fail "model-delay helper waited for a mode that was not on"

  printf 'off\n' >"$dir/model-delay"
  out=$(PATH="$fakebin:$PATH" bash "$helper" 5 "$dir")
  rc=$?
  [ "$rc" -eq 0 ] || fail "model-delay helper with the preference off exited $rc"
  [ -z "$out" ] || fail "model-delay helper with the preference off printed: $out"

  # On and free: it blocks in the foreground for the interval, prints one short
  # line, and launches no timeout. A backgrounded wait would return fast, so the
  # elapsed bound is the behavioral proof that nothing was backgrounded.
  printf 'on\n' >"$dir/model-delay"
  start=$(date +%s)
  out=$(FM_MODEL_DELAY_MODEL=opencode-go/step-5-preview-free \
    FM_MODEL_DELAY_TIMEOUT_LOG="$TMP_ROOT/helper-timeout.log" PATH="$fakebin:$PATH" \
    bash "$helper" 2 "$dir")
  rc=$?
  end=$(date +%s)
  [ "$rc" -eq 0 ] || fail "model-delay helper with the preference on exited $rc"
  [ "$((end - start))" -ge 2 ] || fail "model-delay helper returned before its interval elapsed"
  case "$out" in
    *model-delay*paced*2s*) ;;
    *) fail "model-delay helper printed an unexpected line: $out" ;;
  esac
  [ ! -s "$TMP_ROOT/helper-timeout.log" ] || fail "model-delay helper launched a timeout wrapper"

  # On and paid, and on with no model named: no wait at all, because a paid
  # fallback endpoint does not share the free endpoint's concurrency refusals.
  # The skip line is the plain statement of what it did.
  start=$(date +%s)
  out=$(FM_MODEL_DELAY_MODEL=some-paid-model PATH="$fakebin:$PATH" bash "$helper" 30 "$dir")
  rc=$?
  end=$(date +%s)
  [ "$rc" -eq 0 ] || fail "model-delay helper on a paid model exited $rc"
  [ "$((end - start))" -lt 5 ] || fail "model-delay helper waited for a paid model"
  case "$out" in
    *skipped*) ;;
    *) fail "model-delay helper on a paid model printed an unexpected line: $out" ;;
  esac

  out=$(env -u FM_MODEL_DELAY_MODEL PATH="$fakebin:$PATH" bash "$helper" 30 "$dir")
  rc=$?
  [ "$rc" -eq 0 ] || fail "model-delay helper with no model named exited $rc"
  case "$out" in
    *skipped*) ;;
    *) fail "model-delay helper with no model named printed an unexpected line: $out" ;;
  esac

  # A missing or invalid interval is refused, never silently defaulted, because the
  # skill is the only owner of the interval.
  bash "$helper" >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "model-delay helper accepted a missing interval"
  bash "$helper" 0 "$dir" >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "model-delay helper accepted a zero interval"
  bash "$helper" abc "$dir" >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "model-delay helper accepted a non-numeric interval"
  pass "model-delay helper is inert while off and for a paid or unnamed model, waits only for a free model, prints one line, launches no timeout, and refuses a missing interval"
}

# Load the real extension against a fake Pi and assert the sandglass appears only while
# the preference is on, joins the Calm boat when both modes are on, and that /model-delay
# persists the choice and repaints the working row.
test_pi_model_delay_indicator_and_toggle() {
  local fixture out status version
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for the Pi model-delay indicator test"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi
  version=$(node -p "require('$PI_PACKAGE_DIR/package.json').version" 2>/dev/null || printf 'unknown')

  fixture="$TMP_ROOT/pi-indicator"
  mkdir -p "$fixture/project/.pi/extensions/lib" "$fixture/project/node_modules/@earendil-works" "$fixture/home/config"
  cp "$EXT" "$fixture/project/.pi/extensions/fm-calm.ts"
  cp "$ASSISTANT_LAYOUT" "$fixture/project/.pi/extensions/lib/fm-calm-assistant-layout.ts"
  cp "$PRESERVATION" "$fixture/project/.pi/extensions/lib/fm-calm-preservation.ts"
  cp "$OPERATIONAL_USER_LAYOUT" "$fixture/project/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
  cp "$PENDING_OPERATIONAL_LAYOUT" "$fixture/project/.pi/extensions/lib/fm-calm-pending-operational-layout.ts"
  cp "$VISIBILITY" "$fixture/project/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$WORKING_SHIP" "$fixture/project/.pi/extensions/lib/fm-calm-working-ship.ts"
  cp "$WORKING_SHIP_SPRITE" "$fixture/project/.pi/extensions/lib/fm-calm-working-ship-sprite.ts"
  cp "$PI_OPERATIONAL_INPUT" "$fixture/project/.pi/extensions/lib/fm-operational-input.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/project/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$fixture/project/node_modules/@earendil-works/pi-tui"
  ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$fixture/project/node_modules/typebox"
  printf '%s\n' '{"type":"module"}' >"$fixture/project/package.json"

  out=$(cd "$fixture/project" && \
    EXT="$fixture/project/.pi/extensions/fm-calm.ts" \
    FM_HOME="$fixture/home" \
    PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
    node --input-type=module 2>&1 <<'JS'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { CALM_WORKING_SHIP_WIDGET_KEY } = await import(
  `${pathToFileURL(`${process.cwd()}/.pi/extensions/lib/fm-calm-working-ship.ts`).href}?widget=${Date.now()}`
);
const SANDGLASS = "\u29d7";
const HULL = "\u2572\u2581\u2581\u2581\u2571";

const handlers = new Map();
let calmCommand;
let modelDelayCommand;
const pi = {
  events: { emit() {}, on() {} },
  on(event, handler) {
    const existing = handlers.get(event) ?? [];
    existing.push(handler);
    handlers.set(event, existing);
  },
  registerCommand(name, command) {
    if (name === "calm") calmCommand = command;
    if (name === "model-delay") modelDelayCommand = command;
  },
  registerEntryRenderer() {},
  registerTool() {},
  getAllTools() {
    return [];
  },
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?modelDelay=${Date.now()}`);
extension.default(pi);
if (!modelDelayCommand) throw new Error("the extension did not register /model-delay");

const tui = { requestRender() {} };
const ui = {
  workingVisible: [],
  widgets: new Map(),
  setWorkingVisible(visible) {
    this.workingVisible.push(visible);
  },
  setWidget(key, content) {
    const existing = this.widgets.get(key);
    if (existing?.dispose) existing.dispose();
    this.widgets.delete(key);
    if (content === undefined) return;
    this.widgets.set(key, typeof content === "function" ? content(tui, {}) : content);
  },
  getEditorText: () => "",
  getToolsExpanded: () => false,
  onTerminalInput: () => () => {},
  setHiddenThinkingLabel() {},
  setStatus() {},
  setToolsExpanded() {},
  notify() {},
};
const ctx = { ui };
const fire = async (event, payload = {}) => {
  for (const handler of handlers.get(event) ?? []) await handler(payload, ctx);
};
const widget = () => ui.widgets.get(CALM_WORKING_SHIP_WIDGET_KEY);
const preference = () => {
  try {
    return readFileSync(`${process.env.FM_HOME}/config/model-delay`, "utf8").trim();
  } catch {
    return "";
  }
};

const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};
const visibleWidth = (row) => row.replace(/\x1b\[[0-9;]*m/g, "").length;

// A session that starts with the preference absent leaves the stock working row alone.
await fire("session_start", { reason: "startup" });
ui.workingVisible.length = 0;
await fire("agent_start");
assert(ui.widgets.size === 0, "a model-delay-off, calm-off run installed a working widget");
assert(ui.workingVisible.length === 0, "a model-delay-off, calm-off run touched the stock working row");

// Turning model-delay on during the run persists the choice and shows the sandglass.
await modelDelayCommand.handler("", ctx);
assert(preference() === "on", `/model-delay did not persist "on" (saw "${preference()}")`);
const sandglassWidget = widget();
assert(!!sandglassWidget, "model-delay on did not install a working widget");
assert(ui.workingVisible[ui.workingVisible.length - 1] === false, "model-delay on did not hide the stock working row");
const sandglassRows = sandglassWidget.render(40);
assert(sandglassRows.length === 1, `a sandglass-only widget rendered ${sandglassRows.length} rows`);
assert(sandglassRows[0].includes(SANDGLASS), "the model-delay widget rendered no sandglass");
assert(!sandglassRows[0].includes(HULL), "the sandglass-only widget rendered the boat without Calm");

// Calm on top of model-delay shows the boat with the sandglass beside it in one widget.
await calmCommand.handler("", ctx);
const bothWidget = widget();
assert(bothWidget === sandglassWidget, "turning Calm on replaced the shared working widget");
const bothRows = bothWidget.render(40);
assert(bothRows.length === 2, `Calm plus model-delay rendered ${bothRows.length} rows instead of two`);
assert(bothRows[1].includes(HULL), "Calm plus model-delay lost the boat");
assert(bothRows[1].includes(SANDGLASS), "Calm plus model-delay lost the sandglass");
assert(
  visibleWidth(bothRows[bothRows.length - 1]) === 40,
  `the combined boat row was not full width: ${visibleWidth(bothRows[bothRows.length - 1])}`,
);

// Turning model-delay off drops the sandglass but, with Calm still on, keeps the boat.
await modelDelayCommand.handler("", ctx);
assert(preference() === "off", `/model-delay did not persist "off" (saw "${preference()}")`);
const boatOnly = widget();
assert(!!boatOnly, "turning model-delay off with Calm on cleared the working widget");
const boatRows = boatOnly.render(40);
assert(boatRows.length === 2, "Calm-only rendering changed row count");
assert(!boatRows[1].includes(SANDGLASS), "turning model-delay off kept the sandglass");
assert(boatRows[1].includes(HULL), "turning model-delay off removed the Calm boat");

// A fresh session reloads the persisted preference: on shows the indicator again.
await modelDelayCommand.handler("", ctx);
await fire("session_start", { reason: "new" });
await fire("agent_start");
const reloaded = widget();
assert(!!reloaded, "a persisted model-delay=on session installed no working widget");
const reloadedRows = reloaded.render(40);
assert(reloadedRows.length === 2, `a reloaded Calm plus model-delay session rendered ${reloadedRows.length} rows`);
assert(reloadedRows[1].includes(SANDGLASS), "a reloaded model-delay=on session lost the sandglass");
await fire("agent_settled");
assert(ui.widgets.size === 0, "settling left a residual working widget");
assert(ui.workingVisible[ui.workingVisible.length - 1] === true, "settling did not restore the stock working row");
JS
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi model-delay indicator test failed: $out"
  [ -z "$out" ] || fail "Pi model-delay indicator test printed output: $out"
  pass "Pi shows exactly one working widget: sandglass alone while model-delay is on, boat plus sandglass with Calm, boat alone after model-delay off, and reloads the persisted choice (Pi $version)"
}

test_model_delay_skill_contract
test_model_delay_documentation_contract
test_free_model_rule_contract
test_model_delay_helper_contract
test_pi_model_delay_indicator_and_toggle

echo "# all fm-model-delay tests passed"
