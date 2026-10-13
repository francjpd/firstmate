#!/usr/bin/env bash
# Pause one model turn so a shared, flaky model endpoint is not hit by several
# agents' streams at once. The model-delay skill owns this pacing rule and the
# fixed interval; this script owns only the wait.
#
# Usage: fm-model-delay.sh <seconds> [config-dir]
#   <seconds>     positive integer pause in seconds: the interval the skill names
#   [config-dir]  directory holding the config/model-delay switch; defaults to
#                 FM_CONFIG_OVERRIDE, then ${FM_HOME:-${FM_ROOT_OVERRIDE:-<code root>}}/config
#
# With config/model-delay reading exactly "on" it blocks in the foreground for
# <seconds>, prints one short line, and exits 0. Otherwise it is inert: it prints
# nothing, waits for nothing, and exits 0, so a disabled mode costs the caller only
# the call. It never backgrounds, never wraps itself in a timeout, and needs no
# harness hook or plugin. A caller in another project's local copy must pass the
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

sleep "$seconds"
printf 'model-delay: paused %ss\n' "$seconds"
