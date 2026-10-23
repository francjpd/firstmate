#!/usr/bin/env bash
# fm-agy2.sh - run the Antigravity CLI (`agy`) as a SECOND Antigravity identity
# on this same Unix user, so two subscriptions can run side by side without
# logging out of the first one and without a second Unix account.
#
# Usage:
#   fm-agy2.sh [<agy arguments...>]     launch agy as the second identity
#   fm-agy2.sh --agy2-status            show the store, the bus, and both identities
#   fm-agy2.sh --agy2-ready             exit 0 only when a second, distinct identity is stored
#   fm-agy2.sh --agy2-verify            print this identity's /quota beside the fleet's
#   fm-agy2.sh --agy2-forget            remove ONLY this identity's stored token
#   fm-agy2.sh --agy2-root              print this identity's state root
#   fm-agy2.sh --agy2-help              print this header
#
# Install it in PATH under the name `agy2` (a symlink to this file is enough);
# `bin/fm-spawn.sh` then dispatches a worker on the `agy2` harness. Every agy
# flag and the whole TUI behave exactly as they do under `agy`, because this is
# the same binary - only the identity and the state root differ.
#
# WHY AN OS KEYRING PER IDENTITY, AND NOT A FILE OR AN API KEY.
# agy resolves its account from exactly one OS keyring item per Unix user,
# keyed by the fixed attributes `service=gemini, username=antigravity`, and it
# consults that keyring FIRST (codeassistclient.compositeTokenStorage;
# `composite_token_storage.go:419` is the file fallback, reached only when the
# keyring call ERRORS). HOME, XDG_*, and --gemini_dir move state but never
# identity, and a private D-Bus session alone still talks to the one running
# keyring daemon. So the isolated thing has to be the keyring SERVICE ITSELF:
# this wrapper runs its own dbus-daemon on its own socket and its own
# gnome-keyring-daemon with its own control directory and its own data home,
# and agy reaches that second slot only because its DBUS_SESSION_BUS_ADDRESS
# points at this wrapper's bus. Two rejected alternatives, with the evidence in
# docs/verification/agy2.md:
#   - A deliberately unreachable bus (the documented file-token fallback) makes
#     the second store a file whose path cannot be named in advance and that
#     only exists after a real login, and it FAILS OPEN: any process handed a
#     working bus silently reverts to the fleet identity.
#   - GEMINI_API_KEY with `modelProvider: "gemini"` in settings.json selects
#     auth method `gemini_api_key` with the keyring never consulted at all
#     (verified: zero keyring lines in the CLI log), but it authenticates with
#     no account identity and calls generativelanguage.googleapis.com, i.e. it
#     is Gemini-API billed and does NOT draw the Antigravity subscription's
#     Gemini or Claude/GPT quota pools `agy --print /quota` reports.
#
# THE FLEET'S IDENTITY IS NEVER TOUCHED. The one destructive mistake available
# here is a login performed while the fleet's keyring is reachable, because the
# login would write that single shared slot. This wrapper therefore never hands
# agy an environment in which that slot is reachable: DBUS_SESSION_BUS_ADDRESS
# is replaced unconditionally, and before the TUI starts the wrapper proves the
# isolation it claims (below) instead of assuming it. A login performed inside
# `agy2` writes the private slot only.
#
# WHAT IS ASSERTED BEFORE THE TUI STARTS, in order, each refusing loudly:
#   1. the private Secret Service on this wrapper's bus is served by a
#      gnome-keyring-daemon whose own environment carries THIS state root's
#      control directory and data home (so it cannot be the fleet daemon);
#   2. the private store path differs from the fleet's ~/.local/share/keyrings;
#   3. a probe item written on this bus reads back here and is INVISIBLE on the
#      fleet bus, proving the two stores are distinct and this one is writable,
#      which is exactly the capability agy needs to save a token;
#   4. the identity this store holds is not the fleet's account - a private
#      slot holding the fleet email is a hard refusal, never a warning.
#
# WHAT THIS DOES NOT ISOLATE. Only the Gemini tree (`--gemini_dir`) and the
# account identity move. HOME, XDG_CONFIG_HOME, and every other path stay the
# real user's, deliberately: a dispatched agy2 worker needs the captain's git,
# gh, and ssh state to do its job. Two consequences, both bounded and known:
# agy's own plugin secret store (~/.config/antigravity/plugin-secrets.json) is
# shared with the fleet, and agy's tool subprocesses inherit this wrapper's
# budget bus, so a tool that itself needs the login keyring will not find it.
#
# The state root defaults to ~/.agy2 and moves with FM_AGY2_ROOT. It holds the
# gemini tree, the private bus socket, the private keyring store, the unlock
# passphrase for that store (0600, generated once - a convenience lock, not a
# secrecy boundary, since the same uid owns the files), and logs.
#
# This script is a Firstmate-owned launcher, not a supervisor: it never writes
# a task's status file, never speaks to the captain, and never runs agy's
# /login for anyone.
set -u
unset CDPATH

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { printf 'agy2: %s\n' "$*" >&2; exit 1; }
note() { printf 'agy2: %s\n' "$*" >&2; }

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

