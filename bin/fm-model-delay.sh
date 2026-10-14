#!/usr/bin/env bash
# Pause one model turn so a shared, flaky model endpoint is not hit by several
# agents' streams at once. The model-delay skill owns this pacing rule and the
# fixed interval; this script owns only the wait, and it spends that wait only
# on a free-tier caller.
#
# Usage: fm-model-delay.sh <seconds> [config-dir]
#   <seconds>     positive integer pause in seconds: the interval the skill names
#   [config-dir]  directory holding the config/model-delay switch; defaults to
#                 FM_CONFIG_OVERRIDE, then ${FM_HOME:-${FM_ROOT_OVERRIDE:-<code root>}}/config
#
# Environment:
#   FM_MODEL_DELAY_MODEL  the caller's current model id, for example
#                         opencode-go/step-5-preview-free. Only the caller
#                         knows which model it is running, so it names that
#                         model itself; an environment variable rather than
#                         another argument keeps <seconds> [config-dir] as the
#                         one command shape.
#
# While config/model-delay reads exactly "on", this helper paces only a caller
# whose model is free: an id ending in "-free", the rule bin/fm-free-model-lib.sh
# owns. That caller blocks in the foreground for <seconds>, prints one short
# line, and exits 0. Every other caller - a paid id, an unknown id, or no id
# named - waits for nothing, prints one short skip line, and exits 0, because a
# paid fallback endpoint does not share the free endpoint's concurrency
# refusals. While the preference is absent or reads anything but "on" it stays
# fully inert: no line, no wait, exit 0.
#
# It never backgrounds, never wraps itself in a timeout, and needs no harness
# hook or plugin. A caller in another project's local copy must pass the
# firstmate home's config directory here, because that copy cannot discover this
# repository's bin/ or .agents/skills/.
#
# The wait spends no model tokens by itself. The residual cost is what the agent
# spends issuing this call and reading its one-line result; literal zero would need
# a per-harness hook or a gate in front of the model endpoint, which is not
# harness-agnostic. docs/model-delay.md owns that honesty note.
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1

seconds=${1:-}
config=${2:-}
if [ -z "$seconds" ]; then
  printf 'usage: fm-model-delay.sh <seconds> [config-dir]\n' >&2
  exit 2
fi
case "$seconds" in
  *[!0-9]*)
    printf 'error: fm-model-delay.sh: <seconds> must be a positive integer, got "%s"\n' "$seconds" >&2
    exit 2
    ;;
esac
if [ "$seconds" -le 0 ]; then
  printf 'error: fm-model-delay.sh: <seconds> must be greater than zero\n' >&2
  exit 2
fi

if [ -z "$config" ]; then
  config="${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}/config}"
fi

if [ ! -f "$config/model-delay" ]; then
  exit 0
fi
if [ "$(tr -d '[:space:]' <"$config/model-delay" 2>/dev/null)" != on ]; then
  exit 0
fi

# The free-tier verdict decides whether this caller paces at all, so the rule is
# loaded before the wait. A caller that named no model is unknown to this
# helper, and an unknown caller never waits.
free_lib="$root/bin/fm-free-model-lib.sh"
if [ ! -f "$free_lib" ]; then
  printf 'error: fm-model-delay.sh: the free-model rule is missing at %s\n' "$free_lib" >&2
  exit 1
fi
# shellcheck source=bin/fm-free-model-lib.sh
. "$free_lib"
if ! fm_model_is_free "${FM_MODEL_DELAY_MODEL:-}"; then
  printf 'model-delay: skipped: paid/unknown model\n'
  exit 0
fi

sleep "$seconds"
printf 'model-delay: paced %ss\n' "$seconds"
