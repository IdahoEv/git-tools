#!/usr/bin/env bash
# sibling-worktrees.sh — find worktrees in OTHER repos that belong to the same ticket.
#
#   sibling-worktrees.sh [--ticket <id>] [--branch <name>] [--root <dir>]
#                        [--include-clean] [--repos <dir>[,<dir>...]]
#
# A ticket is often implemented across several repos at once (an API change in
# one, the shared schema package in another). Each repo gets its own worktree
# from `worktree-manager.sh`, on a branch carrying the same ticket id. This
# script locates those sibling worktrees so a caller — `/open-pr` — can fan a
# session out to each of them instead of shipping only the repo it happens to
# be standing in.
#
# It makes no changes and talks to no network: pure local inspection, safe to
# run speculatively on every ship.
#
# Ticket id is taken from --ticket, else parsed from --branch, else from the
# current branch, using the two conventions git-tools creates:
#   <id>-<slug>              GitHub issues  (worktree-manager default)
#   [<prefix>/]sc-<id>/<slug>  Shortcut     (worktree-manager --sc)
# The LAST sc-<id> in a branch wins (a follow-up branch can name several),
# matching open-pr-providers' issue_from_branch.
#
# Repos searched: every immediate subdirectory of <root> that is a git repo,
# excluding the one we're standing in. <root> defaults to the grandparent of
# the current worktree (…/Development/<repo>/<worktree> → …/Development), which
# is the layout `worktree-manager.sh --init` produces. --repos bypasses the
# scan entirely and inspects exactly the directories given.
#
# Output (stdout, one TAB-separated record per match, parseable):
#   <repo>\t<worktree-path>\t<branch>\t<state>
# where <state> is one of dirty, ahead, dirty+ahead, clean. `clean` worktrees
# (nothing uncommitted, nothing beyond the base branch) are omitted unless
# --include-clean: they have nothing to ship.
#
# Exit codes: 0 matches found (or none — an empty list is not an error);
#             1 usage/precondition error.

set -euo pipefail

die() { printf 'sibling-worktrees: %s\n' "$*" >&2; exit 1; }

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
ticket="" branch="" root="" include_clean="" repos_csv=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ticket)        ticket="${2:?--ticket needs a value}"; shift 2 ;;
    --branch)        branch="${2:?--branch needs a value}"; shift 2 ;;
    --root)          root="${2:?--root needs a value}"; shift 2 ;;
    --repos)         repos_csv="${2:?--repos needs a value}"; shift 2 ;;
    --include-clean) include_clean=1; shift ;;
    -h|--help)       sed -n '2,/^$/p' "$0"; exit 0 ;;
    *)               die "unknown arg: $1" ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"

# ---- ticket id --------------------------------------------------------------
# Convention lives in lib/repo-facts.sh (gt::ticket_from_branch) so finalize-check.sh
# and the open-pr providers parse branches identically.
if [ -z "$ticket" ]; then
  [ -n "$branch" ] || branch="$(git branch --show-current)"
  [ -n "$branch" ] || die "not on a branch (detached HEAD) — pass --ticket"
  ticket="$(gt::ticket_from_branch "$branch")"
fi
[ -n "$ticket" ] || die "can't parse a ticket id from branch '${branch:-?}' — pass --ticket"
[[ "$ticket" =~ ^[1-9][0-9]*$ ]] || die "ticket id must be a positive integer (got '$ticket')"

# ---- our own repo (to exclude) ----------------------------------------------
self_common="$(cd -P "$(git rev-parse --git-common-dir)" && pwd)"

# ---- candidate repos --------------------------------------------------------
candidates=()
if [ -n "$repos_csv" ]; then
  # Explicit list: entries may be a repo family dir OR a worktree inside one;
  # git resolves either to the same common dir, so both work.
  IFS=',' read -r -a _given <<< "$repos_csv"
  for d in "${_given[@]}"; do
    [ -n "$d" ] || continue
    [ -d "$d" ] || die "--repos entry is not a directory: $d"
    candidates+=("$d")
  done
else
  if [ -z "$root" ]; then
    # …/<dev-root>/<repo-family>/<worktree> → …/<dev-root>
    root="$(dirname "$(dirname "$(git rev-parse --show-toplevel)")")"
  fi
  [ -d "$root" ] || die "root is not a directory: $root"
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    candidates+=("${d%/}")
  done
fi

# ---- base branch ------------------------------------------------------------
# Used only to count commits beyond the base, i.e. "is there anything to ship".
# origin/<base> can be stale (notably when remote.origin.fetch is unset, which
# leaves refs/remotes/origin/* frozen), but staleness only ever OVER-reports
# work — a worktree wrongly shown as `ahead` costs a confirmation, never a
# silently skipped repo. Erring that direction is deliberate.
base_ref_for() {  # <worktree> → refs/remotes/origin/<base>, or nothing
  gt::default_branch_ref "$1" || true
}

worktree_state() {  # <worktree> → dirty | ahead | dirty+ahead | clean
  local wt="$1" base dirty="" ahead="" n
  [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && dirty=1
  base="$(base_ref_for "$wt")"
  if [ -n "$base" ]; then
    n="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] && ahead=1
  else
    # No base to compare against: treat as having work rather than hiding it.
    ahead=1
  fi
  if [ -n "$dirty" ] && [ -n "$ahead" ]; then printf 'dirty+ahead'
  elif [ -n "$dirty" ]; then printf 'dirty'
  elif [ -n "$ahead" ]; then printf 'ahead'
  else printf 'clean'
  fi
}

# ---- scan -------------------------------------------------------------------
for repo in "${candidates[@]}"; do
  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || continue
  common="$(cd -P "$repo" && cd -P "$common" 2>/dev/null && pwd)" || continue
  [ "$common" = "$self_common" ] && continue   # same repo we're shipping from

  repo_name="$(basename "$repo")"

  # --porcelain emits stanzas of "worktree <path>" / "HEAD <oid>" /
  # "branch refs/heads/<name>" (or "detached"), blank-line separated.
  wt="" br=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }"; br="" ;;
      "branch "*)   br="${line#branch }"; br="${br#refs/heads/}" ;;
      "")
        if [ -n "$wt" ] && [ -n "$br" ] && [ "$(ticket_from_branch "$br")" = "$ticket" ]; then
          state="$(worktree_state "$wt")"
          if [ -n "$include_clean" ] || [ "$state" != "clean" ]; then
            printf '%s\t%s\t%s\t%s\n' "$repo_name" "$wt" "$br" "$state"
          fi
        fi
        wt="" br=""
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null; printf '\n')
done
