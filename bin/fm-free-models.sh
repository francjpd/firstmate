#!/usr/bin/env bash
# fm-free-models.sh - the deterministic half of the validate-free-models surface:
# it queries the three free-model sources, probes every candidate with one tiny
# live completion, and keeps one cheap cached list under the active home.
#
# The ranking half is deliberately not in this script. Ranking is bounded research
# owned by .agents/skills/validate-free-models/SKILL.md, which this script serves
# by fetching and comparing the candidate set. Nothing here schedules anything.
#
# Usage: fm-free-models.sh <fetch|status|save|picks> [--help]
#   fetch   query the three sources, probe each candidate with one tiny live
#           completion, and print the canonical sorted candidate list on stdout,
#           one <provider>/<id> per line, with plain-language per-source results
#           on stderr. A candidate the service answers with a model-level error
#           is dropped rather than carried; a candidate the script cannot
#           verify because of a subscription-level block or a transport failure
#           is kept and plainly reported as unverified, because a usage limit
#           says nothing about a model being dead.
#   status  compare the freshly fetched set with the stored list and print
#           exactly one verdict on stdout: `status: unchanged`, or
#           `status: changed` followed by the added and removed ids. This is the
#           cheap path: it makes no ranking or research calls and writes
#           nothing, so a second run after a save costs only the fetch itself.
#           Exits 0 on unchanged, 1 on changed.
#   save    write the freshly fetched set plus a stable fingerprint of it to
#           the home's data file, preserving any ranking fields the manual
#           ranking step already recorded for models still in the set. It never
#           ranks anything itself, and it refuses to overwrite a stored file it
#           cannot read as JSON.
#   picks   print the current top reasoning pick and top speed pick, one line
#           each, or plainly say that no validation or ranking has run yet.
#
# The three sources, checked in this order:
#   opencode-go    the Go subscription's own model list, keeping only ids ending
#                  in -free, which is the naming convention its free preview
#                  models use. The endpoint is truth, never a locally installed
#                  editor's catalog.
#   openrouter     its model list filtered to zero-price models.
#   ollama-cloud   its cloud model list, filtered the same way. Ollama cloud is
#                  expected to offer nothing free; the check still runs and says
#                  so plainly rather than assuming.
#
# The data file is $DATA/free-models.json under the ACTIVE home, resolved through
# the same home contract the rest of bin/ uses ($FM_HOME, then
# $FM_ROOT_OVERRIDE, then this repo root; $FM_DATA_OVERRIDE selects data/
# directly). It is never resolved relative to this script or to a checkout,
# because a worker's checkout has no populated data/. data/free-models.md is
# its human-readable twin, written by the manual ranking step.
#
# Credentials are read-only from $FM_FREE_MODELS_AUTH_FILE (default
# ~/.pi/agent/auth.json), taking the opencode-go and openrouter entries. A key
# reaches curl as a header read from a file descriptor, never on argv, and no
# key, no provider response, and no probe response is ever printed, logged, or
# written into the data file, the docs, or any log.
#
# Exit status: 0 success (or unchanged), 1 changed, 2 usage error, 3 nothing
# could be done (no source readable, corrupt stored file, or a missing tool).
set -u

PROG=fm-free-models.sh
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STORE="$DATA/free-models.json"

