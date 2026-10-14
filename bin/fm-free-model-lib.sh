# shellcheck shell=bash
# Shared free-tier model classification used by Model-delay pacing.
# Usage: . bin/fm-free-model-lib.sh; fm_model_is_free "<model-id>"
#
# ONE OWNER for the verdict "is this model free", because two callers need it
# and must never drift apart: bin/fm-model-delay.sh gates its wait on it, and
# bin/fm-dod-lib.sh's launch-brief pacing section emits only for a free model.
# One owner is what keeps a brief that carries the pacing contract and a helper
# that skips it from disagreeing about the same model.
#
# A model id is free when it ends in "-free", the naming convention the free
# OpenCode Go preview uses (opencode-go/step-5-preview-free). The rule is a
# naming convention rather than an allowlist in config/: the free tier is a
# provider property no home can enumerate, and the classification is only ever
# a pacing scope, not a trust or quota decision.
#
# An absent or unrecognized id is not free. Pacing therefore stops instead of
# guessing, which is the safe direction: a missed pause on an already free
# endpoint is the flakiness this mode exists to spread out, while an unnecessary
# pause on a paid endpoint only costs time.
fm_model_is_free() {  # <model-id>
  case "${1:-}" in
  *-free) return 0 ;;
  *) return 1 ;;
  esac
}
