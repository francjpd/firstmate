---
name: model-delay
description: Load when this Firstmate home has model-delay on, before a model turn on a shared flaky endpoint, or when the captain asks about the model-call pacing mode.
user-invocable: false
metadata:
  internal: true
---

# model-delay

This skill owns Firstmate's model-call pacing rule for a shared, flaky model endpoint.
The switch is the local, gitignored `config/model-delay` preference that [`docs/configuration.md`](../../../docs/configuration.md#model-delay-preference-configmodel-delay) owns; `on` enables pacing, and `off` or an absent file disables it.
While the mode is on, pause 45 seconds between model turns so several agents' streams do not stack on the endpoint.
The simplest way to enforce the pause is to run `sleep 45` as the last command of a turn, before you end it, so the model call that follows the next turn starts only after the gap.
Keep the pause fixed at 45 seconds unless the captain names another interval, and never skip it while the mode is on.
The mode changes pace only: it never changes what you do, which model you use, or what you write.
A crewmate working in a project's local copy cannot discover this skill through `.agents/skills`, so its launch brief carries the same pacing contract and a path fallback to this file; follow whichever you received.