AUTH_FILE="${FM_FREE_MODELS_AUTH_FILE:-${HOME}/.pi/agent/auth.json}"
TIMEOUT="${FM_FREE_MODELS_TIMEOUT:-30}"
GO_MODELS_URL="${FM_FREE_MODELS_GO_MODELS_URL:-https://opencode.ai/inference/go/v1/models}"
GO_CHAT_URL="${FM_FREE_MODELS_GO_CHAT_URL:-https://opencode.ai/inference/go/v1/chat/completions}"
OR_MODELS_URL="${FM_FREE_MODELS_OPENROUTER_MODELS_URL:-https://openrouter.ai/api/v1/models}"
OR_CHAT_URL="${FM_FREE_MODELS_OPENROUTER_CHAT_URL:-https://openrouter.ai/api/v1/chat/completions}"
OLLAMA_MODELS_URL="${FM_FREE_MODELS_OLLAMA_MODELS_URL:-https://ollama.com/v1/models}"
OLLAMA_CHAT_URL="${FM_FREE_MODELS_OLLAMA_CHAT_URL:-https://ollama.com/api/chat}"
PROBE_AGENT="firstmate-free-models/1.0"
PROBE_PROMPT="Say OK."
PROBE_MAX_TOKENS=2

fm_fm_usage() {
  cat <<EOF
$PROG - keep the fleet's free-model list current (the deterministic half of
.validate-free-models; the ranking half is the skill's manual step).

Usage:
  $PROG fetch    query the three sources, probe every candidate, print the
                 canonical sorted candidate list on stdout
  $PROG status   print exactly one verdict: unchanged, or changed with the
                 added and removed ids
  $PROG save     write the fetched set plus a stable fingerprint to the data
                 file, preserving recorded ranking
  $PROG picks    print the current top reasoning and top speed picks

The data file is \$DATA/free-models.json under the active home. Credentials are
read-only from \$FM_FREE_MODELS_AUTH_FILE (default ~/.pi/agent/auth.json). This
script never schedules anything and never ranks anything; the ranking step
belongs to .agents/skills/validate-free-models/SKILL.md.
EOF
}

fm_fm_auth_key() {  # <entry> - echoes the entry's key, empty when absent or unreadable
  local entry=$1
  [ -f "$AUTH_FILE" ] || return 0
  jq -r --arg e "$entry" '.[$e]?.key // empty' "$AUTH_FILE" 2>/dev/null
}

fm_fm_session_header() {  # one stable id per fetch run, as the endpoint asks
  printf '%s-%s' "$(date +%s)" "$$"
}

