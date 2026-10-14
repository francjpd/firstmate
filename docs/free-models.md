# Free-model validation

Free-model validation is the captain's manual check of which free models the fleet can dispatch on right now, and which of them is best for a reasoning-heavy task versus a quick easy one.
It answers two questions: which free models do we actually have, and which one should reasoning work use while easy work uses the quickest.
This page is for the captain, who runs the check by hand and needs to know what it changes, what it costs, and which file owns each part of the behavior.

## What it changes and what it does not

The check changes only the fleet's free-model list and its two rankings.
It never changes dispatch configuration, and nothing here runs on a schedule: the captain invokes it, and the caching exists to make re-running cheap, not to schedule it.
The deterministic half is [`bin/fm-free-models.sh`](../bin/fm-free-models.sh), which queries three sources, probes every candidate with one tiny live completion, and keeps one cached list under the active home.
The manual half is [`.agents/skills/validate-free-models/SKILL.md`](../.agents/skills/validate-free-models/SKILL.md), which owns the status/rank/save loop and the bounded ranking research.

The three sources, checked in order:

- **OpenCode Go** - the subscription's own model list, keeping only ids ending in `-free`, which is the naming convention its free preview models use.
  The endpoint is truth, never a locally installed editor's catalog.
- **OpenRouter** - its model list filtered to zero-price models.
- **Ollama cloud** - its cloud model list, filtered the same way.
  Ollama cloud is expected to offer nothing free; the check still runs and says so plainly rather than assuming.

Every candidate is probed with one tiny live completion, because a catalog entry is not proof of a served model: a model the service answers with a model-level error is dropped rather than carried.
A candidate the script cannot verify because of a subscription-level block or a transport failure is kept and plainly reported as unverified, because a usage limit says nothing about a model being dead.

## The cheap re-run

The list is kept in a file under the active home's `data/`, with a stable fingerprint of the fetched set.
`bin/fm-free-models.sh status` compares the freshly fetched set with the stored one and prints exactly one verdict: `unchanged`, or `changed` with the added and removed ids.
On `unchanged` the check stops there - no ranking, no research, nothing written - so a second run costs only the fetch itself.
On `changed` the manual step ranks the free set and saves.

## The ranking

Ranking is bounded research, not an open-ended survey.
The reasoning order uses published benchmark data, one or two established sources and one lookup per model family at most.
The speed order uses a measured latency probe, timing one tiny completion per candidate.
Each placement records its evidence in the output file, so a later reader can challenge it.
A candidate with no published number is placed last with that stated plainly, and a candidate whose probe was blocked is not speed-ranked.

## Output files

The ranked output lives under the active home's `data/`:

- `data/free-models.md` - the human-readable twin: two ordered lists, reasoning first and speed first.
- `data/free-models.json` - the same data plus the fingerprint `status` compares against, so the one file is both the cache and the ranking.

Each model entry carries its provider, id, why it sits where it sits, and the date it was validated.

## Cost

The check spends one tiny completion per candidate per run, a handful of tokens against free tiers.
The unchanged path spends no ranking research at all.
There is no way to make the probe free without dropping the guarantee that a listed model is actually served, so that cost is deliberate.

## Files and owners

- [`.agents/skills/validate-free-models/SKILL.md`](../.agents/skills/validate-free-models/SKILL.md) owns the manual procedure, the bounded ranking research, and the evidence each placement must record.
- [`bin/fm-free-models.sh`](../bin/fm-free-models.sh) owns the fetch, the probe classification, the status verdict, the save, and the picks.
- [`docs/configuration.md`](configuration.md#find-a-setting) owns the setting-table row that points here.
- The active home's `data/free-models.json` and `data/free-models.md` own the cached list and the ranking.
