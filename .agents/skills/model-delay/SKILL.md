---
name: model-delay
description: Load when this Firstmate home has model-delay on and this session runs a free-tier model (an id ending in `-free`), before a model turn on a shared flaky endpoint, or when the captain asks about the model-call pacing mode.
user-invocable: false
metadata:
  internal: true
---

# model-delay

This skill owns Firstmate's model-call pacing rule for a shared, flaky model endpoint.
The switch is the local, gitignored `config/model-delay` preference that [`docs/configuration.md`](../../../docs/configuration.md#model-delay-preference-configmodel-delay) owns; `on` enables pacing, and `off` or an absent file disables it.
While the mode is on, a session on a free-tier model pauses 45 seconds between model turns so several agents' streams do not stack on the endpoint.
A model is free when its id ends in `-free`, the naming convention the free OpenCode Go preview uses (`opencode-go/step-5-preview-free`); a paid fallback is not free and skips the pause entirely.
Run `FM_MODEL_DELAY_MODEL=<this session's model id> bin/fm-model-delay.sh 45` as the last command of a turn, before you end it, so the model call that follows the next turn starts only after the gap.
That helper owns the wait: it blocks in the foreground for the interval, prints one short line, and backgrounds nothing.
It gates that wait on the free-model verdict [`bin/fm-free-model-lib.sh`](../../../bin/fm-free-model-lib.sh) owns.
A model id that does not end in `-free`, and no model named at all, is skipped with no wait, exactly as the mode being off is.
Keep that variable pointed at the model you are actually running, so moving to a paid model mid-session stops the pause.
If you cannot tell which model this session uses, leave it unset and let the helper skip.
It is harness-agnostic and takes an explicit config directory as an optional second argument only when the caller is outside this home's tree.
Keep the pause fixed at 45 seconds unless the captain names another interval, and never skip it while the mode is on and the model is free.
The mode changes pace only: it never changes what you do, which model you use, or what you write.
The wait spends no model tokens by itself; its residual cost and the literal-zero alternative are documented in [`docs/model-delay.md`](../../../docs/model-delay.md#token-cost).
A crewmate working in a project's local copy cannot discover this skill through `.agents/skills`, so its launch brief names the helper and this home's config directory; follow whichever you received.
