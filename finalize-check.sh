#!/usr/bin/env bash
# finalize-check.sh — read-only post-merge verification for a feature branch.
#
#   finalize-check.sh [--branch <name>] [--dir <worktree>]
#
# Answers, in one call, every deterministic question /finalize used to ask the
# model to work out command-by-command: which ticket does this branch belong
# to, is there a PR, did it merge, did it actually land on the base branch, are
# there local commits the PR never saw, and where is the base worktree.
#
# Makes NO changes: no pushes, no deletes, no ticket writes. The judgment calls
# /finalize still owns — which done-state to set on Shortcut, whether to delete
# a worktree that looks off — stay in the command, same division of labor as
# open-pr.sh vs. /open-pr.
#
# Output (stdout, parseable key=value, one per line):
#   branch=<name>
#   ticket_id=<id>              (empty if unparseable)
#   ticket_scheme=shortcut|github|unknown
#   base=<branch>               (empty if unresolvable)
#   pr_number=<n>               (empty if none found)
#   pr_state=MERGED|OPEN|CLOSED|none|unknown
#   pr_merge_commit=<sha>
#   pr_head_oid=<sha>
#   head_oid=<sha>              (local tip)
#   head_matches=same|behind|ahead|diverged|unknown
#                               (local tip's relationship to the PR head)
#   merged=yes|no|unknown       (branch is an ancestor of origin/<base>)
#   base_worktree=<path>        (empty if not found)
#   worktree=<path>             (the worktree being finalized)
#   verdict=ready|not-merged|no-pr|local-commits|squash-merged|unknown
#   agent_phase=MERGED|REVIEW|  the agent-view phase this verdict implies, for
#               <empty>         the caller to pass to agent-phase.sh. Empty when
#                               the verdict doesn't justify moving the label.
#
# `verdict` is the one-line summary a caller can branch on:
#   ready          PR merged AND branch is an ancestor of origin/<base> AND
#                  local tip == PR head. Safe to clean up.
#   no-pr          no PR found for this branch — nothing to finalize.
#   not-merged     a PR exists but hasn't merged.
#   squash-merged  PR says MERGED but the branch isn't an ancestor (normal for
#                  squash/rebase merges) — caller should confirm before deleting.
#   local-commits  PR merged, but the local branch is ahead of or diverged from
#                  the PR head: there is work here the PR never contained.
#                  Caller must stop. (A branch merely *behind* the PR head is a
#                  stale worktree with nothing to lose — that stays `ready`.)
#   unknown        couldn't determine (no gh/jq, not the right host, no base,
#                  or the PR-head commit isn't available locally).
#
# Exit codes: 0 always when it could inspect the repo (read `verdict`, not $?);
#             1 usage/precondition error (not a repo, detached HEAD).

set -euo pipefail

die() { printf 'finalize-check: %s\n' "$*" >&2; exit 1; }

# ---- resolve our own dir (following symlinks) -----------------------------
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# shellcheck source=lib/repo-facts.sh
. "$SCRIPT_DIR/lib/repo-facts.sh"

# ---- args -------------------------------------------------------------------
branch="" dir="."
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) branch="${2:?--branch needs a value}"; shift 2 ;;
    --dir)    dir="${2:?--dir needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    *)        die "unknown arg: $1" ;;
  esac
done

git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo: $dir"
[ -n "$branch" ] || branch="$(git -C "$dir" branch --show-current)"
[ -n "$branch" ] || die "not on a branch (detached HEAD) — pass --branch"

worktree="$(cd -P "$(git -C "$dir" rev-parse --show-toplevel)" && pwd)"

# ---- ticket -----------------------------------------------------------------
ticket_id="$(gt::ticket_from_branch "$branch")"
ticket_scheme="$(gt::ticket_scheme "$branch")"

# ---- base branch ------------------------------------------------------------
base="$(gt::default_branch "$dir" || true)"

# ---- PR ---------------------------------------------------------------------
# Shortcut-tracked repos still host their PRs on GitHub, so `gh` is the right
# first try regardless of which tracker owns the ticket. A non-GitHub host
# leaves these empty and the verdict `unknown`, which the caller reports rather
# than acting on.
pr_number="" pr_state="none" pr_merge_commit="" pr_head_oid=""
if command -v gh >/dev/null && command -v jq >/dev/null; then
  # Distinguish "query succeeded, no PR" from "query failed": both yield an
  # empty string, but conflating them would report an auth/network/wrong-repo
  # error as verdict=no-pr — i.e. "nothing to finalize", which reads like a
  # clean answer. Only a zero exit may leave pr_state at "none".
  if pr_json="$(cd "$worktree" && gh pr list --head "$branch" --state all \
      --json number,state,mergedAt,mergeCommit,headRefOid \
      --jq 'sort_by(.number) | last // empty' 2>/dev/null)"; then
    if [ -n "$pr_json" ]; then
      pr_number="$(printf '%s' "$pr_json"      | jq -r '.number // empty')"
      pr_state="$(printf '%s' "$pr_json"       | jq -r '.state // "unknown"')"
      pr_merge_commit="$(printf '%s' "$pr_json"| jq -r '.mergeCommit.oid // empty')"
      pr_head_oid="$(printf '%s' "$pr_json"    | jq -r '.headRefOid // empty')"
    fi
  else
    pr_state="unknown"
  fi
else
  pr_state="unknown"
