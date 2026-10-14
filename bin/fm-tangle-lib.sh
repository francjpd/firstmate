# shellcheck shell=bash
# Shared worktree-tangle guard for the firstmate-on-itself case.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: crewmate worktrees and
# secondmate homes are all linked `git worktree`s of the same repo, while the
# PRIMARY checkout (the repo root firstmate operates from) is a normal checkout
# on a real branch - normally the default branch, main. The "worktree tangle"
# failure mode is a crewmate spawned to work on firstmate ITSELF branching and
# committing in the primary checkout instead of its own disposable worktree,
# stranding the primary on a feature branch (e.g. fm/readme-restructure-d3).
#
# fm_primary_tangle_branch detects exactly that and nothing else: a NAMED,
# non-default branch checked out in the given root. It is deliberately silent for
# every legitimate state - the primary on its default branch, and detached HEAD,
# which is how every linked worktree and secondmate home legitimately sits on the
# default branch. Detached HEAD on the default is fine; a feature branch in a
# primary checkout is the alarm.

# Resolve the default branch name of the git repo at <dir>: prefer origin/HEAD,
# then fall back to a local main/master. Echoes the name, or returns 1.
fm_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Echo the declared integration branch only when it is genuinely local-only for
# this repo: <config-dir>/integration-branch names it, the branch exists as a
# local ref of <dir>, and origin has no branch of that name. Return 1 otherwise.
#
# A spawn base normally comes from origin, so a home whose own work sits on a
# local integration branch that is never pushed needs this answer to resolve that
# base from the local ref instead. Requiring the branch to be absent from origin
# keeps the exception from silently covering a branch that origin really has.
# Echoes the name, or returns 1.
fm_local_integration_branch() {  # <dir> [<config-dir>]
  local dir=$1 config_dir=${2:-} branch
  [ -n "$config_dir" ] && [ -f "$config_dir/integration-branch" ] || return 1
  branch=$(tr -d '[:space:]' <"$config_dir/integration-branch" 2>/dev/null || true)
  [ -n "$branch" ] || return 1
  git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" || return 1
  git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$branch" && return 1
  printf '%s\n' "$branch"
}

# Resolve the branch a home's primary checkout is expected to sit on: the
# home-declared integration branch when <config-dir>/integration-branch names one
# that exists as a local branch of <dir>, else the repo's default branch.
#
# A home may keep its own work on an integration branch while the repo's default
# branch stays a pristine mirror of upstream, so every "is the primary on the
# branch it should be on" decision must ask this question rather than
# fm_default_branch. An absent, empty, or unknown declaration changes nothing.
# Echoes the name, or returns 1.
fm_integration_branch() {  # <dir> [<config-dir>]
  local dir=$1 config_dir=${2:-} branch
  if [ -n "$config_dir" ] && [ -f "$config_dir/integration-branch" ]; then
    branch=$(tr -d '[:space:]' <"$config_dir/integration-branch" 2>/dev/null || true)
    if [ -n "$branch" ] && git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  fi
  fm_default_branch "$dir"
}

# If the git checkout at <root> is tangled - on a NAMED branch that is not the
# branch it is expected to sit on - echo the offending branch name and return 0.
# For every healthy state (not a git work tree, detached HEAD, or already on the
# expected branch) echo nothing and return 1. Detached HEAD is how linked
# worktrees and secondmate homes legitimately sit, so they never trip this; only
# a feature branch checked out in a primary checkout does.
fm_primary_tangle_branch() {  # <root> [<config-dir>]
  local root=$1 config_dir=${2:-} cur expected
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  expected=$(fm_integration_branch "$root" "$config_dir") || return 1
  [ "$cur" = "$expected" ] && return 1
  printf '%s\n' "$cur"
  return 0
}
