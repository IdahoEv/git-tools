#!/usr/bin/env bash
# request-review.sh — (re-)request a Copilot (and optionally Claude) PR review.
#
#   request-review.sh [--pr <N>] [--level copilot|copilot+claude] [--workflow claude.yml]
#
# Defaults: --pr resolved from the current branch's PR, --level copilot.
# Safe to call repeatedly (e.g. after every push) — GitHub allows
# re-requesting the same bot reviewer, so this is the tool to reach for when
# a push after Copilot's first pass doesn't get an automatic re-review.
#
# This is the single source of truth for the Copilot-review GraphQL
# mutation; open-pr.sh's kardashev provider delegates to it at PR-creation
# time instead of duplicating the call.
#
# Prints on success (stdout, parseable):
#   pr_number=<n>
#
# Exit codes: 0 success; 1 usage/precondition error; otherwise the
# underlying gh command's exit status propagates via set -e.

set -euo pipefail

die() { printf 'request-review: %s\n' "$*" >&2; exit 1; }

pr_number="" level="copilot" workflow="claude.yml"
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)       pr_number="${2:?--pr needs a value}"; shift 2 ;;
    --level)    level="${2:?--level needs a value}"; shift 2 ;;
    --workflow) workflow="${2:?--workflow needs a value}"; shift 2 ;;
    -h|--help)  sed -n '2,15p' "$0"; exit 0 ;;
    *)          die "unknown arg: $1" ;;
  esac
done

case "$level" in
  copilot|copilot+claude) ;;
  *) die "--level must be copilot or copilot+claude (got '$level')" ;;
esac

command -v gh >/dev/null || die "gh CLI not found"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"

if [ -z "$pr_number" ]; then
  branch="$(git branch --show-current)"
  [ -n "$branch" ] || die "not on a branch — pass --pr explicitly"
  pr_number="$(gh pr list --head "$branch" --json number --jq '.[0].number // empty')"
  [ -n "$pr_number" ] || die "no PR found for branch '$branch' — pass --pr explicitly"
fi

pr_node_id="$(gh pr view "$pr_number" --json id --jq '.id')"

# Copilot's reviewer bot is a fixed bot account; resolve its node id live
# rather than hardcoding it, in case it ever differs per install.
copilot_bot_id="$(gh api "users/copilot-pull-request-reviewer%5Bbot%5D" --jq '.node_id' 2>/dev/null || true)"
[ -n "$copilot_bot_id" ] || die "couldn't resolve Copilot bot id"

# botIds must be inlined into the query body, not passed as a `-F`/`-f`
# variable — gh api's field flags pass JSON-array-shaped strings through as
# literal strings rather than deserializing them into a GraphQL list.
gh api graphql -f query="
  mutation(\$pid: ID!) {
    requestReviews(input: { pullRequestId: \$pid, botIds: [\"$copilot_bot_id\"], union: true }) {
      clientMutationId
    }
  }" -f pid="$pr_node_id" >/dev/null \
  && echo "request-review: requested Copilot review on #$pr_number" >&2 \
  || die "Copilot review request failed"

if [ "$level" = "copilot+claude" ]; then
  gh workflow view "$workflow" >/dev/null 2>&1 || die "no $workflow workflow in this repo"
  gh workflow run "$workflow" -f "pr_number=$pr_number" >/dev/null \
    && echo "request-review: dispatched $workflow review for #$pr_number" >&2 \
    || die "$workflow dispatch failed"
fi

printf 'pr_number=%s\n' "$pr_number"
