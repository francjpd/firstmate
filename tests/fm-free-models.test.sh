#!/usr/bin/env bash
# Behavior tests for the validate-free-models surface: the deterministic script
# (fetch/status/save/picks), its probe classification, the cheap re-run contract,
# and the manual skill's procedure contract.
#
# The suite never touches the network or the captain's live keys. A fake curl on
# PATH maps the three endpoints to fixture files under a stub directory, and a
# stubbed auth.json stands in for the credential store. Every probe the script
# makes is logged to <stub>/call.log so a test can assert exactly which calls a
# run made.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-free-models)
HELPER="$ROOT/bin/fm-free-models.sh"
SKILL="$ROOT/.agents/skills/validate-free-models/SKILL.md"
DOC="$ROOT/docs/free-models.md"
CONFIG_DOC="$ROOT/docs/configuration.md"

ALIVE_BODY='{"id":"chatcmpl-stub","object":"chat.completion","model":"MODEL","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content:"OK."}}]}'

# fm_free_models_stub <stub-dir> - the fixture world: a stubbed credential
# store, the three model lists, and a probe fixture per candidate. The OpenCode
# Go catalog deliberately advertises space-bunny-free, which the probe answers
# with "Model is unavailable", so the drop path is exercised exactly as the live
# service behaves.
fm_free_models_stub() {
  local stub=$1
  mkdir -p "$stub/list" "$stub/probe/go" "$stub/probe/openrouter/liquid" \
    "$stub/probe/openrouter/nvidia" \
    "$stub/probe/openrouter/google" "$stub/probe/openrouter/poolside" \
    "$stub/home/data" "$stub/fakebin"
  cat >"$stub/home/auth.json" <<'JSON'
{"opencode-go":{"type":"api_key","key":"go-key-stub"},"openrouter":{"type":"api_key","key":"or-key-stub"}}
JSON
  cat >"$stub/list/go.body" <<'JSON'
{"object":"model","data":[{"id":"cat-jam-free"},{"id":"step-5-preview-free"},{"id":"longcat-2.5-preview-free"},{"id":"space-bunny-free"},{"id":"grok-4.7"}]}
JSON
  cat >"$stub/list/openrouter.body" <<'JSON'
{"data":[{"id":"liquid/lfm-2.5-2.6b:free","pricing":{"prompt":"0","completion":"0"}},{"id":"nvidia/nemotron-3-ultra-550b-a55b:free","pricing":{"prompt":"0","completion":"0"}},{"id":"google/lyria-3-clip-preview","pricing":{"prompt":"0","completion":"0"}}]}
JSON
  cat >"$stub/list/ollama.body" <<'JSON'
{"data":[{"id":"gpt-oss:120b"},{"id":"glm-5.3"}]}
JSON
  # OpenCode Go probes: three alive, one dead on the service's own words.
  printf '%s\n' "${ALIVE_BODY//MODEL/cat-jam-free}" >"$stub/probe/go/cat-jam-free.body"
  printf '%s\n' "${ALIVE_BODY//MODEL/step-5-preview-free}" >"$stub/probe/go/step-5-preview-free.body"
  printf '%s\n' "${ALIVE_BODY//MODEL/longcat-2.5-preview-free}" >"$stub/probe/go/longcat-2.5-preview-free.body"
  printf '%s\n' '{"type":"error","error":{"type":"ModelUnavailable","message":"Model is unavailable"}}' \
    >"$stub/probe/go/space-bunny-free.body"
  printf '400\n' >"$stub/probe/go/space-bunny-free.status"
  # OpenRouter probes: two alive, one the provider positively rejects.
  printf '%s\n' "${ALIVE_BODY//MODEL/liquid/lfm-2.5-2.6b:free}" \
    >"$stub/probe/openrouter/liquid/lfm-2.5-2.6b:free.body"
  printf '%s\n' "${ALIVE_BODY//MODEL/nvidia/nemotron-3-ultra-550b-a55b:free}" \
    >"$stub/probe/openrouter/nvidia/nemotron-3-ultra-550b-a55b:free.body"
  printf '%s\n' '{"error":{"message":"Provider returned error","code":400}}' \
    >"$stub/probe/openrouter/google/lyria-3-clip-preview.body"
  printf '400\n' >"$stub/probe/openrouter/google/lyria-3-clip-preview.status"
}

