#!/usr/bin/env bash
# fm-harness-capacity-lib.sh - how many workers a harness admits at once on this
# machine, and whether a fresh worker spawn still fits.
#
# A harness provider or local model runner can have a concurrent-worker limit:
# rate limits, subscription concurrency caps, or local GPU/memory budget.
# The captain declares how many workers a harness admits on this machine in
# config/harness-capacity, and bin/fm-spawn.sh defers a fresh worker beyond that
# number instead of launching it only to fail or be throttled. A deferred task
# keeps its queued backlog item and is dispatched again when a place frees.
# Without a declaration nothing changes and dispatch stays uncapped
# (AGENTS.md section 7).
#
# This file is the single owner of the declaration format, of what holds a
# place, and of the admission verdict. docs/configuration.md "Harness capacity"
# is the operator reference, and bin/fm-spawn.sh owns where the check runs.
#
# Declaration: config/harness-capacity in the local root Firstmate home (the home
# bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every home on this
# machine reads the same number for the same machine's resources. One line per
# harness:
#   <harness> <capacity>
# <harness> is a verified adapter name:
#   claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|agy|devin
# and <capacity> is the last whitespace-separated field, which is a positive
# integer of at most six digits. Blank lines are ignored and the same comment
# rules as config/project-capacity apply: '#' followed by whitespace is a
# comment, bare '#' is a comment, and '#' with a non-integer last field is a
# comment. Any other shape, a harness named twice, a harness that is not a
# verified adapter name, or an unreadable file makes the whole declaration
# unreadable, and bin/fm-spawn.sh then refuses every fresh ship or scout spawn
# from this machine's homes rather than guessing which limit was meant.
#
# Occupancy: a place is held by every ordinary (kind != secondmate) task record
# in the root home or any local secondmate home registered under it
# (fm_local_firstmate_state_dirs in bin/fm-wake-lib.sh) whose recorded harness=
# matches, until its ready PR is recorded (its pr= line) or the task is cleaned
# up - the same place-holding rule as project capacity. A relaunch replaces a
# worker that already counts, and a secondmate is a persistent home rather than
# a worker, so both are exempt. Remote homes are never walked.
#
# Race safety: mirror project capacity - evaluate admission while holding the
# shared project lock and keep holding it until the new task record is published,
# so two concurrent spawns for one harness cannot both publish from the same
# count.
#
# Requires bin/fm-wake-lib.sh (root home, local homes) and bin/fm-backend.sh
# (fm_meta_get) to be sourced first. No side effects on source.

# Exit status of a spawn deferred because the harness is at capacity: the
# sysexits "temporary failure" code, so a caller can tell a deferral that leaves
# the task queued from an ordinary failure.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_HARNESS_CAPACITY_DEFER_EXIT=75

# The config directory holding this machine's declaration: the spawning home's
# own <config-dir> when that home is the local root (so an override of it
# applies), otherwise the root home's config/.
fm_harness_capacity_config_dir() {  # <spawning-home> <spawning-config-dir>
  local home=$1 config=$2 root home_real
  root=$(fm_firstmate_root_home "$home") || return 1
  home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  if [ "$root" = "$home_real" ]; then
    printf '%s\n' "$config"
  else
    printf '%s/config\n' "$root"
  fi
}

