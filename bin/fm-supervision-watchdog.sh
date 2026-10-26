#!/usr/bin/env bash
# fm-supervision-watchdog.sh - persistent always-on supervision loop and terminal doorbell injector.
#
# Usage:
#   fm-supervision-watchdog.sh [start] [--foreground]
#   fm-supervision-watchdog.sh --status
#   fm-supervision-watchdog.sh --stop
#   fm-supervision-watchdog.sh --restart [--foreground]
#   fm-supervision-watchdog.sh --once
#
# In CLI harness sessions without an in-process watch extension or hook-owned
# rewake (e.g. Antigravity/agy CLI, stand-alone TUI sessions), the watcher
# (bin/fm-watch.sh) terminates upon encountering an actionable wake. If the
# session finishes its turn or pauses without immediately re-arming the watcher,
# supervision lapses and turn completions / decisions are missed.
#
# This persistent watchdog daemon:
# 1. Keeps the watcher continuously armed in a self-healing loop.
# 2. On actionable wake, immediately re-arms the watcher so watcher downtime is
#    virtually zero.
# 3. Delivers a fast doorbell injection to the primary supervisor pane (e.g. w44:p1)
#    when an actionable wake occurs or when crewmates/secondmates complete or require
#    decisions, eliminating dead supervision episodes.
# 4. Enforces a single-instance lock per FM_HOME and handles self-healing on crashes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Source required libraries
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE" 2>/dev/null || true
WATCH_SCRIPT="${FM_WATCH_OVERRIDE:-$SCRIPT_DIR/fm-watch.sh}"

LOCK="$STATE/.supervision-watchdog.lock"
PIDFILE="$STATE/.supervision-watchdog.pid"
WATCHER_PIDFILE="$STATE/.supervision-watchdog.watcher_pid"
LOG="$STATE/.supervision-watchdog.log"
ERR="$STATE/.supervision-watchdog.err"

LOG_MAX_BYTES=500000

log() {
  local msg=$1 sz
  printf '%s [%s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$msg" >> "$LOG" 2>/dev/null || true
  sz=$(wc -c < "$LOG" 2>/dev/null || printf '0')
  if [ "$sz" -ge "$LOG_MAX_BYTES" ]; then
    tail -n 1000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true
    rm -f "$LOG.tmp" 2>/dev/null || true
  fi
}

STOP_REQUESTED=0
WATCHER_PID=

handle_shutdown() {
  STOP_REQUESTED=1
  log "shutdown signal received; terminating watcher"
  if [ -n "$WATCHER_PID" ] && kill -0 "$WATCHER_PID" 2>/dev/null; then
    kill -TERM "$WATCHER_PID" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" "$WATCHER_PIDFILE" 2>/dev/null || true
  fm_lock_release "$LOCK" 2>/dev/null || true
  exit 0
}

ring_doorbell() {
  local reason=$1 backend target outcome
  backend=$(discover_supervisor_backend 2>/dev/null || printf '')
  target=$(discover_supervisor_target 2>/dev/null || printf '')
  [ -n "$backend" ] && [ -n "$target" ] || return 0

  outcome=$(fm_procevent_ring_doorbell "$STATE" "$backend" "$target" "$reason" 2>/dev/null || printf 'failed')
  case "$outcome" in
    delivered|skipped|failed) ;;
    *) outcome='failed' ;;
  esac
  log "doorbell ($backend:$target): $outcome (reason: $reason)"
  printf '%s\n' "$outcome"
}

watchdog_run_loop() {
  local once_mode=$1
  local cur_tmp rc reason crash_streak=0 backoff=1 last_doorbell_outcome=""
  local undrained_reason="" backend target

  trap handle_shutdown TERM INT HUP

  echo "$$" > "$PIDFILE"
  log "watchdog daemon started (pid=$$)"

  while [ "$STOP_REQUESTED" -eq 0 ]; do
    touch "$STATE/.supervision-watchdog.beat" 2>/dev/null || true

    cur_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-watchdog-watch.XXXXXX" 2>/dev/null) || {
      sleep 1
      continue
    }

    # Start the watcher child
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$WATCH_SCRIPT" >"$cur_tmp" 2>>"$ERR" &
    WATCHER_PID=$!
    echo "$WATCHER_PID" > "$WATCHER_PIDFILE" 2>/dev/null || true

    # Wait for watcher child to complete its cycle
    # While watcher runs, if a prior doorbell was skipped and wake-queue has undrained wakes,
    # recheck when the supervisor pane becomes idle
    while kill -0 "$WATCHER_PID" 2>/dev/null; do
      if [ "$last_doorbell_outcome" = skipped ] && [ -s "$STATE/.wake-queue" ]; then
        backend=$(discover_supervisor_backend 2>/dev/null || printf '')
        target=$(discover_supervisor_target 2>/dev/null || printf '')
        if [ -n "$backend" ] && [ -n "$target" ]; then
          if [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null || printf '')" = empty ]; then
            undrained_reason=$(tail -n 1 "$STATE/.wake-queue" 2>/dev/null | cut -f 5- || printf 'queued-wake')
            last_doorbell_outcome=$(ring_doorbell "$undrained_reason")
          fi
        fi
      fi
      sleep 1
    done

    if wait "$WATCHER_PID"; then
      rc=0
    else
      rc=$?
    fi

    rm -f "$WATCHER_PIDFILE" 2>/dev/null || true
    WATCHER_PID=""

    [ "$STOP_REQUESTED" -eq 0 ] || {
      rm -f "$cur_tmp" 2>/dev/null || true
      break
    }

    reason=""
    if [ -s "$cur_tmp" ]; then
      reason=$(cat "$cur_tmp")
    fi
    rm -f "$cur_tmp" 2>/dev/null || true

    if [ "$rc" -eq 0 ] && [ -n "$reason" ]; then
      crash_streak=0
      backoff=1
      log "actionable wake: $reason"

      # Ring primary supervisor pane doorbell
      last_doorbell_outcome=$(ring_doorbell "$reason")

      if [ "$once_mode" -eq 1 ]; then
        break
      fi

      # Immediately continue loop to start successor watcher cycle
      continue
    elif [ "$rc" -ne 0 ]; then
      crash_streak=$((crash_streak + 1))
      log "watcher child crashed or exited nonzero (rc=$rc, streak=$crash_streak); backing off ${backoff}s"
      sleep "$backoff"
      backoff=$((backoff * 2))
      [ "$backoff" -le 10 ] || backoff=10
    else
      # Clean exit without reason (e.g. self-eviction on peer lock)
      sleep 0.5
    fi

    if [ "$once_mode" -eq 1 ]; then
      break
    fi
  done

  rm -f "$PIDFILE" "$WATCHER_PIDFILE" 2>/dev/null || true
  fm_lock_release "$LOCK" 2>/dev/null || true
  log "watchdog daemon stopped cleanly"
}