# fm_free_models_fake_curl <fakebin> <stub> - a curl that serves the fixtures.
# It maps each URL to a fixture file, logs every call to <stub>/call.log, and
# answers with the fixture's status (default 200), writing the body to the -o
# file exactly like curl does. An unstubbed URL is a hard error, never a silent
# pass, so an unexpected call fails the test that made it.
fm_free_models_fake_curl() {
  local fakebin=$1 stub=$2
  cat >"$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
stub=${FM_FAKE_CURL_STUB:-}
method=GET
url=
out=
bodyfile=
arg=
prev=
for arg in "$@"; do
  case "$prev" in
  -o) out=$arg; prev=; continue ;;
  -d) bodyfile=${arg#@}; prev=; continue ;;
  -H|-X|--max-time|-w) prev=; continue ;;
  esac
  case "$arg" in
  -o|-d|-H|-X|--max-time|-w) prev=$arg; continue ;;
  -sS) continue ;;
  *) url=$arg ;;
  esac
done
[ -n "$stub" ] || { echo "fake curl: no FM_FAKE_CURL_STUB" >&2; exit 1; }
[ -n "$url" ] || { echo "fake curl: no url in: $*" >>"$stub/fake-curl-errors.log"; exit 1; }
case "$url" in
*opencode.ai*v1/models*) provider=go; kind=list ;;
*openrouter.ai*v1/models*) provider=openrouter; kind=list ;;
*ollama.com/v1/models*) provider=ollama; kind=list ;;
*opencode.ai*chat/completions*) provider=go; kind=probe ;;
*openrouter.ai*chat/completions*) provider=openrouter; kind=probe ;;
*ollama.com/api/chat*) provider=ollama; kind=probe ;;
*)
  echo "fake curl: unstubbed url $url" >>"$stub/fake-curl-errors.log"
  exit 1
  ;;
esac
model=
if [ -n "$bodyfile" ] && [ -f "$bodyfile" ]; then
  model=$(jq -r '.model // empty' "$bodyfile" 2>/dev/null)
fi
printf '%s %s model=%s\n' "$method" "$url" "${model:-none}" >>"$stub/call.log"
if [ "$kind" = list ]; then
  body="$stub/list/$provider.body"
else
  body="$stub/probe/$provider/$model.body"
fi
status=200
[ -f "${body%.body}.status" ] && status=$(cat "${body%.body}.status")
if [ ! -f "$body" ]; then
  printf '{"error":{"message":"no stub fixture","code":500}}' >"$stub/missing.body"
  body="$stub/missing.body"
  status=500
fi
[ -n "$out" ] && cp "$body" "$out"
printf '%s' "$status"
SH
  chmod +x "$fakebin/curl"
}

# fm_free_models_run <stub> <action> - run the helper against the stub world.
fm_free_models_run() {
  local stub=$1 action=$2
  PATH="$stub/fakebin:$PATH" \
    FM_FREE_MODELS_AUTH_FILE="$stub/home/auth.json" \
    FM_DATA_OVERRIDE="$stub/home/data" \
    FM_FAKE_CURL_STUB="$stub" \
    bash "$HELPER" "$action"
}

EXPECTED_SET='opencode-go/cat-jam-free
opencode-go/longcat-2.5-preview-free
opencode-go/step-5-preview-free
openrouter/liquid/lfm-2.5-2.6b:free
openrouter/nvidia/nemotron-3-ultra-550b-a55b:free'

