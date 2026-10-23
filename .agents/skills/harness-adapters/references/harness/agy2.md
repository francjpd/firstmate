# Antigravity CLI, second identity (agy2)

`agy2` is the same Antigravity CLI (`agy`) running as a SECOND Antigravity account on this same Unix user, launched by [`bin/fm-agy2.sh`](../../../../../bin/fm-agy2.sh).
Verified end to end on 2026-10-23 with agy 1.4.6 on Linux through the Herdr backend, on the identity mechanism and the dispatch path.
Verified as a CREWMATE and SCOUT adapter only, exactly like `agy`.
`../../../../../docs/verification/agy2.md` owns how every fact below was established and what is still unproven.

## What it is, and what it is not

`agy2` is a standalone command, not a flag, mode, or subcommand of `agy`: it is the same binary, handed a different identity and a different state root, so the captain can type `agy2` wherever he types `agy` and gets the same TUI speaking for the second subscription.
`agy` itself is untouched and keeps working exactly as before, and both can run at the same time.
The binding is permanent rather than per-session: the identity lives in that account's own OS keyring slot, so nothing in a later launch can drift back to the first subscription.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `agy2`, a symlink to [`bin/fm-agy2.sh`](../../../../../bin/fm-agy2.sh), resolved from `PATH` by [`bin/fm-spawn.sh`](../../../../../bin/fm-spawn.sh); that script resolves the real `agy` from `PATH` and execs it, so the live process name is still `agy`. |
| Launch | `agy2 --prompt-interactive "<brief>" --model <id> --effort <level> --dangerously-skip-permissions`, identical to `agy`; the wrapper appends its own `--gemini_dir` and refuses a caller-supplied one. |
| Identity | The wrapper runs its own `dbus-daemon` and its own `gnome-keyring-daemon` on a private socket under `~/.agy2`, so agy's keyring lookup reaches a second `service=gemini, username=antigravity` slot that no other process sees. |
| State root | `~/.agy2` (`FM_AGY2_ROOT`), holding `gemini/` (the `--gemini_dir`), `data/keyrings/` (the private store), `keyring/` (the control socket), and `log/`. |
| Busy state | Identical to `agy`: no hook surface, so nothing is armed and the `agy-regex` rendered-tail fallback classifies it. |
| Rendered tail | Identical to `agy`: `esc to cancel` on the busy status row, `? for shortcuts` when idle. |
| Turn end | Identical to `agy`: worker status protocol, and on Herdr the native return to `idle`. |
| Exit | `/quit`, one Enter, identical to `agy`. |
| Interrupt | Single `Escape`, identical to `agy`. |
| Model | `--model <id>` with the bare catalog id from `agy2 models`; the pre-launch probe runs through the wrapper, so it reads the second identity's own catalog. |
| Effort | `--effort low\|medium\|high`; `xhigh` and `max` stay in task metadata under the record-and-omit contract. |
| Credential | A second subscription's own OAuth token, stored in the second keyring slot; the spawn refuses a launch when that slot is empty. |

## Why the identity mechanism is a private Secret Service

agy resolves its account from exactly one OS keyring item per Unix user, keyed by the fixed attributes `service=gemini, username=antigravity`, and it consults that keyring first: the file-backed store is reached only when the keyring call ERRORS (`composite_token_storage.go:419`).
`HOME`, `XDG_*`, and `--gemini_dir` move state and never identity, and a private D-Bus session on its own is not enough because the daemon that answers it is the one already running for that user.
The wrapper therefore isolates the keyring SERVICE: its own bus socket, its own `gnome-keyring-daemon` with its own control directory and its own data home.
Two alternatives were tested and rejected:

- **Deliberately unreachable keyring** (the documented file fallback): it makes the second store a file whose path cannot be named in advance and exists only after a real login, and it fails open, because any process handed a working bus silently reverts to the fleet identity.
- **`GEMINI_API_KEY` with `modelProvider: "gemini"`**: the chain selects auth method `gemini_api_key` with the keyring never consulted at all, but it carries no account identity and calls `generativelanguage.googleapis.com`, so it is Gemini-API billed and does not draw the subscription quota pools `agy --print /quota` reports.
  A key that bypasses the subscription defeats the purpose of a second subscription.