cmd_status() {
  local pid wpid
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      wpid=$(cat "$WATCHER_PIDFILE" 2>/dev/null || true)
      if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
        echo "supervision-watchdog: running pid=$pid (watcher pid=$wpid)"
      else
        echo "supervision-watchdog: running pid=$pid"
      fi
      return 0
    fi
  fi
  echo "supervision-watchdog: stopped"
  return 1
}

cmd_stop() {
  local pid wpid i=0
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do
        sleep 0.1
        i=$((i + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi
  fi
  if [ -f "$WATCHER_PIDFILE" ]; then
    wpid=$(cat "$WATCHER_PIDFILE" 2>/dev/null || true)
    if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
      kill -TERM "$wpid" 2>/dev/null || true
    fi
    rm -f "$WATCHER_PIDFILE" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" 2>/dev/null || true
  fm_lock_release "$LOCK" 2>/dev/null || true
  echo "supervision-watchdog: stopped"
  return 0
}

cmd_start() {
  local foreground=$1 once_mode=$2 pid

  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "supervision-watchdog: already running pid=$pid"
      return 0
    fi
  fi
  if [ -d "$LOCK" ]; then
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "supervision-watchdog: already running pid=$pid (lock held)"
      return 0
    fi
  fi

  if [ "$foreground" -eq 1 ] || [ "$once_mode" -eq 1 ]; then
    if ! fm_lock_try_acquire "$LOCK"; then
      pid=$(cat "$LOCK/pid" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "supervision-watchdog: already running pid=$pid (lock held)"
        return 0
      fi
      # Reclaim stale lock
      fm_lock_release "$LOCK" 2>/dev/null || true
      if ! fm_lock_try_acquire "$LOCK"; then
        echo "error: failed to acquire watchdog lock: $LOCK" >&2
        return 1
      fi
    fi
    watchdog_run_loop "$once_mode"
    return $?
  fi

  # Background detached launch
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_WATCH_OVERRIDE="$WATCH_SCRIPT" \
    nohup "$SCRIPT_DIR/fm-supervision-watchdog.sh" --foreground </dev/null >>"$LOG" 2>>"$ERR" &
  pid=$!

  # Wait up to 2s to verify daemon startup
  local i=0
  while [ "$i" -lt 20 ]; do
    if [ -f "$PIDFILE" ]; then
      pid=$(cat "$PIDFILE" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "supervision-watchdog: started pid=$pid"
        return 0
      fi
    fi
    sleep 0.1
    i=$((i + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    echo "supervision-watchdog: started pid=$pid"
    return 0
  fi

  echo "error: supervision-watchdog failed to start" >&2
  return 1
}

# --- CLI Dispatch -------------------------------------------------------------
FOREGROUND=0
ONCE=0
ACTION="start"

while [ $# -gt 0 ]; do
  case "$1" in
    --status) ACTION="status"; shift ;;
    --stop) ACTION="stop"; shift ;;
    --restart) ACTION="restart"; shift ;;
    --foreground|-f) FOREGROUND=1; shift ;;
    --once) ONCE=1; shift ;;
    start) ACTION="start"; shift ;;
    --help|-h)
      echo "usage: fm-supervision-watchdog.sh [start] [--foreground] [--status] [--stop] [--restart] [--once]"
      exit 0
      ;;
    *)
      echo "error: unrecognized argument: $1" >&2
      exit 1
      ;;
  esac
done

case "$ACTION" in
  status) cmd_status ;;
  stop) cmd_stop ;;
  restart)
    cmd_stop >/dev/null 2>&1 || true
    sleep 0.5
    cmd_start "$FOREGROUND" "$ONCE"
    ;;
  start) cmd_start "$FOREGROUND" "$ONCE" ;;
esac
