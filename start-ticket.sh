#!/usr/bin/env bash
# start-ticket.sh — spin up a worktree + Claude session for a tracker ticket.
#
#   start-ticket.sh <id> [--provider github|shortcut] [--no-tab] [--launcher iterm|bg|none]
#   start-ticket.sh --tab-only <worktree> <kickoff> [--launcher iterm|bg|none]
#
# Resolves a ticket (GitHub issue or Shortcut story) to a branch, creates a
# worktree via worktree-manager.sh, marks the ticket in progress, writes a
# kickoff prompt, and starts a Claude session for it with a "launcher":
#   iterm (default)  a 2-pane iTerm tab: claude on top with the prompt typed in
#                    but unsubmitted; a shell on the bottom.
#   bg               a background session for Claude Code's agent view
#                    (`claude agents`): claude --bg --name "<label>" "<kickoff>".
#                    The kickoff is SUBMITTED immediately, so it starts in plan
#                    mode by default to keep a review gate (see bg_permission_mode).
#   none             worktree + kickoff only (same as --no-tab).
#
# Launcher is chosen by, in order: --launcher flag → $START_TICKET_LAUNCHER →
# `launcher=` in .start-ticket.conf / ~/.config/start-ticket/config → iterm.
# Put `launcher=bg` in the per-machine ~/.config/start-ticket/config to opt in.
#
# Run from anywhere inside the target repo. Provider is chosen by, in order:
#   --provider flag → .start-ticket.conf (provider=…) → autodetect (gh vs short).
#
# Env knobs: START_TICKET_CLAUDE_DELAY (secs before typing the prompt, default 3),
#   START_TICKET_TAB_MAXLEN (default 30), START_TICKET_PROVIDER_DIR,
#   START_TICKET_BG_MAXLEN (agent-view row name length, default 70),
#   START_TICKET_BG_PERMISSION_MODE or `bg_permission_mode=` in the conf files
#   (bg launcher only; default "plan"; "default" passes no --permission-mode).
#
# Providers: <script-dir>/start-ticket-providers/<name>.sh (override with
# $START_TICKET_PROVIDER_DIR), each defining:
#   provider::available
#   provider::fetch <id>              → sets ST_TITLE ST_BODY ST_URL ST_PARENT ST_BRANCH
#   provider::create_worktree <id>    → echoes worktree path (last line)
#   provider::post_worktree <id> <wt> → optional; re-populate ST_* from files in <wt>
#   provider::mark_in_progress <id>

set -euo pipefail

die() { printf 'start-ticket: %s\n' "$*" >&2; exit 1; }

# Literal (non-regex) replace of every <from> with <to> in <string>. Pure bash
# so values containing '/', '&', '\' etc. can't corrupt or abort the result the
# way `sed`/`awk` substitution would.
subst() {  # <string> <from> <to>
  local s="$1" from="$2" to="$3" out=""
  while [ "$s" != "${s#*"$from"}" ]; do
    out+="${s%%"$from"*}$to"
    s="${s#*"$from"}"
  done
  printf '%s%s' "$out" "$s"
}

