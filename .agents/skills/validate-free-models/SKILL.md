---
name: validate-free-models
description: Load only when the captain asks to validate, refresh, or check the fleet's free-model list - which free models exist right now, or which free model is best for reasoning-heavy versus quick work - never on every session.
user-invocable: true
---

# validate-free-models

This skill owns the manual half of the free-model validation surface.
The deterministic half is [`bin/fm-free-models.sh`](../../../bin/fm-free-models.sh), which fetches the candidate set, probes every candidate with one tiny live completion, and keeps one cached list under the active home.
This skill owns the decision loop and the ranking research; the script never ranks anything and nothing here schedules anything.

Run the loop in order:

1. Run `bin/fm-free-models.sh status`.
2. On `status: unchanged`, report that the list is current and stop.
   No ranking, no research, no save: the cheap path is the whole point.
3. On `status: changed`, rank the free set as bounded research, below.
4. Write the ranked output to `data/free-models.md` and `data/free-models.json` under the active home, then run `bin/fm-free-models.sh save` to stamp the fingerprint the next `status` compares against.
5. Run `bin/fm-free-models.sh picks` and report the two top picks to the captain.

## Ranking is bounded research, not an open-ended survey

Rank the free set two ways, and record the evidence behind each placement in the output file so a later reader can challenge it.

- **Reasoning order** uses published benchmark data.
  Check one or two established benchmark sources for the candidates (an artificial-analysis-style intelligence index and a coding benchmark such as SWE-bered or Terminal-Bench), one lookup per model family at most, and stop there.
  Do not survey every leaderboard on the internet.
  When a candidate has no published number, place it last with that stated plainly rather than guessing.
- **Speed order** uses a measured latency probe.
  Time one tiny completion per candidate with the script's own probe (`FM_FREE_MODELS_TIMEOUT` bounds it), and order by the measured latency.
  A candidate whose probe was blocked or unverified is not speed-ranked; say so instead of ordering it.

Each model entry in the output files carries its provider, id, why it sits where it sits, and the date it was validated, so the one file is both the cache and the ranking.
`data/free-models.json` is the cache: it holds the same ranked data plus the fingerprint `status` compares against.
Keep the credential store read-only: never write a key, a provider response, or a probe response into the output files.

The three sources are the OpenCode Go subscription's free ids, OpenRouter's zero-price models, and Ollama cloud's free models, which are expected to be none.
The script checks all three and says plainly what each offered, including when one offers nothing.

Crewmates working in a project's local copy cannot discover this skill through `.agents/skills`, so a launch brief names the script and the procedure; follow whichever you received.