fm_fm_http_get() {  # <url> <out-file> <key|-> - echoes the http code, 000 on transport failure
  local url=$1 out=$2 key=$3 code
  if [ -n "$key" ] && [ "$key" != "-" ]; then
    code=$(curl -sS --max-time "$TIMEOUT" -o "$out" -w '%{http_code}' \
      -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$key") \
      "$url" 2>/dev/null) || code=000
  else
    code=$(curl -sS --max-time "$TIMEOUT" -o "$out" -w '%{http_code}' \
      "$url" 2>/dev/null) || code=000
  fi
  printf '%s' "$code"
}

fm_fm_probe() {  # <model> <chat-url> <key|-> <session-header|-> - echoes alive | dead: <reason> | blocked: <reason>
  local model=$1 url=$2 key=$3 session_header=$4
  local req resp code body err_type err_msg reason verdict
  req="$TMP_DIR/probe-req.$$"
  resp="$TMP_DIR/probe-resp.$$"
  jq -nc --arg model "$model" --arg prompt "$PROBE_PROMPT" --argjson max "$PROBE_MAX_TOKENS" \
    '{model: $model, messages: [{role: "user", content: $prompt}], max_tokens: $max, temperature: 0}' \
    >"$req" 2>/dev/null || { rm -f "$req"; printf 'blocked: could not build the probe request'; return 0; }
  local headers=(-H 'Content-Type: application/json' -H "User-Agent: $PROBE_AGENT")
  if [ -n "$session_header" ] && [ "$session_header" != "-" ]; then
    headers+=(-H "$session_header: $(fm_fm_session_header)")
  fi
  if [ -n "$key" ] && [ "$key" != "-" ]; then
    code=$(curl -sS --max-time "$TIMEOUT" -X POST -o "$resp" -w '%{http_code}' \
      "${headers[@]}" -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$key") \
      -d @"$req" "$url" 2>/dev/null) || code=000
  else
    code=$(curl -sS --max-time "$TIMEOUT" -X POST -o "$resp" -w '%{http_code}' \
      "${headers[@]}" \
      -d @"$req" "$url" 2>/dev/null) || code=000
  fi
  rm -f "$req"
  body=$(head -c 2000 "$resp" 2>/dev/null || true)
  rm -f "$resp"
  err_type=$(printf '%s' "$body" | jq -r \
    'if (.error | type) == "object" then (.error.type // "") elif (.type | type) == "string" then .type else "" end' \
    2>/dev/null || true)
  err_msg=$(printf '%s' "$body" | jq -r \
    'if (.error | type) == "object" then (.error.message // "") else "" end' \
    2>/dev/null || true)
  err_code=$(printf '%s' "$body" | jq -r 'if (.error | type) == "object" then (.error.code | tostring) else "" end' \
    2>/dev/null || true)
  reason="$err_type ${err_msg:-}"
  reason=$(printf '%s' "$reason" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
  reason=$(printf '%s' "$reason" | cut -c1-120)

  if [ "$code" = 000 ]; then
    printf 'blocked: probe did not reach the service'
    return 0
  fi
  # A subscription-level block proves nothing about the model, so the candidate
  # is kept and plainly reported as unverified.
  case "$code" in
  401 | 403 | 429)
    printf 'blocked: %s' "${reason:-http $code}"
    return 0
    ;;
  esac
  case "$err_type" in
  *UsageLimit* | *RateLimit* | *Auth* | *Key* | *Quota*)
    printf 'blocked: %s' "${reason:-$err_type}"
    return 0
    ;;
  esac
  # OpenRouter wraps provider outcomes in a 200 with an inner error code; the
  # inner code carries the real verdict.
  case "$err_code" in
  401 | 403 | 429)
    printf 'blocked: %s' "${reason:-http $err_code}"
    return 0
    ;;
  esac
  # HTTP 200 with a real completion is the only alive verdict.
  if [ "$code" = 200 ]; then
    if printf '%s' "$body" | grep -q '"choices"'; then
      printf 'alive'
      return 0
    fi
    # A provider that positively rejects the model's requests (inner 400) or
    # names it unavailable no longer serves it, so the candidate is dropped.
    case "$err_code" in
    400)
      printf 'dead: %s' "${reason:-provider rejected the model}"
      return 0
      ;;
    esac
    case "$reason" in
    *[Uu]navailable* | *not\ found* | *does\ not\ exist* | *no\ such* | *not\ served* | *unknown\ model* | *No\ endpoints* | *invalid\ argument*)
      printf 'dead: %s' "${reason:-unavailable}"
      return 0
      ;;
    esac
    printf 'blocked: http 200 %s' "${reason:-unrecognized response}"
    return 0
  fi
  # Any other 4xx is a model-level rejection: the service will not serve it.
  case "$code" in
  4??)
    printf 'dead: http %s %s' "$code" "${reason:-error}"
    return 0
    ;;
  esac
  printf 'blocked: http %s %s' "$code" "${reason:-unrecognized response}"
  return 0
}

fm_fm_model_list_valid() {  # <file> - the file is JSON with a .data array
  jq -e '(.data | type) == "array"' "$1" >/dev/null 2>&1
}