# ---- resolve our own dir (following symlinks) -----------------------------
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [ "${_src#/}" = "$_src" ] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# Provider lookup (first dir containing <name>.sh wins):
#   1. $START_TICKET_PROVIDER_DIR (explicit override)
#   2. <main-repo-root>/.git-tools/start-ticket-providers  (per-repo)
#   3. ~/.config/git-tools/start-ticket-providers          (per-machine)
#   4. this repo's start-ticket-providers/                 (shipped defaults)
# Same layering as open-pr.sh's find_provider_file.
find_provider_file() {  # <name> → path, or empty
  local name="$1" main_root common pd f
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    common="$(cd -P "$common" 2>/dev/null && pwd)" && main_root="$(dirname "$common")" || main_root=""
  fi
  for pd in "${START_TICKET_PROVIDER_DIR:-}" \
            "${main_root:-}/.git-tools/start-ticket-providers" \
            "$HOME/.config/git-tools/start-ticket-providers" \
            "$SCRIPT_DIR/start-ticket-providers"; do
    [ -n "$pd" ] || continue
    f="$pd/$name.sh"
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

conf_get() {  # <key> → value from repo .start-ticket.conf, then ~/.config
  # In a worktree the .start-ticket.conf lives in the MAIN repo root
  # (--git-common-dir's parent), so check the cwd's toplevel and that.
  local key="$1" f v main_root="" common top
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    common="$(cd -P "$common" 2>/dev/null && pwd)" && main_root="$(dirname "$common")" || main_root=""
  fi
  for f in "${top:-/nonexistent}/.start-ticket.conf" "${main_root:-/nonexistent}/.start-ticket.conf" "$HOME/.config/start-ticket/config"; do
    [ -f "$f" ] || continue
    v="$(sed -n "s/^${key}=//p" "$f" | head -1)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

# setting <conf-key> <ENV_VAR> <default>: env var → conf file → default.
setting() {
  local v="${!2:-}"
  [ -n "$v" ] || v="$(conf_get "$1" || true)"
  printf '%s' "${v:-$3}"
}

# make_label <branch> <maxlen> [pretty] → short tab / agent-view row label.
# Branch "<n>-<slug>" -> "Is<n> <slug>"; Shortcut "<user>/sc-<id>/<slug>" ->
# "Sc<id> <slug>". The ticket number is ALWAYS kept; the slug is truncated.
# "Is" (not "#") disambiguates issue numbers from PR numbers at a glance,
# since GitHub shares one number sequence between the two. With "pretty",
# hyphens in the slug become spaces (more readable in agent-view rows).
make_label() {
  local branch="$1" maxlen="$2" pretty="${3:-}" num="" slug="$1"
  if [[ "$branch" =~ ^([0-9]+)-(.+)$ ]]; then
    num="Is${BASH_REMATCH[1]}"
    slug="${BASH_REMATCH[2]}"
  elif [[ "$branch" =~ (^|/)sc-([0-9]+)/(.+)$ ]]; then
    num="Sc${BASH_REMATCH[2]}"
    slug="${BASH_REMATCH[3]}"
  fi
  [ -n "$pretty" ] && slug="${slug//-/ }"
  if [ -n "$num" ]; then
    # Reserve room for "IsN " and the ellipsis when truncating the slug.
    local budget=$((maxlen - ${#num} - 2))
    [ "${#slug}" -gt "$budget" ] && slug="${slug:0:$((budget-1))}…"
    printf '%s %s' "$num" "$slug"
  else
    [ "${#slug}" -gt "$maxlen" ] && slug="${slug:0:$((maxlen-1))}…"
    printf '%s' "$slug"
  fi
}

# ---- iTerm tab ---------------------------------------------------------------
# Opens a new iTerm tab, split into two horizontal panes:
#   top    — `claude` (bare); the kickoff prompt is typed into its input via a
#            bracketed paste after START_TICKET_CLAUDE_DELAY seconds, left
#            UNSUBMITTED for review.
#   bottom — a plain shell in the worktree.
# The kickoff is also put on the clipboard as a fallback (paste with ⌘V).
# Tab name = "Is<n> <slug>" where the ticket number is ALWAYS kept and the slug is
# truncated instead (to START_TICKET_TAB_MAXLEN). The name is re-asserted after
# commands are written so iTerm's automatic title updates don't clobber it.
open_tab() {  # <worktree> <kickoff>
  local wt="$1" kf="$2"
  local branch; branch="$(git -C "$wt" branch --show-current 2>/dev/null || basename "$wt")"

  local label; label="$(make_label "$branch" "${START_TICKET_TAB_MAXLEN:-30}")"

  local delay="${START_TICKET_CLAUDE_DELAY:-3}"

  command -v pbcopy >/dev/null && pbcopy < "$kf" 2>/dev/null || true

  if [ "${TERM_PROGRAM:-}" != "iTerm.app" ] && [ "${LC_TERMINAL:-}" != "iTerm2" ]; then
    printf '\nNot in iTerm. Kickoff is on the clipboard and at %s\n  cd %q && claude   # then paste the kickoff\n' "$kf" "$wt"
    return
  fi

  osascript - "$wt" "$kf" "$label" "$delay" "$(cat "$kf")" <<'OSA'
on run argv
  set wt to item 1 of argv
  set kf to item 2 of argv
  set tabName to item 3 of argv
  set startDelay to (item 4 of argv) as integer
  set promptText to item 5 of argv
  set ESC to (ASCII character 27)
  tell application "iTerm2"
    tell current window
      try
        set newTab to (create tab with profile "Ticket")
      on error
        -- "Ticket" dynamic profile not loaded yet. Install it via
        -- setup-ticket-profile.sh (writes the DynamicProfiles JSON; iTerm
        -- picks it up live), but fall back rather than fail outright.
        set newTab to (create tab with default profile)
      end try
      tell newTab
        set topPane to current session
        tell topPane
          set name to tabName
          write text "cd " & quoted form of wt & " && claude"
          -- Re-assert the name after launching: shells/Claude may set their own
          -- title, which would bury the ticket number.
          set name to tabName
          try
            set botPane to (split horizontally with profile "Ticket")
          on error
            set botPane to (split horizontally with default profile)
          end try
        end tell
        tell botPane
          set name to tabName
          write text "cd " & quoted form of wt & " && clear"
          write text "printf '%s\\n' '──── kickoff (typed into Claude above, unsubmitted; also on clipboard) ────'"
          write text "(command -v bat >/dev/null && bat --style=plain --paging=never " & quoted form of kf & " || cat " & quoted form of kf & ")"
          write text "printf '\\n%s\\n' '────' 'Looks good: click Claude above, press Enter.' 'Edit first: $EDITOR " & kf & " ; pbcopy < " & kf & " ; clear Claude input; paste; Enter.'"
        end tell
        delay startDelay
        tell topPane
          write text (ESC & "[200~" & promptText & ESC & "[201~") newline false
          select
          -- Final re-assert after the kickoff is typed: Claude's session-start
          -- title update lands around here.
          set name to tabName
        end tell
      end tell
    end tell
  end tell
end run
OSA
}

# ---- background session (Claude Code agent view) -----------------------------
# Starts `claude --bg` in the worktree so the session shows up as a row in
# `claude agents`, named "Is<n> <slug>" (hyphens → spaces, START_TICKET_BG_MAXLEN
# long). Because the worktree already exists (worktree-manager.sh made it),
# Claude Code uses it as-is rather than creating its own under .claude/worktrees/,
# so .worktree-sync seeding is preserved and /finalize's cleanup still applies.
# Unlike the iTerm launcher, the kickoff is submitted immediately; the default
# permission mode is therefore "plan" (Claude proposes before editing).
# claude's own output goes to stderr to keep this script's stdout parseable.
open_bg() {  # <worktree> <kickoff>
  local wt="$1" kf="$2"
  command -v claude >/dev/null || die "claude CLI not found (needed by the bg launcher)"
  local branch; branch="$(git -C "$wt" branch --show-current 2>/dev/null || basename "$wt")"
  local label; label="$(make_label "$branch" "${START_TICKET_BG_MAXLEN:-70}" pretty)"
  local perm; perm="$(setting bg_permission_mode START_TICKET_BG_PERMISSION_MODE plan)"
  local args=(--bg --name "$label")
  [ "$perm" = "default" ] || args+=(--permission-mode "$perm")

  printf 'start-ticket: dispatching background session "%s" (permission mode: %s)\n' "$label" "$perm" >&2
  if ! ( cd "$wt" && claude "${args[@]}" "$(cat "$kf")" ) >&2; then
    printf 'start-ticket: `claude --bg` failed. If it mentioned workspace trust, run `cd %q && claude` once to accept the trust dialog, then retry:\n  cd %q && claude --bg --name %q "$(cat %q)"\n' \
      "$wt" "$wt" "$label" "$kf" >&2
    return 1
  fi
}

launch_session() {  # <worktree> <kickoff> — uses the resolved $launcher
  case "$launcher" in
    iterm) open_tab "$1" "$2" ;;
    bg)    open_bg  "$1" "$2" ;;
    none)  : ;;
  esac
}

# ---- args ------------------------------------------------------------------
id="" provider="" mode="full" launcher_flag="" tab_wt="" tab_kf=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider="${2:?--provider needs a value}"; shift 2 ;;
    --no-tab)   mode="no-tab"; shift ;;
    --tab-only) mode="tab-only"
                tab_wt="${2:?--tab-only needs <worktree> <kickoff>}"
                tab_kf="${3:?--tab-only needs <worktree> <kickoff>}"
                shift 3 ;;
    --launcher) launcher_flag="${2:?--launcher needs a value}"; shift 2 ;;
    -h|--help)  sed -n '2,/^$/p' "$0"; exit 0 ;;
    -*)         die "unknown flag: $1" ;;
    *)          id="$1"; shift ;;
  esac
