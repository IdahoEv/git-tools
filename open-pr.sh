#!/usr/bin/env bash
# open-pr.sh — push the current branch, open (or reuse) its PR, and trigger review bots.
#
#   open-pr.sh [--title "Is<NNN>: <short title>"] [--body-file <path>] [--issue <N>]
#               [--review none|copilot|copilot+claude] [--provider kardashev]
#
# Assumes the working tree is already committed — this script never commits.
# It handles the mechanical, judgment-free parts of `/open-pr`: push, PR
# create-or-reuse, and review-bot triggering. Commit-message drafting, PR
# title/body drafting, and the "wait for explicit approval before doing
# anything" rule all stay in the calling command (.claude/commands/open-pr.md),
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

die() { printf 'open-pr: %s\n' "$*" >&2; exit 1; }

# ---- resolve our own dir (following symlinks) -----------------------------
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
PROVIDER_DIR="${OPEN_PR_PROVIDER_DIR:-$SCRIPT_DIR/open-pr-providers}"

# ---- args -------------------------------------------------------------------
title="" body_file="" issue="" review="copilot" provider=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title)          title="${2:?--title needs a value}"; shift 2 ;;
    --body-file)      body_file="${2:?--body-file needs a value}"; shift 2 ;;
    --issue)          issue="${2:?--issue needs a value}"; shift 2 ;;
    --review)         review="${2:?--review needs a value}"; shift 2 ;;
    --provider|--env) provider="${2:?--provider needs a value}"; shift 2 ;;
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *)                die "unknown arg: $1" ;;
  esac
done

case "$review" in
  none|copilot|copilot+claude) ;;
  *) die "--review must be none, copilot, or copilot+claude (got '$review')" ;;
esac

if [ -n "$issue" ]; then
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || die "--issue must be a positive integer (got '$issue')"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"
command -v gh >/dev/null || die "gh CLI not found"

branch="$(git branch --show-current)"
[ -n "$branch" ] || die "not on a branch (detached HEAD)"
case "$branch" in
  main|master|development) die "refusing to open a PR from $branch" ;;
esac

# ---- provider ---------------------------------------------------------------
# Reviewer/bot wiring and this environment's PR title/body/branch conventions
# are per-repo-family, not per-script — a provider encapsulates them. `kardashev`
# is today's only provider (and the default); a work-environment provider lands
# later. Providers mirror start-ticket-providers/.
provider="${provider:-kardashev}"
pf="$PROVIDER_DIR/$provider.sh"
[ -f "$pf" ] || die "no provider script: $pf"
# shellcheck source=/dev/null
PROVIDER_TRIGGER_MODE=""   # providers may declare their own; default manual below
source "$pf"

provider::available || die "provider '$provider' unavailable (CLI missing or not authed)"
: "${PROVIDER_TRIGGER_MODE:=manual}"

# ---- PR: reuse if one already exists for this branch, else create ---------
# Decide (and validate inputs) before pushing, so a usage error can't leave a
# published branch behind as a side effect.
# gh pr list returns an empty result successfully when no PR exists for the
# branch, so auth/network/repository failures still abort here (pre-push
# validation) via set -e instead of being swallowed like a || true.
existing_pr="$(gh pr list --head "$branch" --json number --jq '.[0].number // empty')"
create_pr=""
if [ -n "$existing_pr" ]; then
  pr_number="$existing_pr"
  pr_action="reused"
else
  create_pr=1
  [ -n "$title" ] || die "no existing PR for '$branch' and no --title given"
  if [ -n "$body_file" ] && { [ ! -f "$body_file" ] || [ ! -r "$body_file" ]; }; then
    die "--body-file is not a readable file: $body_file"
  fi

  # Resolve the issue number (branch convention first, else --issue). The
  # title/body conventions hang off it, so it's resolved for both — not just
  # the default body, as the old inline version did.
  if [ -z "$issue" ]; then
    issue="$(provider::issue_from_branch "$branch")"
  fi
  if [ -n "$issue" ]; then
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || die "issue number '$issue' isn't a positive integer"
  fi

  title="$(provider::pr_title "$issue" "$title")"

  if [ -n "$body_file" ]; then
    body_args=(--body-file "$body_file")
  else
    [ -n "$issue" ] || die "can't infer issue number from branch '$branch' — pass --issue or --body-file"
    body_args=(--body "$(provider::pr_body "$issue")")
  fi
fi

# ---- push --------------------------------------------------------------------
# stdout (the ref-update summary) is suppressed to keep this script's stdout
# limited to the documented key=value fields; progress/errors go to stderr.
git push -u origin "$branch" >/dev/null

if [ -n "$create_pr" ]; then
  create_args=(--title "$title" --head "$branch")
  create_args+=("${body_args[@]}")
  # gh pr create prints the new PR URL to stdout; suppress it to keep this
  # script's stdout limited to the documented key=value fields (pr_url below).
  gh pr create "${create_args[@]}" >/dev/null
  pr_number="$(gh pr view --json number --jq '.number')"
  pr_action="created"
fi

pr_url="$(gh pr view "$pr_number" --json url --jq '.url')"

# ---- reviews ----------------------------------------------------------------
if [ "$review" != "none" ]; then
  # trigger_mode seam: "manual" providers dispatch their review triggers here
  # (Copilot requestReviews, claude.yml workflow run, …) after the user
  # approved. "auto" providers would trigger at push time and have nothing to
  # do here — that path is a later work-environment provider's concern and is
  # deliberately left unimplemented.
  case "${PROVIDER_TRIGGER_MODE:-manual}" in
    manual) provider::trigger_reviews "$pr_number" "$review" ;;
    auto)   : ;;
    *)      die "provider '$provider' declares unknown trigger_mode '$PROVIDER_TRIGGER_MODE'" ;;
  esac
fi

printf 'pr_number=%s\npr_url=%s\npr_action=%s\n' "$pr_number" "$pr_url" "$pr_action"