## What the wrapper asserts before the TUI starts

Each check refuses loudly instead of falling back, and [`bin/fm-agy2.sh`](../../../../../bin/fm-agy2.sh)'s header owns the exact order:

1. The Secret Service on the wrapper's bus is served by a `gnome-keyring-daemon` whose own environment carries this state root's control directory and data home, which no unrelated daemon can carry.
2. The private store path differs from the fleet's `~/.local/share/keyrings`.
3. A probe item written on the private bus reads back there and is invisible on the fleet bus, proving the two stores are distinct and this one is writable - the exact capability agy needs to save a token.
4. The identity the private slot holds is not the fleet's account; a private slot holding the fleet email is a hard refusal.

`agy2 --agy2-status` prints the resolved paths, the daemon pid, and both identities, and `agy2 --agy2-ready` is the pre-spawn gate that succeeds only when a distinct identity is stored.

## What is NOT isolated

Only the Gemini tree and the account identity move.
`HOME`, `XDG_CONFIG_HOME`, and every other path stay the real user's, deliberately, because a dispatched worker needs the captain's git, gh, and ssh state to do its job.
Two consequences are bounded and known: agy's own plugin secret store (`~/.config/antigravity/plugin-secrets.json`) is shared with the fleet, and agy's tool subprocesses inherit the wrapper's private bus, so a tool that itself needs the login keyring will not find it.

## Trust, and where the decision persists

The folder-trust dialog and its pre-registration are the `agy` behaviour verbatim, but the store is the SECOND identity's own: [`bin/fm-agy-trust.sh`](../../../../../bin/fm-agy-trust.sh) takes `--gemini-dir <root>` and writes `<root>/antigravity-cli/settings.json`, and [`bin/fm-spawn.sh`](../../../../../bin/fm-spawn.sh) passes the wrapper's own root so the entry never lands in the fleet's settings file.
The post-launch readiness gate is the same backstop as `agy`'s.

## The captain's single action

Once, when he has a second subscription, in a window he opens himself:

```
agy2
```

It prints `identity: none yet in the second store` and then the TUI; he runs `/login` there, opens the printed URL in a browser signed in as the SECOND account only, and pastes the authorization code back.
That code is the only value he supplies, and it lands in the private slot because this process's fleet keyring is unreachable by construction.
`agy2 --agy2-verify` then prints this identity's `/quota` windows beside the fleet's, and different reset timestamps are the proof that a second subscription - not the same one - is connected.
`agy2 --agy2-forget` removes only the second slot.

## Detection

`agy2` cannot be told from `agy` by process name, because the wrapper execs the same binary.
[`bin/fm-harness.sh`](../../../../../bin/fm-harness.sh) therefore reads `FM_AGY2_HARNESS=agy2`, a Firstmate-owned launch marker the wrapper sets at its own launch boundary, in the `pi-signed` shape: the marker names the identity, ancestry still proves the family, and `harness_family` folds `agy2` back to `agy` so a fleet `agy` session that never saw the marker is unaffected.
The fleet `agy` launch clears the marker so an inherited value cannot rename it.

## Dispatch

`agy2` is a dispatchable harness: [`bin/fm-spawn.sh`](../../../../../bin/fm-spawn.sh) resolves the launcher, validates a requested model against `agy2 models`, pre-registers trust in the second identity's store, and refuses the launch when no second identity is stored.
Because `config/crew-dispatch.json` is captain-private, its live rule is applied by the captain's home rather than shipped here; the rule shape is:

```json
{
  "when": "The captain asked for agy2 or the second Antigravity subscription.",
  "use": { "harness": "agy2" },
  "why": "agy2 is the second Antigravity identity on this machine."
}
```

## Primary integration

Unsupported, exactly as for `agy`: `../../../../../docs/supervision-protocols/` carries no Antigravity wake protocol, no turn-end guard adapter exists, and only the crewmate-side launch, busy state, interrupt, and exit are verified.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies.