done

# --tab-only runs from wherever the caller is: move into the worktree so the
# per-repo .start-ticket.conf resolves, after making the kickoff path absolute.
if [ "$mode" = "tab-only" ]; then
  tab_kf="$(cd "$(dirname "$tab_kf")" && pwd)/$(basename "$tab_kf")"
  cd "$tab_wt" || die "worktree not found: $tab_wt"
fi

launcher="$launcher_flag"
[ -n "$launcher" ] || launcher="$(setting launcher START_TICKET_LAUNCHER iterm)"
case "$launcher" in
  iterm|bg|none) ;;
  *) die "unknown launcher '$launcher' (expected iterm, bg, or none)" ;;
esac

if [ "$mode" = "tab-only" ]; then
  launch_session "$tab_wt" "$tab_kf"
  exit 0
fi

[ -n "$id" ] || die "usage: start-ticket.sh <id> [--provider github|shortcut] [--no-tab] [--launcher iterm|bg|none]"

# ---- repo + provider -----------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"
repo_root="$(git rev-parse --show-toplevel)"
_url="$(git remote get-url origin 2>/dev/null || true)"
if [ -n "$_url" ]; then repo_name="$(basename "${_url%.git}")"; else repo_name="$(basename "$repo_root")"; fi

[ -n "$provider" ] || provider="$(conf_get provider || true)"
if [ -z "$provider" ]; then
  if command -v gh >/dev/null && gh repo view >/dev/null 2>&1; then provider=github
  elif command -v short >/dev/null; then provider=shortcut
  else die "no ticket provider detected — set 'provider=' in .start-ticket.conf or pass --provider"
  fi