[ -n "${HOME:-}" ] || die "HOME is not set, so no state root can be located"

ROOT=${FM_AGY2_ROOT:-$HOME/.agy2}
GEMINI_DIR=$ROOT/gemini
BUS=$ROOT/bus
BUS_PID_FILE=$ROOT/bus.pid
KEYRING_DIR=$ROOT/keyring
DATA=$ROOT/data
CONFIG=$ROOT/config
CACHE=$ROOT/cache
PASS_FILE=$ROOT/passphrase
LOG_DIR=$ROOT/log
BUS_ADDR=unix:path=$ROOT/bus

# The fleet's own session bus. Captured once and re-exported into the launch so
# a nested `agy2` (or a tool that shells back into agy) still knows which bus is
# the fleet's rather than mistaking this wrapper's private bus for it.
REAL_BUS=${FM_AGY2_REAL_BUS:-${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}}

AGY_BIN=${FM_AGY2_AGY:-}

resolve_agy() {
  local candidate dir
  if [ -z "$AGY_BIN" ]; then
    candidate=$(command -v agy 2>/dev/null) || candidate=
    [ -n "$candidate" ] || die "the real 'agy' is not on PATH; install Antigravity CLI, or point FM_AGY2_AGY at it"
    case "$candidate" in
      /*) AGY_BIN=$candidate ;;
      *)
        dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || dir=
        AGY_BIN=${dir:-.}/$(basename "$candidate")
        ;;
    esac
  fi
  [ -x "$AGY_BIN" ] || die "resolved agy '$AGY_BIN' is not executable"
  # A symlink chain that loops back here would fork-bomb instead of launching.
  if [ "$(cd "$(dirname "$AGY_BIN")" && pwd -P)/$(basename "$AGY_BIN")" = "$SCRIPT_DIR/fm-agy2.sh" ]; then
    die "'agy' on PATH resolves to this wrapper; point FM_AGY2_AGY at the real Antigravity CLI"
  fi
}

require_cmd() {  # <command> <why>
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' is missing ($2)"
}

init_state() {
  umask 077
  mkdir -p "$GEMINI_DIR" "$DATA" "$CONFIG" "$CACHE" "$LOG_DIR" "$KEYRING_DIR" \
    || die "could not create the agy2 state root at $ROOT"
  # gnome-keyring refuses a control directory any other user can reach.
  chmod 700 "$ROOT" "$KEYRING_DIR" 2>/dev/null || true
  if [ ! -s "$PASS_FILE" ]; then
    (umask 077; tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32 >"$PASS_FILE") || true
    [ -s "$PASS_FILE" ] || die "could not generate $PASS_FILE"
  fi
}

bus_alive() {
  [ -S "$BUS" ] || return 1
  timeout 5 dbus-send --bus="$BUS_ADDR" --print-reply --reply-timeout=3000 \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
    >/dev/null 2>&1
}

ensure_bus() {
  bus_alive && return 0
  rm -f "$BUS"
  local out
  out=$(dbus-daemon --session --fork --address="$BUS_ADDR" --print-address=1 --print-pid=1 2>"$LOG_DIR/bus.err") || {
    die "could not start the private session bus at $BUS: $(tr '\n' ' ' <"$LOG_DIR/bus.err" 2>/dev/null)"
  }
  printf '%s\n' "$out" | tail -n 1 >"$BUS_PID_FILE"
  local _
  for _ in $(seq 1 50); do
    bus_alive && return 0
    sleep 0.1
  done
  die "the private session bus at $BUS started but never answered"
}

secrets_owner() {  # print the unique name owning org.freedesktop.secrets, or nothing
  timeout 5 dbus-send --bus="$BUS_ADDR" --print-reply --reply-timeout=3000 \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner \
    string:org.freedesktop.secrets 2>/dev/null | sed -n 's/.*string "\(.*\)"/\1/p'
}

secrets_pid() {  # <unique-name> -> pid
  timeout 5 dbus-send --bus="$BUS_ADDR" --print-reply --reply-timeout=3000 \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.GetConnectionUnixProcessID "string:$1" 2>/dev/null \
    | sed -n 's/.*uint32 \([0-9]*\)/\1/p'
}

# Refuse unless the Secret Service answering on THIS bus is this state root's
# own gnome-keyring-daemon. The check reads the daemon's own environment, which
# is the one fact an unrelated (fleet) daemon cannot carry: its data home and
# control directory are the ones this wrapper exported.
assert_keyring_is_ours() {  # <pid>
  local pid=$1 dump
  [ -n "$pid" ] && [ -r "/proc/$pid/environ" ] \
    || die "the secret service process ($pid) is not inspectable; refusing to launch on an unproven keyring"
  dump=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null) || die "could not read /proc/$pid/environ"
  case "$dump" in
    *"XDG_DATA_HOME=$DATA"*) ;;
    *) die "the secret service on the agy2 bus is not using $DATA as its store; refusing to launch" ;;
  esac
  case "$dump" in
    *"GNOME_KEYRING_CONTROL=$KEYRING_DIR"*) ;;
    *) die "the secret service on the agy2 bus is not using $KEYRING_DIR as its control directory; refusing to launch" ;;
  esac
  case "$(cat "/proc/$pid/comm" 2>/dev/null)" in
    gnome-keyring-*) ;;
    *) die "the secret service on the agy2 bus is not gnome-keyring-daemon; refusing to launch" ;;
  esac
}

ensure_keyring() {
  local owner pid _
  owner=$(secrets_owner)
  if [ -n "$owner" ]; then
    pid=$(secrets_pid "$owner")
    assert_keyring_is_ours "$pid"
    return 0
  fi
  printf '%s' "$(cat "$PASS_FILE")" \
    | env DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR" XDG_DATA_HOME="$DATA" \
        GNOME_KEYRING_CONTROL="$KEYRING_DIR" \
        gnome-keyring-daemon --unlock --components=secrets \
        --control-directory="$KEYRING_DIR" --daemonize \
        >"$LOG_DIR/keyring.env" 2>"$LOG_DIR/keyring.err" \
    || die "could not start the private gnome-keyring-daemon: $(tr '\n' ' ' <"$LOG_DIR/keyring.err" 2>/dev/null)"
  for _ in $(seq 1 50); do
    owner=$(secrets_owner)
    [ -n "$owner" ] || { sleep 0.1; continue; }
    pid=$(secrets_pid "$owner")
    assert_keyring_is_ours "$pid"
    return 0
  done
  die "the private keyring daemon started but never owned org.freedesktop.secrets on $BUS_ADDR: $(tr '\n' ' ' <"$LOG_DIR/keyring.err" 2>/dev/null)"
}

# Prove the two stores are distinct and this one is writable, by writing a
# throwaway item on this bus and requiring that (a) it reads back here and
# (b) the fleet bus does not see it. Nothing but this wrapper's own item is
# ever written, and it is removed again immediately.
assert_store_isolated() {
  local value back fleet_hit real_store our_store
  value="pid-$$-$(date +%s)"
  real_store=$(cd -P "$HOME/.local/share/keyrings" 2>/dev/null && pwd -P) || real_store=
  our_store=$(cd -P "$DATA/keyrings" 2>/dev/null && pwd -P) || our_store=
  if [ -n "$real_store" ] && [ "$real_store" = "$our_store" ]; then
    die "the agy2 store resolves to the fleet's own keyring directory ($real_store); refusing to launch"
  fi
  printf '%s' "$value" | DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR" timeout 20 \
    secret-tool store --label='firstmate agy2 isolation probe' fm-agy2-probe "$value" 2>/dev/null \
    || die "the private keyring store at $DATA is not writable, so a second identity could not be saved; run 'agy2 --agy2-status' for the daemon log"
  back=$(DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR" timeout 20 secret-tool lookup fm-agy2-probe "$value" 2>/dev/null)
  [ "$back" = "$value" ] || die "a probe item written to the private keyring did not read back; refusing to launch on an unproven store"
  fleet_hit=$(DBUS_SESSION_BUS_ADDRESS="$REAL_BUS" timeout 5 secret-tool search fm-agy2-probe "$value" 2>/dev/null)
  case "$fleet_hit" in
    *fm-agy2-probe*) die "the private store and the fleet store answered as one; refusing to launch" ;;
  esac
  DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR" timeout 20 secret-tool clear fm-agy2-probe "$value" >/dev/null 2>&1 || true
}

token_email() {  # <bus-address> -> the account email the antigravity slot holds, or nothing
  DBUS_SESSION_BUS_ADDRESS="$1" timeout 15 \
    secret-tool lookup service gemini username antigravity 2>/dev/null \
    | tr ',' '\n' \
    | sed -n 's/.*"id_token_email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

# Name the identity this wrapper is about to run as, and refuse the one state
# that must never reach a TUI: a private slot holding the fleet's own account.
assert_identity() {
  local private_email fleet_email
  private_email=$(token_email "$BUS_ADDR")
  fleet_email=$(token_email "$REAL_BUS")
  if [ -n "$private_email" ] && [ -n "$fleet_email" ] && [ "$private_email" = "$fleet_email" ]; then
    die "the agy2 store holds the FLEET account ($private_email); refusing to launch a second identity that is really the first one"
  fi
  if [ -n "$private_email" ]; then
    note "identity: $private_email (fleet: ${fleet_email:-unknown})"
  else
    note "identity: none yet in the second store (fleet: ${fleet_email:-unknown})"
    note "no second subscription is connected: in this window run /login, signed in as the second account only"
  fi
}

bring_up() {
  require_cmd dbus-daemon "the private session bus"
  require_cmd dbus-send "D-Bus health checks"
  require_cmd gnome-keyring-daemon "the private Secret Service"
  require_cmd secret-tool "reading and proving the private keyring slot"
  resolve_agy
  init_state
  # One bring-up at a time, so two simultaneous launches cannot race for the bus
  # socket or leave a half-initialised store behind.
  exec 9>"$ROOT/lock" || die "could not open $ROOT/lock"
  flock -w 60 9 || die "another agy2 launch is still setting up $ROOT"
  ensure_bus
  ensure_keyring
  assert_store_isolated
  assert_identity
  exec 9>&-
}

status() {
  local owner pid private_email fleet_email
  printf 'root:        %s\n' "$ROOT"
  printf 'gemini dir:  %s\n' "$GEMINI_DIR"
  printf 'bus:         %s%s\n' "$BUS_ADDR" "$([ -S "$BUS" ] && echo '' || echo ' (not running)')"
  owner=$(secrets_owner 2>/dev/null)
  if [ -n "$owner" ]; then
    pid=$(secrets_pid "$owner")
    printf 'secret svc:  %s pid %s\n' "$owner" "$pid"
    printf 'store:       %s\n' "$DATA/keyrings"
    printf 'control:     %s\n' "$KEYRING_DIR"
  else
    printf 'secret svc:  not running on this bus\n'
  fi
  private_email=$(token_email "$BUS_ADDR")
  fleet_email=$(token_email "$REAL_BUS")
  printf 'identity:    %s\n' "${private_email:-none stored yet}"
  printf 'fleet:       %s (bus %s)\n' "${fleet_email:-unknown}" "$REAL_BUS"
  if [ -n "$private_email" ] && [ "$private_email" = "${fleet_email:-}" ]; then
    printf 'warning:     the two stores hold the same account; agy2 would refuse to launch\n'
  fi
}

quota_windows() {  # <bus-address> [<extra agy args>...] -> reset timestamps found in /quota
  local bus=$1
  shift
  DBUS_SESSION_BUS_ADDRESS="$bus" timeout 150 "$AGY_BIN" "$@" \
    --print '/quota' --print-timeout 120s 2>/dev/null < /dev/null \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' | sort -u | tr '\n' ' '
}

verify() {
  local private_email out private_windows fleet_windows
  private_email=$(token_email "$BUS_ADDR")
  [ -n "$private_email" ] || die "no credential is stored for the second identity yet; run 'agy2' and use /login once, then retry --agy2-verify"
  note "verifying as $private_email"
  private_windows=$(quota_windows "$BUS_ADDR" --gemini_dir="$GEMINI_DIR")
  [ -n "$private_windows" ] || die "agy2 could not read its own quota; run 'agy2 --agy2-status' and check the store"
  fleet_windows=$(quota_windows "$REAL_BUS")
  printf 'agy2  windows: %s\n' "$private_windows"
  printf 'agy   windows: %s\n' "${fleet_windows:-unavailable}"
  if [ -n "$fleet_windows" ] && [ "$private_windows" = "$fleet_windows" ]; then
    die "both identities report the same reset windows, so they are the same subscription - not a second one"
  fi
  printf 'ok: the two identities report different quota windows, so they are different subscriptions\n'
}

forget() {
  local private_email
  private_email=$(token_email "$BUS_ADDR")
  if [ -z "$private_email" ]; then
    printf 'agy2: nothing stored for the second identity\n'
    return 0
  fi
  DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR" timeout 20 \
    secret-tool clear service gemini username antigravity >/dev/null 2>&1 \
    || die "could not remove the second identity's token from $DATA"
  [ -z "$(token_email "$BUS_ADDR")" ] || die "the second identity's token is still present after removal"
  printf 'agy2: removed %s from the second store only; the fleet identity on %s is untouched\n' \
    "$private_email" "$REAL_BUS"
}

case "${1:-}" in
  --agy2-help|-h|--help)
    usage
    ;;
  --agy2-root)
    printf '%s\n' "$ROOT"
    ;;
  --agy2-status)
    resolve_agy
    init_state
    ensure_bus
    ensure_keyring
    status
    ;;
  --agy2-verify)
    resolve_agy
    bring_up
    verify
    ;;
  --agy2-ready)
    # The pre-launch gate bin/fm-spawn.sh applies before it creates any pane: the
    # assertions above have already run, so all that is left is to require that
    # an identity actually exists. An agy2 pane with no credential parks on an
    # interactive login nobody is there to finish, so the spawn refuses instead.
    bring_up
    email=$(token_email "$BUS_ADDR")
    [ -n "$email" ] || die "no second Antigravity identity is stored yet; run 'agy2' and complete /login once as the second account"
    printf '%s\n' "$email"
    ;;
  --agy2-forget)
    resolve_agy
    init_state
    ensure_bus
    ensure_keyring
    forget
    ;;
  *)
    for arg in "$@"; do
      case "$arg" in
        --gemini_dir|--gemini_dir=*|--app_data_dir|--app_data_dir=*)
          die "$arg is owned by agy2 (it pins this identity's state root); drop it and retry"
          ;;
      esac
    done
    bring_up
    exec env DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR" \
      FM_AGY2_HARNESS=agy2 FM_AGY2_REAL_BUS="$REAL_BUS" FM_AGY2_ROOT="$ROOT" \
      "$AGY_BIN" --gemini_dir="$GEMINI_DIR" "$@"
    ;;
esac
