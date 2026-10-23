# Verification: the agy2 (second Antigravity identity) crewmate/scout adapter

Active empirical facts for firstmate's `agy2` adapter, the same Antigravity CLI running as a second Antigravity account on one Unix user.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/agy2.md`](../../.agents/skills/harness-adapters/references/harness/agy2.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `agy 1.4.6` (Go-compiled ELF single binary, stripped) |
| Verified | 2026-10-23 |
| Binary | `/home/francjpd/.local/bin/agy`, launched through `bin/fm-agy2.sh` |
| Platform | Linux x64, one Unix user, `gnome-keyring-daemon` and `dbus-daemon` from the distro |
| Backend | local probes plus an isolated non-`default` Herdr lab session created with `bin/fm-herdr-lab.sh` |

Every probe below ran in a disposable state root under the private task data directory or in the Herdr lab, never in the live `~/.gemini` tree.
The fleet's own credential file was read only, and its md5 was recorded before and after: `aa1550d21c5dc9628ac296e00be03103` with exactly one item carrying `value=antigravity`, unchanged across every step below.

## The identity lives in one keyring slot per Unix user

```
$ secret-tool lookup service gemini username antigravity    # on the fleet bus
{"token":{"access_token":"ya29...", ...}, "auth_method":"consumer", "id_token_email":"spirituz@gmail.com"}
```

The slot is keyed by the fixed attributes `service=gemini, username=antigravity`, agy reads it through the Secret Service API on `DBUS_SESSION_BUS_ADDRESS`, and the file store is a fallback reached only when that call errors:

```
W composite_token_storage.go:419] Failed to load stored token from keyring, falling back to file: dial unix /nonexistent-agy2-bus: connect: no such file or directory
```

## A private Secret Service holds a stable second identity

A private bus plus a private `gnome-keyring-daemon` (own control directory, own `XDG_DATA_HOME`) creates its own store and sees nothing of the fleet's:

```
$ dbus-run-session -- env XDG_DATA_HOME=<root>/data XDG_RUNTIME_DIR=<root>/run \
    bash -c 'gnome-keyring-daemon --unlock --components=secrets --control-directory=<root>/control --daemonize
             secret-tool search service gemini username antigravity'
(no output: the fleet slot is not visible on this bus)
store created: <root>/data/keyrings/login.keyring, <root>/data/keyrings/user.keystore
```

agy resolves its identity from that slot, and from nowhere else.
With a synthetic token planted there (a fake value, never a real credential) the CLI loaded it and named that identity:

```
I keyring.go:64] keyringAuth: loaded token, expiry=2030-01-01 00:00:00 +0000 UTC expired=false
I auth.go:157] ChainedAuth: authenticated via keyring (effective: keyring)
I server_oauth.go:224] applyAuthResult: email=second.subscription@example.invalid, authMethod=consumer, quotaProject=
```

The identity is stable across daemon restarts: a fresh bus and a fresh daemon pointed at the same private data home read the same slot back and still could not see the fleet's item.

## Why the two alternatives were rejected

Unreachable bus, the documented file fallback:

```
$ DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent-agy2-bus agy --gemini_dir=<root> --print hi
Authentication required. Please visit the URL to log in:
```

No token file appeared anywhere in that state root, so the second store has no nameable path until a real login writes one; and the same install authenticates as the fleet account the moment a working bus is present, which is the fail-open the wrapper exists to prevent.
On the fleet bus, `secret-tool lookup service gemini username antigravity` returns the fleet token regardless of the state root, so identity never follows state.

API key, `modelProvider: "gemini"` in `settings.json` plus `GEMINI_API_KEY`:

```
GEMINI_API_KEY=AIzaSyFAKE... agy --gemini_dir=<root> --print 'reply OK'
error: ... Error 400, Message: API key not valid. ... reason:API_KEY_INVALID ... metadata:map[service:generativelanguage.googleapis.com]
I auth.go:157] ChainedAuth: authenticated via gemini_api_key (effective: gemini_api_key)
I server_oauth.go:224] applyAuthResult: email=, authMethod=gemini_api_key, quotaProject=
I quota_manager.go:36] doRefreshQuota: skipped (not logged in)
```

The keyring was consulted zero times in that run, so an API key genuinely needs no slot - but it carries no account identity and calls the Gemini Developer API directly, and the subscription quota summary is never fetched.
agy's own changelog states the same: `GEMINI_API_KEY` "lets the CLI run against the Gemini API directly without signing in".
It is therefore API-billed, not subscription-drawn, and cannot serve a second subscription.

## The wrapper refuses every unsafe state

```
$ <plant a token whose email is the fleet account in the private slot>
$ bin/fm-agy2.sh --print 'this must never run'
agy2: the agy2 store holds the FLEET account (spirituz@gmail.com); refusing to launch a second identity that is really the first one
exit 1

$ bin/fm-agy2.sh --agy2-ready            # nothing stored yet
agy2: no second Antigravity identity is stored yet; run 'agy2' and complete /login once as the second account
exit 1

$ bin/fm-agy2.sh --print 'x' --gemini_dir=/tmp/other
agy2: --gemini_dir=/tmp/other is owned by agy2 (it pins this identity's state root); drop it and retry
```

Before every launch the wrapper also proves the Secret Service answering its bus is its OWN daemon (by reading that daemon's `/proc/<pid>/environ` for this state root's data home and control directory), that the private store path differs from `~/.local/share/keyrings`, and that a probe item written on the private bus reads back there while remaining invisible on the fleet bus.
A daemon that is not its own, a store that is not writable, or a store that answers as the fleet's each stop the launch.

## Dispatch path

`bin/fm-spawn.sh` resolves `agy2` from `PATH` (falling back to this repository's `bin/fm-agy2.sh`), validates a requested model through `agy2 models`, pre-registers the worktree in the second identity's own settings store through `bin/fm-agy-trust.sh --gemini-dir <root>/gemini`, and refuses the spawn when no distinct identity is stored.
`bin/fm-harness.sh` names the worker `agy2` from the `FM_AGY2_HARNESS=agy2` launch marker, folding it onto the `agy` family so ancestry still decides ownership.
Control, busy state, interrupt, and exit are the `agy` tables unchanged, reached through `fm_control_harness_family`'s `agy2 -> agy` fold.

## Still unproven

The decisive "two real subscriptions authenticated at the same time" run needs a second Google account that actually holds a subscription, which is the captain's own one-time `/login`.
Until then, the mechanism is proven with a synthetic token in the private slot (which is exactly the read path a real token takes), and `agy2 --agy2-verify` is the command that completes the proof by printing both identities' quota windows.
`--gemini_dir` is a hidden agy flag rather than a documented one, so it is the piece to re-check after an `agy update`; `agy2 --agy2-status` shows the resolved root if it ever stops taking effect.
