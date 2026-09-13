#!/usr/bin/env bash
# ship.sh — push the current branch, open (or reuse) its PR, and trigger review bots.
#
#   ship.sh --title "Is<NNN>: <short title>" --body-file <path> [--issue <N>]
#           [--review none|copilot|copilot+claude]
#
# Assumes the working tree is already committed — this script never commits.
# It handles the mechanical, judgment-free parts of `/ship`: push, PR
# create-or-reuse, and review-bot triggering. Commit-message drafting, PR
# title/body drafting, and the "wait for explicit approval before doing
# anything" rule all stay in the calling command (.claude/commands/ship.md),
# same division of labor as start-ticket.sh vs. /start's kickoff enrichment.
#
# On success, prints (stdout, parseable):
#   pr_number=<n>
#   pr_url=<url>
#   pr_action=created|reused
#
# Exit codes: 0 success; 1 usage/precondition error (die); otherwise the
# underlying git/gh command's exit status propagates via set -e.

set -euo pipefail

die() { printf 'ship: %s\n' "$*" >&2; exit 1; }

title="" body_file="" issue="" review="copilot"
while [ $# -gt 0 ]; do
  case "$1" in
    --title)     title="${2:?--title needs a value}"; shift 2 ;;
    --body-file) body_file="${2:?--body-file needs a value}"; shift 2 ;;
    --issue)     issue="${2:?--issue needs a value}"; shift 2 ;;
    --review)    review="${2:?--review needs a value}"; shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *)           die "unknown arg: $1" ;;
  esac
done

case "$review" in
  none|copilot|copilot+claude) ;;
  *) die "--review must be none, copilot, or copilot+claude (got '$review')" ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"
command -v gh >/dev/null || die "gh CLI not found"

branch="$(git branch --show-current)"
[ -n "$branch" ] || die "not on a branch (detached HEAD)"
case "$branch" in
  main|master|development) die "refusing to ship from $branch" ;;
esac

# ---- PR: reuse if one already exists for this branch, else create ---------
# Decide (and validate inputs) before pushing, so a usage error can't leave
# a published branch behind as a side effect.
existing_pr="$(gh pr view --json number --jq '.number' 2>/dev/null || true)"
create_pr=""
if [ -n "$existing_pr" ]; then
  pr_number="$existing_pr"
  pr_action="reused"
else
  create_pr=1
  [ -n "$title" ] || die "no existing PR for '$branch' and no --title given"
  if [ -n "$body_file" ] && [ ! -f "$body_file" ]; then
    die "--body-file not found: $body_file"
  fi
  # The default PR body ("Closes #N") needs an issue number; infer it from
  # the branch name (worktree-manager formats: "<issue>-slug", "sc-<ticket-id>").
  if [ -z "$body_file" ] && [ -z "$issue" ]; then
    if [[ "$branch" =~ ^([0-9]+)-.+$ || "$branch" =~ ^sc-([0-9]+) ]]; then
      issue="${BASH_REMATCH[1]}"
    else
      die "can't infer issue number from branch '$branch' — pass --issue or --body-file"
    fi
  fi
fi

# ---- push --------------------------------------------------------------------
git push -u origin "$branch"

if [ -n "$create_pr" ]; then
  create_args=(--title "$title" --head "$branch")
  if [ -n "$body_file" ]; then
    create_args+=(--body-file "$body_file")
  else
    create_args+=(--body "Closes #$issue")
  fi
  # gh pr create prints the new PR URL to stdout; suppress it to keep this
  # script's stdout limited to the documented key=value fields (pr_url below).
  gh pr create "${create_args[@]}" >/dev/null
  pr_number="$(gh pr view --json number --jq '.number')"
  pr_action="created"
fi

pr_url="$(gh pr view "$pr_number" --json url --jq '.url')"

# ---- reviews ----------------------------------------------------------------
if [ "$review" != "none" ]; then
  pr_node_id="$(gh pr view "$pr_number" --json id --jq '.id')"

  # Copilot's reviewer bot is a fixed bot account; resolve its node id live
  # rather than hardcoding it, in case it ever differs per install.
  copilot_bot_id="$(gh api "users/copilot-pull-request-reviewer%5Bbot%5D" --jq '.node_id' 2>/dev/null || true)"
  if [ -n "$copilot_bot_id" ]; then
    # botIds must be inlined into the query body, not passed as a `-F`/`-f`
    # variable — gh api's field flags pass JSON-array-shaped strings through
    # as literal strings rather than deserializing them into a GraphQL list
    # (confirmed against this exact mutation; see docs/plans/ship-command.md).
    gh api graphql -f query="
      mutation(\$pid: ID!) {
        requestReviews(input: { pullRequestId: \$pid, botIds: [\"$copilot_bot_id\"], union: true }) {
          clientMutationId
        }
      }" -f pid="$pr_node_id" >/dev/null \
      && echo "ship: requested Copilot review on #$pr_number" >&2 \
      || echo "ship: WARN Copilot review request failed" >&2
  else
    echo "ship: WARN couldn't resolve Copilot bot id, skipping Copilot review request" >&2
  fi

  if [ "$review" = "copilot+claude" ]; then
    gh workflow run claude.yml -f "pr_number=$pr_number" \
      && echo "ship: dispatched claude.yml review for #$pr_number" >&2 \
      || echo "ship: WARN claude.yml dispatch failed" >&2
  fi
fi

printf 'pr_number=%s\npr_url=%s\npr_action=%s\n' "$pr_number" "$pr_url" "$pr_action"