# Read the declared capacity for one harness.
# Sets FM_HARNESS_CAPACITY_FILE to the declaration path, FM_HARNESS_CAPACITY
# to the harness's capacity, or to empty when the harness declares none, and
# FM_HARNESS_CAPACITY_ANY to 1 when the declaration caps any harness at all.
# Returns 1 with FM_HARNESS_CAPACITY_ERROR when the declaration is unreadable.
fm_harness_capacity_lookup() {  # <config-dir> <harness-name>
  local name=$2 line lineno=0 hname hcap seen='|'
  FM_HARNESS_CAPACITY_FILE="$1/harness-capacity"
  FM_HARNESS_CAPACITY=
  FM_HARNESS_CAPACITY_ANY=
  FM_HARNESS_CAPACITY_ERROR=
  if [ ! -e "$FM_HARNESS_CAPACITY_FILE" ] && [ ! -L "$FM_HARNESS_CAPACITY_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_HARNESS_CAPACITY_FILE" ] || [ ! -r "$FM_HARNESS_CAPACITY_FILE" ]; then
    FM_HARNESS_CAPACITY_ERROR="$FM_HARNESS_CAPACITY_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#' | '#'[[:space:]]*) continue ;;
      '#'*)
        case "${line##*[[:space:]]}" in
          *[!0-9]*) continue ;;
        esac
        ;;
    esac
    hcap=${line##*[[:space:]]}
    hname=${line%"$hcap"}
    hname=${hname%"${hname##*[![:space:]]}"}
    if [ -z "$hname" ]; then
      FM_HARNESS_CAPACITY_ERROR="$FM_HARNESS_CAPACITY_FILE line $lineno is not '<harness> <capacity>'"
      FM_HARNESS_CAPACITY=
      return 1
    fi
    case "$hname" in
      claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|agy|devin) ;;
      *)
        FM_HARNESS_CAPACITY_ERROR="$FM_HARNESS_CAPACITY_FILE line $lineno names '$hname', which is not a verified adapter (claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|agy|devin)"
        FM_HARNESS_CAPACITY=
        return 1
        ;;
    esac
    case "$hcap" in
      '' | *[!0-9]* | 0*)
        FM_HARNESS_CAPACITY_ERROR="$FM_HARNESS_CAPACITY_FILE line $lineno gives $hname a capacity that is not a positive integer"
        FM_HARNESS_CAPACITY=
        return 1
        ;;
    esac
    if [ "${#hcap}" -gt 6 ]; then
      FM_HARNESS_CAPACITY_ERROR="$FM_HARNESS_CAPACITY_FILE line $lineno gives $hname a capacity longer than six digits"
      FM_HARNESS_CAPACITY=
      return 1
    fi
    case "$seen" in
      *"|$hname|"*)
        FM_HARNESS_CAPACITY_ERROR="$FM_HARNESS_CAPACITY_FILE line $lineno names $hname a second time"
        FM_HARNESS_CAPACITY=
        return 1
        ;;
    esac
    seen="$seen$hname|"
    [ "$hname" != "$name" ] || FM_HARNESS_CAPACITY=$hcap
  done < "$FM_HARNESS_CAPACITY_FILE"
  [ "$seen" = '|' ] || FM_HARNESS_CAPACITY_ANY=1
  return 0
}

# Count the task records holding a place in one harness's capacity.
# <first-state> is the spawning home's state directory. <own-id> is the task
# being admitted; its own record in <first-state> is the one this spawn
# replaces, so it is not counted.
# Sets FM_HARNESS_CAPACITY_OCCUPANTS to the count and
# FM_HARNESS_CAPACITY_OCCUPANT_IDS to a comma-separated list of the holders,
# each outside <first-state> qualified with its home. Returns 1 with
# FM_HARNESS_CAPACITY_ERROR when the local homes cannot be enumerated, or when
# a state directory or task record in them cannot be read, since skipping it
# could undercount the holders.
fm_harness_capacity_occupants() {  # <harness> <first-state> <own-id>
  local want=$1 first=$2 self=$3 state meta kind harness id label
  FM_HARNESS_CAPACITY_OCCUPANTS=0
  FM_HARNESS_CAPACITY_OCCUPANT_IDS=
  FM_HARNESS_CAPACITY_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_HARNESS_CAPACITY_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_HARNESS_CAPACITY_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_HARNESS_CAPACITY_ERROR="task record $meta cannot be read"
        return 1
      }
      kind=$(fm_meta_get "$meta" kind)
      [ "$kind" != secondmate ] || continue
      [ -z "$(fm_meta_get "$meta" pr)" ] || continue
      harness=$(fm_meta_get "$meta" harness)
      [ "$harness" = "$want" ] || continue
      id=$(basename "$meta" .meta)
      label=$id
      [ "$state" = "$first" ] || label="$id in $(dirname "$state")"
      FM_HARNESS_CAPACITY_OCCUPANTS=$((FM_HARNESS_CAPACITY_OCCUPANTS + 1))
      FM_HARNESS_CAPACITY_OCCUPANT_IDS="${FM_HARNESS_CAPACITY_OCCUPANT_IDS:+$FM_HARNESS_CAPACITY_OCCUPANT_IDS, }$label"
    done
  done
  return 0
}