fm_fm_fetch_set() {  # <set-file> - canonical sorted lines on the file, plain per-source notes on stderr
  local set_file=$1 resp ids id verdict reason code
  local go_key or_key n_alive n_dead n_blocked n_total sources_ok=0
  : >"$set_file"

  # --- OpenCode Go: the subscription's own list, free ids only. ---
  go_key=$(fm_fm_auth_key opencode-go)
  if [ -z "$go_key" ]; then
    printf 'opencode-go: no credential in %s; skipped\n' "$AUTH_FILE" >&2
  else
    resp="$TMP_DIR/go-models.json"
    code=$(fm_fm_http_get "$GO_MODELS_URL" "$resp" "$go_key")
    if [ "$code" != 200 ]; then
      printf 'opencode-go: model list returned %s; skipped\n' \
        "$([ "$code" = 000 ] && printf 'http 000 (unreachable)' || printf 'http %s' "$code")" >&2
    elif ! fm_fm_model_list_valid "$resp"; then
      printf 'opencode-go: model list is not a model list; skipped\n' >&2
    else
      sources_ok=$((sources_ok + 1))
      ids=$(jq -r '.data[].id' "$resp" 2>/dev/null | grep -e '-free$' | LC_ALL=C sort -u || true)
      if [ -z "$ids" ]; then
        printf 'opencode-go: %s models, none free\n' "$(jq '.data | length' "$resp" 2>/dev/null || printf '0')" >&2
      else
        n_alive=0 n_dead=0 n_blocked=0 n_total=0
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          n_total=$((n_total + 1))
          verdict=$(fm_fm_probe "$id" "$GO_CHAT_URL" "$go_key" x-opencode-session)
          case "$verdict" in
          alive)
            printf 'opencode-go/%s\n' "$id" >>"$set_file"
            n_alive=$((n_alive + 1))
            ;;
          dead:*)
            n_dead=$((n_dead + 1))
            printf 'opencode-go/%s: dropped (%s)\n' "$id" "${verdict#dead: }" >&2
            ;;
          *)
            printf 'opencode-go/%s\n' "$id" >>"$set_file"
            n_blocked=$((n_blocked + 1))
            printf 'opencode-go/%s: unverified, kept (%s)\n' "$id" "${verdict#blocked: }" >&2
            ;;
          esac
        done < <(printf '%s\n' "$ids")
        printf 'opencode-go: %s free candidates: %s alive, %s dropped as dead, %s kept unverified\n' \
          "$n_total" "$n_alive" "$n_dead" "$n_blocked" >&2
      fi
    fi
  fi

  # --- OpenRouter: zero-price models. ---
  or_key=$(fm_fm_auth_key openrouter)
  if [ -z "$or_key" ]; then
    printf 'openrouter: no credential in %s; skipped\n' "$AUTH_FILE" >&2
  else
    resp="$TMP_DIR/openrouter-models.json"
    code=$(fm_fm_http_get "$OR_MODELS_URL" "$resp" "$or_key")
    if [ "$code" != 200 ]; then
      printf 'openrouter: model list returned %s; skipped\n' \
        "$([ "$code" = 000 ] && printf 'http 000 (unreachable)' || printf 'http %s' "$code")" >&2
    elif ! fm_fm_model_list_valid "$resp"; then
      printf 'openrouter: model list is not a model list; skipped\n' >&2
    else
      sources_ok=$((sources_ok + 1))
      ids=$(jq -r '.data[] | select(((.pricing.prompt // "1") | tostring) == "0" and ((.pricing.completion // "1") | tostring) == "0") | .id' "$resp" 2>/dev/null \
        | LC_ALL=C sort -u || true)
      if [ -z "$ids" ]; then
        printf 'openrouter: %s models, none zero-price\n' "$(jq '.data | length' "$resp" 2>/dev/null || printf '0')" >&2
      else
        n_alive=0 n_dead=0 n_blocked=0 n_total=0
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          n_total=$((n_total + 1))
          verdict=$(fm_fm_probe "$id" "$OR_CHAT_URL" "$or_key" "-")
          case "$verdict" in
          alive)
            printf 'openrouter/%s\n' "$id" >>"$set_file"
            n_alive=$((n_alive + 1))
            ;;
          dead:*)
            n_dead=$((n_dead + 1))
            printf 'openrouter/%s: dropped (%s)\n' "$id" "${verdict#dead: }" >&2
            ;;
          *)
            printf 'openrouter/%s\n' "$id" >>"$set_file"
            n_blocked=$((n_blocked + 1))
            printf 'openrouter/%s: unverified, kept (%s)\n' "$id" "${verdict#blocked: }" >&2
            ;;
          esac
        done < <(printf '%s\n' "$ids")
        printf 'openrouter: %s free candidates: %s alive, %s dropped as dead, %s kept unverified\n' \
          "$n_total" "$n_alive" "$n_dead" "$n_blocked" >&2
      fi
    fi
  fi

  # --- Ollama cloud: expected to offer nothing free, still checked and stated. ---
  resp="$TMP_DIR/ollama-models.json"
  code=$(fm_fm_http_get "$OLLAMA_MODELS_URL" "$resp" "-")
  if [ "$code" != 200 ]; then
    printf 'ollama cloud: model list returned %s; skipped\n' \
      "$([ "$code" = 000 ] && printf 'http 000 (unreachable)' || printf 'http %s' "$code")" >&2
  elif ! fm_fm_model_list_valid "$resp"; then
    printf 'ollama cloud: model list is not a model list; skipped\n' >&2
  else
    sources_ok=$((sources_ok + 1))
    ids=$(jq -r '.data[].id' "$resp" 2>/dev/null | grep -e ':free$' | LC_ALL=C sort -u || true)
    if [ -z "$ids" ]; then
      printf 'ollama cloud: %s cloud models, none free\n' "$(jq '.data | length' "$resp" 2>/dev/null || printf '0')" >&2
    else
      n_alive=0 n_dead=0 n_blocked=0 n_total=0
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        n_total=$((n_total + 1))
        verdict=$(fm_fm_probe "$id" "$OLLAMA_CHAT_URL" "${OLLAMA_API_KEY:--}" "-")
        case "$verdict" in
        alive)
          printf 'ollama-cloud/%s\n' "$id" >>"$set_file"
          n_alive=$((n_alive + 1))
          ;;
        dead:*)
          n_dead=$((n_dead + 1))
          printf 'ollama-cloud/%s: dropped (%s)\n' "$id" "${verdict#dead: }" >&2
          ;;
        *)
          printf 'ollama-cloud/%s\n' "$id" >>"$set_file"
          n_blocked=$((n_blocked + 1))
          printf 'ollama-cloud/%s: unverified, kept (%s)\n' "$id" "${verdict#blocked: }" >&2
          ;;
        esac
      done < <(printf '%s\n' "$ids")
      printf 'ollama cloud: %s free cloud models: %s alive, %s dropped as dead, %s kept unverified\n' \
        "$n_total" "$n_alive" "$n_dead" "$n_blocked" >&2
    fi
  fi

  LC_ALL=C sort -u "$set_file" -o "$set_file"
  # At least one source had to be readable for the set to mean anything; a
  # source that answered with models and no free candidate still counts.
  if [ "$sources_ok" -eq 0 ]; then
    return 3
  fi
  return 0
}

