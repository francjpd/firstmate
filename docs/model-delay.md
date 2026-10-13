# Model-delay mode

Model-delay is Firstmate's pacing mode for a shared, flaky model endpoint.
While it is on, agents wait between model turns so several agents' streams do not stack on the endpoint.
This page is for operators who turn Model-delay on and need to know what it changes, how to switch it, and which file owns each part of that behavior.

## What it changes and what it does not

Model-delay changes only the pace at which agents issue model calls.
It never changes what an agent does, which model it uses, or how it answers.
The pacing rule is owned by [`.agents/skills/model-delay/SKILL.md`](../.agents/skills/model-delay/SKILL.md), which fixes the pause between model turns.
Crewmates working in a project's local copy cannot discover that skill through `.agents/skills`, so their launch brief carries a pointer to the same rule as a dispatch-time contract.

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
- `.agents/skills/model-delay/SKILL.md` owns the pacing rule, including the fixed interval.
- `bin/fm-dod-lib.sh` owns the launch-brief pacing section that carries the rule to crewmates who cannot discover the skill.
- `.pi/extensions/lib/fm-calm-working-ship.ts` owns Pi's sandglass rendering inside the shared working widget.

## A stricter future option

Skill-level pacing is the shipped behavior.
A future strict version could throttle model calls inside a worker's runtime plugin instead, but that path is deliberately out of scope for this mode.