fi

pf="$(find_provider_file "$provider")"
[ -n "$pf" ] || die "no provider script for '$provider' (searched: START_TICKET_PROVIDER_DIR, <repo>/.git-tools/start-ticket-providers, ~/.config/git-tools/start-ticket-providers, git-tools/start-ticket-providers)"
# shellcheck source=/dev/null
source "$pf"

WORKTREE_MANAGER="$(command -v worktree-manager.sh || echo "$SCRIPT_DIR/worktree-manager.sh")"
[ -x "$WORKTREE_MANAGER" ] || die "worktree-manager.sh not found / not executable"
export WORKTREE_MANAGER

provider::available || die "provider '$provider' unavailable (CLI missing or not authed)"

# ---- run ---------------------------------------------------------------
ST_TITLE="" ST_BODY="" ST_URL="" ST_PARENT="" ST_BRANCH="" ST_REF=""
provider::fetch "$id"
: "${ST_REF:=${provider} ticket ${id}}"
printf 'start-ticket: %s #%s — %s\n' "$provider" "$id" "${ST_TITLE:-?}" >&2

wt="$(provider::create_worktree "$id" | tail -1)"
[ -d "$wt" ] || die "worktree not created (got '$wt')"
branch="$(git -C "$wt" branch --show-current)"

declare -f provider::post_worktree >/dev/null && provider::post_worktree "$id" "$wt"
provider::mark_in_progress "$id" || echo "start-ticket: WARN mark_in_progress failed" >&2

# ---- kickoff ---------------------------------------------------------
_tmp="${TMPDIR:-/tmp}"; kickoff="${_tmp%/}/${repo_name}-kickoff-${id}.md"
{
  printf 'Working on %s in this worktree. Branch `%s` is checked out.\n\n' \
    "$ST_REF" "$branch"
  printf '## %s — %s\n\n%s\n' "$id" "${ST_TITLE:-untitled}" "${ST_BODY:-(no description)}"
  [ -n "$ST_URL" ] && printf '\n<%s>\n' "$ST_URL"
  pre="$repo_root/.claude/kickoff-preamble.md"
  if [ -f "$pre" ]; then
    printf '\n'
    _pre="$(cat "$pre")"
    _pre="$(subst "$_pre" '{{ID}}' "$id")"
    _pre="$(subst "$_pre" '{{BRANCH}}' "$branch")"
    _pre="$(subst "$_pre" '{{PARENT}}' "$ST_PARENT")"
    printf '%s\n' "$_pre"
  fi
} > "$kickoff"

printf 'worktree=%s\nkickoff=%s\n' "$wt" "$kickoff"   # stdout: parseable by callers
[ "$mode" = "no-tab" ] && exit 0
launch_session "$wt" "$kickoff"