fm_fm_fingerprint() {  # <set-file> - stable hash of the canonical set
  local set_file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$set_file" | awk '{print $1}'
  else
    sha256sum "$set_file" | awk '{print $1}'
  fi
}

fm_fm_stored_ids() {  # the stored set as sorted lines, empty when there is none
  [ -f "$STORE" ] || return 0
  jq -r '.models[]? | .provider + "/" + .id' "$STORE" 2>/dev/null | LC_ALL=C sort -u
}

fm_fm_stored_fingerprint() {
  [ -f "$STORE" ] || return 0
  jq -r '.fingerprint // empty' "$STORE" 2>/dev/null
}

fm_fm_action_status() {  # <set-file> - exactly one verdict on stdout
  local set_file=$1 fp stored_fp stored_set added removed line
  fp=$(fm_fm_fingerprint "$set_file")
  stored_fp=$(fm_fm_stored_fingerprint)
  stored_set=$(fm_fm_stored_ids)
  if [ "$fp" = "$stored_fp" ] && [ "$(fm_fm_set_body "$set_file")" = "$(printf '%s\n' "$stored_set" | LC_ALL=C sort -u)" ]; then
    printf 'status: unchanged\n'
    return 0
  fi
  if [ -f "$STORE" ] && ! jq empty "$STORE" >/dev/null 2>&1; then
    printf '%s: the stored %s is not readable JSON, so the comparison used no stored set\n' \
      "$PROG" "$STORE" >&2
  fi
  added=$(LC_ALL=C comm -23 "$set_file" <(printf '%s\n' "$stored_set" | LC_ALL=C sort -u))
  removed=$(LC_ALL=C comm -13 "$set_file" <(printf '%s\n' "$stored_set" | LC_ALL=C sort -u))
  printf 'status: changed\n'
  line=$(printf '%s\n' "$added" | grep -v '^$' | paste -sd, -)
  [ -n "$line" ] && printf 'added: %s\n' "$line"
  line=$(printf '%s\n' "$removed" | grep -v '^$' | paste -sd, -)
  [ -n "$line" ] && printf 'removed: %s\n' "$line"
  return 1
}