# fetch prints the canonical sorted set, drops the two dead candidates with the
# service's own words, states plainly that ollama cloud offers nothing free, and
# probes every candidate exactly once.
test_fetch_probes_and_drops_dead() {
  local stub out
  stub="$TMP_ROOT/fetch"
  fm_free_models_stub "$stub"
  fm_free_models_fake_curl "$stub/fakebin" "$stub"
  out=$(fm_free_models_run "$stub" fetch 2>"$TMP_ROOT/fetch.stderr")
  expect_code 0 $? "fetch against the stub world exits 0"
  assert_equals "$EXPECTED_SET" "$out" "fetch prints the canonical sorted candidate set"
  assert_contains "$(cat "$TMP_ROOT/fetch.stderr")" \
    "opencode-go/space-bunny-free: dropped (Model is unavailable)" \
    "fetch drops the candidate the service calls unavailable"
  assert_contains "$(cat "$TMP_ROOT/fetch.stderr")" \
    "openrouter/google/lyria-3-clip-preview: dropped" \
    "fetch drops the candidate the provider rejects"
  assert_contains "$(cat "$TMP_ROOT/fetch.stderr")" \
    "ollama cloud: 2 cloud models, none free" \
    "fetch says plainly that ollama cloud offers nothing free"
  assert_contains "$(cat "$TMP_ROOT/fetch.stderr")" \
    "opencode-go: 4 free candidates: 3 alive, 1 dropped as dead, 0 kept unverified" \
    "fetch summarizes the OpenCode Go source"
  assert_contains "$(cat "$TMP_ROOT/fetch.stderr")" \
    "openrouter: 3 free candidates: 2 alive, 1 dropped as dead, 0 kept unverified" \
    "fetch summarizes the OpenRouter source"
  # Every candidate from both sources was probed exactly once; the paid grok id
  # and the cloud models were never probed.
  assert_equals 10 "$(wc -l <"$stub/call.log" | tr -d ' ')" \
    "fetch made exactly the ten source and probe calls"
  assert_equals 4 "$(grep 'opencode.ai' "$stub/call.log" | grep -c 'chat/completions')" \
    "fetch probed only the free OpenCode Go candidates"
  assert_equals 3 "$(grep -c 'v1/models' "$stub/call.log")" \
    "fetch read each source's model list once"
  pass "fetch probes every candidate, drops the dead ones with their own words, and states the empty source plainly"
}

# status on an unchanged set prints exactly one verdict, makes no calls beyond
# the fetch itself, and writes nothing: the cheap path is the whole point.
test_status_unchanged_does_no_research() {
  local stub out store_hash_before store_hash_after calls_before calls_after
  stub="$TMP_ROOT/unchanged"
  fm_free_models_stub "$stub"
  fm_free_models_fake_curl "$stub/fakebin" "$stub"
  fm_free_models_run "$stub" save >/dev/null 2>"$TMP_ROOT/unchanged.save.stderr"
  expect_code 0 $? "save against the stub world exits 0"
  store_hash_before=$(shasum -a 256 "$stub/home/data/free-models.json" | awk '{print $1}')
  calls_before=$(wc -l <"$stub/call.log" | tr -d ' ')
  : >"$stub/call.log"
  out=$(fm_free_models_run "$stub" status 2>"$TMP_ROOT/unchanged.stderr")
  expect_code 0 $? "status on an unchanged set exits 0"
  assert_equals "status: unchanged" "$out" "status prints exactly one verdict on an unchanged set"
  store_hash_after=$(shasum -a 256 "$stub/home/data/free-models.json" | awk '{print $1}')
  assert_equals "$store_hash_before" "$store_hash_after" "status wrote nothing"
  calls_after=$(wc -l <"$stub/call.log" | tr -d ' ')
  assert_equals "$calls_before" "$calls_after" \
    "status made only the fetch calls, no research on top"
  assert_equals 3 "$(grep -c 'v1/models' "$stub/call.log")" \
    "status read the three lists and probed, nothing else"
  pass "status on an unchanged set is the cheap path: one verdict, no research, nothing written"
}

# status on a changed set reports the delta and exits 1 so the manual step can
# branch on it.
test_status_changed_reports_delta() {
  local stub out
  stub="$TMP_ROOT/changed"
  fm_free_models_stub "$stub"
  fm_free_models_fake_curl "$stub/fakebin" "$stub"
  fm_free_models_run "$stub" save >/dev/null 2>&1
  # The world changes: one OpenRouter free model disappears, another appears.
  cat >"$stub/list/openrouter.body" <<'JSON'
{"data":[{"id":"nvidia/nemotron-3-ultra-550b-a55b:free","pricing":{"prompt":"0","completion":"0"}},{"id":"google/lyria-3-clip-preview","pricing":{"prompt":"0","completion":"0"}},{"id":"poolside/laguna-xs-2.1:free","pricing":{"prompt":"0","completion":"0"}}]}
JSON
  mkdir -p "$stub/probe/openrouter/poolside"
  printf '%s\n' "${ALIVE_BODY//MODEL/poolside/laguna-xs-2.1:free}" \
    >"$stub/probe/openrouter/poolside/laguna-xs-2.1:free.body"
  out=$(fm_free_models_run "$stub" status 2>"$TMP_ROOT/changed.stderr")
  expect_code 1 $? "status on a changed set exits 1"
  assert_contains "$out" "status: changed" "status reports the changed verdict"
  assert_contains "$out" "added: openrouter/poolside/laguna-xs-2.1:free" \
    "status names the added id"
  assert_contains "$out" "removed: openrouter/liquid/lfm-2.5-2.6b:free" \
    "status names the removed id"
  pass "status on a changed set reports its delta"
}

