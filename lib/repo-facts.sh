#!/usr/bin/env bash
# lib/repo-facts.sh — shared, read-only facts about a repo/branch.
#
# Sourced by open-pr.sh, sibling-worktrees.sh, and finalize-check.sh so the
# conventions below live in exactly one place. These were previously restated in
# prose inside .claude/commands/*.md, which meant the model re-derived them (and
# re-ran the probe commands) on every invocation.
#
# start-ticket.sh does NOT source this: it resolves a ticket id from its
# argument and a branch name from its provider, so it has no use for either
# helper. Don't wire it up just for symmetry.
#
# Everything here is pure inspection: no network beyond the host CLI fallback
# in gt::default_branch, no writes, no side effects.

# ---- default branch ---------------------------------------------------------
# Resolve origin's default branch name (NOT prefixed with "origin/"). Never
# assume main/master — `development` is common in these repos.
#
# Order: refs/remotes/origin/HEAD (local, instant) → `git remote show origin`
# (network, host-neutral) → the host CLI (GitHub only). Prints nothing and
# returns 1 if none of them answer, so callers can decide whether to ask.
gt::default_branch() {  # [<dir>] → <branch>, or nothing + rc 1
  local dir="${1:-.}" b

  b="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  b="${b#origin/}"
  if [ -n "$b" ]; then printf '%s' "$b"; return 0; fi

  b="$(git -C "$dir" remote show origin 2>/dev/null \
       | sed -n 's/.*HEAD branch: //p' | head -1)"
  if [ -n "$b" ] && [ "$b" != "(unknown)" ]; then printf '%s' "$b"; return 0; fi

  if command -v gh >/dev/null; then
    b="$(git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 \
         && cd "$dir" && gh repo view --json defaultBranchRef \
              -q .defaultBranchRef.name 2>/dev/null || true)"
    if [ -n "$b" ]; then printf '%s' "$b"; return 0; fi
  fi

  return 1
}

# Same, but as a verified remote ref (refs/remotes/origin/<base>), falling back
# to probing the usual names. Used where the caller needs a ref that definitely
# resolves rather than just a name.
#
# LOCAL-ONLY by design: reads refs/remotes/origin/HEAD and probes existing
# remote refs, never `git remote show origin` or a host CLI. sibling-worktrees.sh
# runs this speculatively on every ship and documents that it makes no network
# calls — keep it that way. Staleness here only ever over-reports work.
gt::default_branch_ref() {  # [<dir>] → origin/<branch>, or nothing + rc 1
  local dir="${1:-.}" b
  b="$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  b="${b#origin/}"
  if [ -n "$b" ] && git -C "$dir" rev-parse --verify --quiet "origin/$b" >/dev/null; then
    printf 'origin/%s' "$b"; return 0
  fi
  for b in development main master; do
    if git -C "$dir" rev-parse --verify --quiet "origin/$b" >/dev/null; then
      printf 'origin/%s' "$b"; return 0
    fi
  done
  return 1
}

# ---- ticket id from branch --------------------------------------------------
# The two branch conventions worktree-manager.sh creates:
#   <id>-<slug>                GitHub issues (default)
#   [<prefix>/]sc-<id>/<slug>  Shortcut      (--sc)
# Shortcut is matched first: an sc- id is unambiguous, while the GitHub form is
# just "leading digits" and would also match a branch like "2-sc-5/foo". The
# LAST sc-<id> wins — a follow-up branch can name several — matching
# open-pr-providers' provider::issue_from_branch.
gt::ticket_from_branch() {  # <branch> → id, or nothing
  local b="$1"
  if [[ "$b" =~ .*sc-([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "$b" =~ ^([1-9][0-9]*)- ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
  return 0
}

# Which dialect the branch uses, so callers can label a ticket ref correctly
# without re-parsing. Prints shortcut | github | unknown.
gt::ticket_scheme() {  # <branch> → shortcut | github | unknown
  local b="$1"
  if   [[ "$b" =~ .*sc-[0-9]+ ]];  then printf 'shortcut'
  elif [[ "$b" =~ ^[1-9][0-9]*- ]]; then printf 'github'
  else printf 'unknown'
  fi
}
