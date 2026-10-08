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
# shellcheck source=lib/repo-facts.sh
. "$SCRIPT_DIR/lib/repo-facts.sh"
# Provider lookup (first dir containing <name>.sh wins):
#   1. $OPEN_PR_PROVIDER_DIR (explicit override)
#   2. <main-repo-root>/.git-tools/open-pr-providers  (per-repo)
#   3. ~/.config/git-tools/open-pr-providers          (per-machine, environment-wide)
#   4. this repo's open-pr-providers/                 (shipped defaults)
# This keeps environment-specific providers (e.g. a work environment) out of
# the personal git-tools repo while letting any layer ship one.
find_provider_file() {  # <name> → path, or empty
  local name="$1" main_root common pd f
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    common="$(cd -P "$common" 2>/dev/null && pwd)" && main_root="$(dirname "$common")" || main_root=""
  fi
  for pd in "${OPEN_PR_PROVIDER_DIR:-}" \
            "${main_root:-}/.git-tools/open-pr-providers" \
            "$HOME/.config/git-tools/open-pr-providers" \
            "$SCRIPT_DIR/open-pr-providers"; do
    [ -n "$pd" ] || continue
    f="$pd/$name.sh"
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

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
# Refuse to ship from the repo's actual default branch, whatever it's called —
# the hardcoded main|master|development triple missed any other name. Keep
# those as a fallback for when the default can't be resolved.
_default="$(gt::default_branch || true)"
if [ -n "$_default" ]; then
  [ "$branch" = "$_default" ] && die "refusing to open a PR from $branch (the default branch)"
else
  case "$branch" in
    main|master|development) die "refusing to open a PR from $branch" ;;
  esac
fi

# ---- provider ---------------------------------------------------------------
# Reviewer/bot wiring and this environment's PR title/body/branch conventions
# are per-repo-family, not per-script — a provider encapsulates them. Providers
# mirror start-ticket-providers/. Resolution mirrors start-ticket.sh: --provider
# flag → openpr_provider= in the repo's .start-ticket.conf → kardashev default.
if [ -z "$provider" ]; then
  # In a worktree, --show-toplevel is the worktree path, but .start-ticket.conf
  # lives in the main repo root — resolve both (--git-common-dir's parent is
  # the main worktree even from a linked worktree).
  _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  _main_root=""
  _common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$_common" ]; then
    _common="$(cd -P "$_common" && pwd)"
    _main_root="$(dirname "$_common")"
  fi
  for _f in "${_repo_root:-/nonexistent}/.start-ticket.conf" "${_main_root:-/nonexistent}/.start-ticket.conf" "$HOME/.config/start-ticket/config"; do
    [ -f "$_f" ] || continue
    _v="$(sed -n 's/^openpr_provider=//p' "$_f" | head -1)"
    [ -n "$_v" ] && { provider="$_v"; break; }
  done
fi
provider="${provider:-kardashev}"
pf="$(find_provider_file "$provider")"
[ -n "$pf" ] || die "no provider script for '$provider' (searched: OPEN_PR_PROVIDER_DIR, <repo>/.git-tools/open-pr-providers, ~/.config/git-tools/open-pr-providers, git-tools/open-pr-providers)"
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
    # The caller drafted a real summary. Any tracker-linking convention
    # ("Closes #N" on providers whose PRs live in the same issue namespace) is
    # the provider's business, not the caller's — appending it here keeps
    # /open-pr's drafting step provider-agnostic and stops a hand-written
    # footer from duplicating or contradicting the provider's.
    # Providers that need no footer leave pr_body_footer undefined / empty.
    footer=""
    if [ -n "$issue" ] && declare -f provider::pr_body_footer >/dev/null; then
      footer="$(provider::pr_body_footer "$issue")"
    fi
    if [ -n "$footer" ] && ! grep -qixF -- "$footer" "$body_file"; then
      # Don't mutate the caller's file; gh reads the body from a copy.
      body_tmp="$(mktemp "${TMPDIR:-/tmp}/open-pr-body.XXXXXX")"
      trap 'rm -f "$body_tmp"' EXIT
      { cat -- "$body_file"; printf '\n%s\n' "$footer"; } > "$body_tmp"
      body_args=(--body-file "$body_tmp")
    else
      body_args=(--body-file "$body_file")
    fi
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

# ---- title self-check -------------------------------------------------------
# This script applied the prefix (provider::pr_title), so it is also the thing
# that can tell whether the result is right — /open-pr used to read the title
# back and reason about it by hand, one round-trip per ship. A doubled prefix
# means the caller's draft already carried one; provider::pr_title is
# idempotent for its OWN dialect but can't catch a foreign one (the
# `sc-73237: Is73237: …` case). Repair it here and say so.
pr_title_now="$(gh pr view "$pr_number" --json title --jq '.title')"
pr_title_fixed=""
if [ -n "$create_pr" ] && [ -n "${issue:-}" ]; then
  expected="$(provider::pr_title "$issue" "")"
  expected="${expected% }"                     # bare prefix, e.g. "Is42:" / "sc-42:"
  if [ -n "$expected" ]; then
    # Strip every leading ticket prefix — this provider's own (repeated) AND a
    # foreign dialect's. Both dialects git-tools creates are matched, because
    # the failure mode that reached production was a cross-dialect double
    # (`sc-73237: Is73237: …`), which an idempotency check on one dialect alone
    # cannot see. Then re-apply exactly one.
    rest="$pr_title_now" n=0
    while :; do
      if [ "${rest#"$expected"}" != "$rest" ]; then
        rest="${rest#"$expected"}"
      elif [[ "$rest" =~ ^(Is[0-9]+|sc-[0-9]+):[[:space:]] ]]; then
        rest="${rest#"${BASH_REMATCH[1]}":}"
      else
        break
      fi
      rest="${rest# }"; n=$((n + 1))
    done
    if [ "$n" -gt 1 ] || { [ "$n" -eq 1 ] && [ "${pr_title_now#"$expected"}" = "$pr_title_now" ]; }; then
      gh pr edit "$pr_number" --title "$expected $rest" >/dev/null
      pr_title_fixed="$pr_title_now"
      pr_title_now="$expected $rest"
    fi
  fi
fi

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

# ---- agent-view phase --------------------------------------------------------
# The PR exists and reviews are dispatched, so this ticket is now in review.
# Stamped here rather than left to /open-pr's prose because it's deterministic
# and should hold even when the command is run by hand. No-ops outside a
# background session, and never fails the ship — the PR is already open by now,
# so aborting over a display label would be strictly worse than a stale one.
"$SCRIPT_DIR/agent-phase.sh" REVIEW >/dev/null 2>&1 || true

printf 'pr_number=%s\npr_url=%s\npr_action=%s\n' "$pr_number" "$pr_url" "$pr_action"
# Reported so /open-pr can describe reviews accurately without re-reading the
# conf: under "auto" the bots fire on PR open and nothing was dispatched here.
printf 'provider=%s\ntrigger_mode=%s\npr_title=%s\n' \
  "$provider" "${PROVIDER_TRIGGER_MODE:-manual}" "$pr_title_now"
[ -n "$pr_title_fixed" ] && printf 'pr_title_repaired_from=%s\n' "$pr_title_fixed"
exit 0