# A subscription-level block proves nothing about the model, so the candidate is
# kept and plainly reported as unverified rather than dropped on a usage limit.
test_blocked_candidate_is_kept_and_stated() {
  local stub out
  stub="$TMP_ROOT/blocked"
  fm_free_models_stub "$stub"
  fm_free_models_fake_curl "$stub/fakebin" "$stub"
  printf '%s\n' '{"type":"error","error":{"type":"GoUsageLimitError","message":"Go usage limit exceeded"}}' \
    >"$stub/probe/go/step-5-preview-free.body"
  printf '429\n' >"$stub/probe/go/step-5-preview-free.status"
  out=$(fm_free_models_run "$stub" fetch 2>"$TMP_ROOT/blocked.stderr")
  expect_code 0 $? "fetch with a blocked candidate exits 0"
  assert_contains "$out" "opencode-go/step-5-preview-free" \
    "a blocked candidate is kept, not dropped"
  assert_contains "$(cat "$TMP_ROOT/blocked.stderr")" \
    "opencode-go/step-5-preview-free: unverified, kept" \
    "fetch says plainly that the candidate is unverified"
  assert_contains "$(cat "$TMP_ROOT/blocked.stderr")" \
    "opencode-go: 4 free candidates: 2 alive, 1 dropped as dead, 1 kept unverified" \
    "fetch counts the blocked candidate as unverified"
  pass "a subscription-level block keeps the candidate and says so plainly"
}

# A missing credential skips that source plainly and still answers from the rest.
test_missing_credential_skips_plainly() {
  local stub out
  stub="$TMP_ROOT/no-credential"
  fm_free_models_stub "$stub"
  fm_free_models_fake_curl "$stub/fakebin" "$stub"
  cat >"$stub/home/auth.json" <<'JSON'
{"openrouter":{"type":"api_key","key":"or-key-stub"}}
JSON
  out=$(fm_free_models_run "$stub" fetch 2>"$TMP_ROOT/no-credential.stderr")
  expect_code 0 $? "fetch with a missing credential exits 0"
  assert_contains "$(cat "$TMP_ROOT/no-credential.stderr")" \
    "opencode-go: no credential in $stub/home/auth.json; skipped" \
    "fetch says plainly which source it skipped and why"
  assert_not_contains "$out" "opencode-go/" "the skipped source contributes nothing"
  assert_contains "$out" "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free" \
    "the remaining source still answers"
  pass "a missing credential skips that source plainly and still answers from the rest"
}