fi

# ---- merged? ----------------------------------------------------------------
# Always compare against origin/<base>: the local base ref is frequently stale.
merged="unknown"
if [ -n "$base" ]; then
  git -C "$worktree" fetch --quiet origin "$base" 2>/dev/null || true
  if git -C "$worktree" rev-parse --verify --quiet "origin/$base" >/dev/null; then
    if git -C "$worktree" merge-base --is-ancestor "$branch" "origin/$base" 2>/dev/null; then
      merged="yes"
    else
      merged="no"
    fi
  fi
fi

# ---- local tip vs PR head ---------------------------------------------------
# The PR only proves its *remote head* merged. Commits added locally after the
# last push are invisible to it and would be destroyed by a branch delete.
#
# What matters is ANCESTRY, not OID equality: a mismatch alone doesn't mean
# local work exists. If someone else pushed the final commit and this worktree
# never pulled, the local tip is *behind* the PR head — nothing to lose, and
# treating it as local work would block cleanup for no reason.
#   same     local tip == PR head
#   behind   local tip is an ancestor of the PR head (stale worktree, safe)
#   ahead    PR head is an ancestor of local tip (real local-only commits)
#   diverged both sides have commits the other lacks (also unsafe)
#   unknown  the PR-head object isn't present locally, so ancestry is unprovable
head_oid="$(git -C "$worktree" rev-parse HEAD)"
head_matches="unknown"
if [ -n "$pr_head_oid" ]; then
  if [ "$head_oid" = "$pr_head_oid" ]; then
    head_matches="same"
  elif ! git -C "$worktree" cat-file -e "${pr_head_oid}^{commit}" 2>/dev/null; then
    # Not fetched (or garbage-collected after a merged branch was deleted).
    # Try once, then give up rather than guessing.
    git -C "$worktree" fetch --quiet origin "$pr_head_oid" 2>/dev/null || true
    git -C "$worktree" cat-file -e "${pr_head_oid}^{commit}" 2>/dev/null \
      || head_matches="unknown"
  fi
  if [ "$head_matches" = "unknown" ] && git -C "$worktree" cat-file -e "${pr_head_oid}^{commit}" 2>/dev/null; then
    if git -C "$worktree" merge-base --is-ancestor "$head_oid" "$pr_head_oid" 2>/dev/null; then
      head_matches="behind"
    elif git -C "$worktree" merge-base --is-ancestor "$pr_head_oid" "$head_oid" 2>/dev/null; then
      head_matches="ahead"
    else
      head_matches="diverged"
    fi
  fi
fi

# ---- base worktree ----------------------------------------------------------
# worktree-manager.sh's layout puts every worktree as a sibling under the repo
# family dir, so the base branch has one too. Find it by branch, not by name.
base_worktree=""
if [ -n "$base" ]; then
  base_worktree="$(git -C "$worktree" worktree list --porcelain \
    | awk -v b="refs/heads/$base" '
        /^worktree /{wt=substr($0,10)}
        $0=="branch "b{print wt; exit}')"
fi

# ---- verdict ----------------------------------------------------------------
if   [ -z "$pr_number" ] && [ "$pr_state" != "unknown" ]; then verdict="no-pr"
elif [ "$pr_state" = "unknown" ] || [ "$merged" = "unknown" ]; then verdict="unknown"
elif [ "$pr_state" != "MERGED" ]; then verdict="not-merged"
# Only ahead/diverged mean there is local work the PR never contained. `behind`
# is a stale worktree with nothing to lose, so it's safe to clean up.
elif [ "$head_matches" = "ahead" ] || [ "$head_matches" = "diverged" ]; then verdict="local-commits"
elif [ "$head_matches" = "unknown" ]; then verdict="unknown"
elif [ "$merged" = "no" ]; then verdict="squash-merged"
elif [ "$merged" = "yes" ]; then verdict="ready"
else verdict="unknown"
fi

printf 'branch=%s\nticket_id=%s\nticket_scheme=%s\nbase=%s\n' \
  "$branch" "$ticket_id" "$ticket_scheme" "$base"
printf 'pr_number=%s\npr_state=%s\npr_merge_commit=%s\npr_head_oid=%s\n' \
  "$pr_number" "$pr_state" "$pr_merge_commit" "$pr_head_oid"
printf 'head_oid=%s\nhead_matches=%s\nmerged=%s\n' \
  "$head_oid" "$head_matches" "$merged"
# ---- implied agent-view phase -----------------------------------------------
# Which workflow phase the agent-view row should show, derived from the verdict
# so /finalize doesn't re-reason about it. This script stays read-only (it
# reports, it does not stamp) — the caller runs agent-phase.sh with this value.
#
# DONE is deliberately absent: it means "/finalize has finished and the session
# is safe to kill", which is only true after cleanup actually ran, and cleanup
# is the caller's job. Verdicts that mean "stop and look" (local-commits,
# unknown, no-pr) leave this empty rather than guessing — a wrong label on a
# branch that needs attention is worse than no change.
case "$verdict" in
  ready|squash-merged) agent_phase="MERGED" ;;
  not-merged)          agent_phase="REVIEW" ;;
  *)                   agent_phase="" ;;
esac

printf 'base_worktree=%s\nworktree=%s\nverdict=%s\nagent_phase=%s\n' \
  "$base_worktree" "$worktree" "$verdict" "$agent_phase"