fm_fm_set_body() {  # <set-file> - the canonical lines as one sorted copy for comparison
  LC_ALL=C sort -u "$1"
}

fm_fm_action_save() {  # <set-file> - merge ranking, write the data file atomically
  local set_file=$1 fp today set_json stored new_json tmp n_models n_unranked
  fp=$(fm_fm_fingerprint "$set_file")
  today=$(date +%F)
  if [ -f "$STORE" ] && ! jq empty "$STORE" >/dev/null 2>&1; then
    printf '%s: the stored %s is not readable JSON; refusing to overwrite it\n' "$PROG" "$STORE" >&2
    return 3
  fi
  stored=$(cat "$STORE" 2>/dev/null || printf '{}')
  set_json=$(jq -R . "$set_file" | jq -s .)
  n_models=$(printf '%s\n' "$set_json" | jq 'length')
  new_json=$(jq -n --argjson set "$set_json" --arg fp "$fp" --arg today "$today" \
    --argjson stored "$stored" '
    ($stored.models // []) as $old
    | ($old | map({key: (.provider + "/" + .id), value: .}) | from_entries) as $oldmap
    | {
        version: 1,
        fingerprint: $fp,
        validated: ($stored.validated // $today),
        models: [
          $set[] | . as $key | ($key | split("/")) as $p
          | ($oldmap[$key] // {}) as $o
          | {
              provider: $p[0],
              id: $p[1],
              reasoning_rank: $o.reasoning_rank,
              speed_rank: $o.speed_rank,
              why_reasoning: $o.why_reasoning,
              why_speed: $o.why_speed,
              latency_ms: $o.latency_ms,
              validated: $o.validated
            }
        ],
        picks: (
          if ($stored.picks.reasoning != null) and ($set | index($stored.picks.reasoning) != null)
             and ($stored.picks.speed != null) and ($set | index($stored.picks.speed) != null)
          then {reasoning: $stored.picks.reasoning, speed: $stored.picks.speed}
          else {reasoning: null, speed: null}
        )
      }') || { printf '%s: save: could not build the data file\n' "$PROG" >&2; return 3; }
  if [ ! -d "$DATA" ]; then
    mkdir -p "$DATA" || { printf '%s: save: could not create %s\n' "$PROG" "$DATA" >&2; return 3; }
  fi
  tmp=$(mktemp "$STORE.tmp.XXXXXX") || { printf '%s: save: could not write %s\n' "$PROG" "$STORE" >&2; return 3; }
  printf '%s\n' "$new_json" >"$tmp" || { rm -f "$tmp"; printf '%s: save: could not write %s\n' "$PROG" "$STORE" >&2; return 3; }
  mv "$tmp" "$STORE" || { rm -f "$tmp"; printf '%s: save: could not replace %s\n' "$PROG" "$STORE" >&2; return 3; }
  n_unranked=$(printf '%s' "$new_json" | jq '[.models[] | select(.reasoning_rank == null or .speed_rank == null)] | length')
  printf 'saved: %s models to %s (fingerprint %s)\n' "$n_models" "$STORE" "$(printf '%s' "$fp" | cut -c1-12)"
  if [ "$n_unranked" -gt 0 ]; then
    printf 'saved: %s of those models have no ranking yet; the ranking step belongs to the validate-free-models skill\n' \
      "$n_unranked"
  fi
  return 0
}

fm_fm_action_picks() {
  local reasoning speed
  if [ ! -f "$STORE" ]; then
    printf 'picks: no validation has run yet\n'
    return 0
  fi
  if ! jq empty "$STORE" >/dev/null 2>&1; then
    printf 'picks: the stored %s is not readable JSON\n' "$STORE" >&2
    printf 'picks: no validation has run yet\n'
    return 0
  fi
  reasoning=$(jq -r '.picks.reasoning // empty' "$STORE" 2>/dev/null)
  speed=$(jq -r '.picks.speed // empty' "$STORE" 2>/dev/null)
  if [ -z "$reasoning" ]; then
    reasoning=$(jq -r '.models[] | select(.reasoning_rank == 1) | .provider + "/" + .id' "$STORE" 2>/dev/null | head -n1)
  fi
  if [ -z "$speed" ]; then
    speed=$(jq -r '.models[] | select(.speed_rank == 1) | .provider + "/" + .id' "$STORE" 2>/dev/null | head -n1)
  fi
  if [ -z "$reasoning" ] && [ -z "$speed" ]; then
    printf 'picks: no ranking recorded yet; the ranking step belongs to the validate-free-models skill\n'
    return 0
  fi
  [ -n "$reasoning" ] && printf 'reasoning: %s\n' "$reasoning"
  [ -n "$speed" ] && printf 'speed: %s\n' "$speed"
  return 0
}

# --- entry point ----------------------------------------------------------------

action=${1:-}
case "$action" in
--help | -h)
  fm_fm_usage
  exit 0
  ;;
esac
case "$action" in
fetch | status | save | picks) ;;
*)
  if [ -z "$action" ]; then
    printf 'error: %s: choose an action: fetch, status, save, or picks\n' "$PROG" >&2
  else
    printf 'error: %s: unknown action "%s"\n' "$PROG" "$action" >&2
  fi
  fm_fm_usage >&2
  exit 2
  ;;
esac

command -v curl >/dev/null 2>&1 || {
  printf 'error: %s: curl not installed\n' "$PROG" >&2
  exit 3
}
command -v jq >/dev/null 2>&1 || {
  printf 'error: %s: jq not installed\n' "$PROG" >&2
  exit 3
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-free-models.XXXXXX") || {
  printf 'error: %s: could not create a temp dir\n' "$PROG" >&2
  exit 3
}
trap 'rm -rf "$TMP_DIR"' EXIT

set_file="$TMP_DIR/set.txt"

case "$action" in
fetch)
  if ! fm_fm_fetch_set "$set_file"; then
    printf 'error: %s: no source could be read, so there is no candidate list\n' "$PROG" >&2
    exit 3
  fi
  cat "$set_file"
  ;;
status)
  if ! fm_fm_fetch_set "$set_file"; then
    printf 'error: %s: no source could be read, so the fetched set is empty\n' "$PROG" >&2
    exit 3
  fi
  fm_fm_action_status "$set_file"
  exit $?
  ;;
save)
  if ! fm_fm_fetch_set "$set_file"; then
    printf 'error: %s: no source could be read, so there is no set to save\n' "$PROG" >&2
    exit 3
  fi
  fm_fm_action_save "$set_file"
  exit $?
  ;;
picks)
  fm_fm_action_picks
  exit $?
  ;;
esac