# save writes the fetched set plus a stable fingerprint, and preserves the
# ranking fields the manual step recorded; picks prints the two top picks, or
# says plainly that no validation has run yet.
test_save_and_picks_round_trip() {
  local stub out ranked reasoning
  stub="$TMP_ROOT/save"
  fm_free_models_stub "$stub"
  fm_free_models_fake_curl "$stub/fakebin" "$stub"
  fm_free_models_run "$stub" save >/dev/null 2>&1
  expect_code 0 $? "save exits 0"
  assert_present "$stub/home/data/free-models.json" "save writes the data file"
  [ "$(jq -r '.models | length' "$stub/home/data/free-models.json")" = 5 ] \
    || fail "save stored the fetched set"
  # picks with a stored but unranked list says so plainly.
  out=$(fm_free_models_run "$stub" picks)
  expect_code 0 $? "picks on an unranked list exits 0"
  assert_contains "$out" "no ranking recorded yet" \
    "picks says plainly that no ranking has run yet"
  # The manual step records its ranking; save must preserve it and refresh the
  # fingerprint, and picks must then print the two top picks.
  ranked="$TMP_ROOT/save-ranked.json"
  jq '.models |= map(
      if .id == "nvidia/nemotron-3-ultra-550b-a55b:free" then
        .reasoning_rank = 1 | .speed_rank = 2 | .why_reasoning = "top published coding-benchmark score" |
        .why_speed = "second-fastest measured probe" | .latency_ms = 900 | .validated = "2026-10-14"
      elif .id == "liquid/lfm-2.5-2.6b:free" then
        .reasoning_rank = 2 | .speed_rank = 1 | .why_reasoning = "second published coding-benchmark score" |
        .why_speed = "fastest measured probe" | .latency_ms = 400 | .validated = "2026-10-14"
      else
        .reasoning_rank = 3 | .speed_rank = 3 | .why_reasoning = "bounded research" |
        .why_speed = "measured probe" | .latency_ms = 1500 | .validated = "2026-10-14"
      end)
    | .picks = {reasoning: "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free", speed: "openrouter/liquid/lfm-2.5-2.6b:free"}' \
    "$stub/home/data/free-models.json" >"$ranked"
  cp "$ranked" "$stub/home/data/free-models.json"
  fm_free_models_run "$stub" save >/dev/null 2>&1
  expect_code 0 $? "a second save exits 0"
  [ "$(jq -r '.picks.reasoning' "$stub/home/data/free-models.json")" = \
    "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free" ] \
    || fail "the second save preserved the recorded reasoning pick"
  [ "$(jq -r '.models[] | select(.id == "liquid/lfm-2.5-2.6b:free") | .latency_ms' \
    "$stub/home/data/free-models.json")" = 400 ] \
    || fail "the second save preserved the recorded latency evidence"
  reasoning=$(jq -r '.fingerprint' "$stub/home/data/free-models.json")
  [ -n "$reasoning" ] && [ "$reasoning" != "null" ] || fail "the second save stamped a fingerprint"
  out=$(fm_free_models_run "$stub" picks)
  expect_code 0 $? "picks on a ranked list exits 0"
  assert_equals "reasoning: openrouter/nvidia/nemotron-3-ultra-550b-a55b:free" \
    "$(printf '%s\n' "$out" | sed -n 1p)" "picks prints the top reasoning pick"
  assert_equals "speed: openrouter/liquid/lfm-2.5-2.6b:free" \
    "$(printf '%s\n' "$out" | sed -n 2p)" "picks prints the top speed pick"
  # picks with no stored file at all says plainly that no validation has run.
  stub="$TMP_ROOT/picks-empty"
  fm_free_models_stub "$stub"
  fm_free_models_fake_curl "$stub/fakebin" "$stub"
  out=$(fm_free_models_run "$stub" picks)
  assert_contains "$out" "no validation has run yet" \
    "picks with no stored list says plainly that no validation has run"
  pass "save writes the set and fingerprint, preserves recorded ranking, and picks prints both top picks or the plain none-yet line"
}

# The skill is the manual half: its trigger fires only when the captain asks
# for this, and its procedure owns the status/rank/save loop, the bounded
# research, and the evidence recording.
test_validate_free_models_skill_contract() {
  [ -f "$SKILL" ] || fail "the validate-free-models skill is missing at $SKILL"
  assert_grep "name: validate-free-models" "$SKILL" "the skill has a name"
  assert_grep "description:" "$SKILL" "the skill has a description"
  assert_grep "Load only when the captain asks" "$SKILL" \
    "the skill trigger fires only when the captain asks for this"
  assert_grep "user-invocable: true" "$SKILL" "the skill is invocable by the captain"
  assert_grep "status" "$SKILL" "the skill procedure runs status"
  assert_grep "unchanged" "$SKILL" "the skill procedure stops on unchanged"
  assert_grep "changed" "$SKILL" "the skill procedure ranks on changed"
  assert_grep "save" "$SKILL" "the skill procedure saves"
  assert_grep "benchmark" "$SKILL" "the skill bounds the reasoning research to published benchmarks"
  assert_grep "latency" "$SKILL" "the skill bounds the speed research to a measured latency probe"
  assert_grep "evidence" "$SKILL" "the skill records the evidence behind each placement"
  # The surface is manual: nothing schedules it, and the docs page and the
  # configuration row point back at the skill and the script.
  [ -f "$DOC" ] || fail "the free-models documentation page is missing at $DOC"
  assert_grep "../.agents/skills/validate-free-models/SKILL.md" "$DOC" \
    "the docs page points at the skill owner"
  assert_grep "bin/fm-free-models.sh" "$DOC" "the docs page points at the script"
  assert_grep "free-models.md" "$CONFIG_DOC" "configuration.md links the free-models page"
  assert_no_grep "cron" "$SKILL" "the skill schedules nothing"
  pass "the skill's trigger, procedure, and documentation contract are stated"
}

test_fetch_probes_and_drops_dead
test_status_unchanged_does_no_research
test_status_changed_reports_delta
test_blocked_candidate_is_kept_and_stated
test_missing_credential_skips_plainly
test_save_and_picks_round_trip
test_validate_free_models_skill_contract
