# Model-delay mode

Model-delay is Firstmate's pacing mode for a shared, flaky model endpoint.
While it is on, agents wait between model turns so several agents' streams do not stack on the endpoint.
This page is for operators who turn Model-delay on and need to know what it changes, how to switch it, and which file owns each part of that behavior.

## What it changes and what it does not

Model-delay changes only the pace at which agents issue model calls.
It never changes what an agent does, which model it uses, or how it answers.
The pacing rule is owned by [`.agents/skills/model-delay/SKILL.md`](../.agents/skills/model-delay/SKILL.md), which fixes the pause between model turns and the free-model scope of that pause, and `bin/fm-model-delay.sh` owns the wait itself.
While the mode is on, an agent on a free-tier model runs that helper before its next model turn; the helper blocks in the foreground, prints one short line, backgrounds nothing, needs no timer or timeout, and is inert while the mode is off.
A model is free when its id ends in `-free`, the naming convention the free OpenCode Go preview uses (`opencode-go/step-5-preview-free`); that scope exists because the free endpoint is the one several agents' streams collide on, while a paid fallback endpoint does not share those refusals.
The caller names its current model to the helper in `FM_MODEL_DELAY_MODEL`, and [`bin/fm-free-model-lib.sh`](../bin/fm-free-model-lib.sh) owns the verdict both the helper and the launch brief use.
A paid model, an unknown model, and a caller that names no model are all skipped with no wait, so the pause never lands on a caller that does not need it.
Crewmates working in a project's local copy cannot discover that skill through `.agents/skills`, so their launch brief names the helper, the model it must be told, and the home's config directory as a dispatch-time contract; a task resolving to a paid or unknown model gets no pacing section at all.

## Token cost

The wait spends no model tokens.
The residual cost is what the agent spends issuing the helper call and reading its one-line result, a handful of tokens per paced turn.
Literal zero would need a per-harness hook or a gate in front of the model endpoint, and neither is harness-agnostic, so that path is not shipped here.

## Turning it on and off

The switch is the local, gitignored `config/model-delay` preference under the effective Firstmate home.
[`configuration.md`](configuration.md#model-delay-preference-configmodel-delay) owns the file format, its `on`/`off` values, the absent-file default of off, and the shared home-resolution order.
On Pi the `/model-delay` command saves the new choice before changing live presentation, exactly as `/calm` does.
A failed write leaves the current choice unchanged.
Turning the mode on or off never changes model context, session storage, or exports.

## The sandglass indicator

On Pi, while Model-delay is on, a small sandglass glyph joins the working-row presentation during an agent run, beside the Calm working boat.
[`calm.md`](calm.md#pi) owns that working-row presentation; Model-delay reuses its widget and visibility plumbing rather than installing a second one.
With Calm on, the boat and the sandglass appear together; with Calm off but Model-delay on, the sandglass replaces the stock `Working...` row on its own.
Turning the mode off restores the stock row or the plain boat immediately.

## Files and owners

- [`configuration.md`](configuration.md#model-delay-preference-configmodel-delay) owns the persisted preference file and its resolution rules.
- [`.agents/skills/model-delay/SKILL.md`](../.agents/skills/model-delay/SKILL.md) owns the pacing rule, including the fixed interval and the free-model scope.
- [`bin/fm-free-model-lib.sh`](../bin/fm-free-model-lib.sh) owns the free-tier verdict, the one rule that decides which callers pace.
- `bin/fm-model-delay.sh` owns the harness-agnostic wait, gates itself on the same `config/model-delay` switch, and spends that wait only on a free model named in `FM_MODEL_DELAY_MODEL`.
- `bin/fm-dod-lib.sh` owns the launch-brief pacing section that points crewmates who cannot discover the skill at the helper, the interval owner, the model to name, and this home's config directory.
- `.pi/extensions/lib/fm-calm-working-ship.ts` owns Pi's sandglass rendering inside the shared working widget.

## A stricter future option

Skill-level pacing is the shipped behavior.
A future strict version could throttle model calls inside a worker's runtime plugin instead, but that path is deliberately out of scope for this mode.
