#!/usr/bin/env bash
# agent-phase.sh — stamp a ticket's workflow phase onto its agent-view row.
#
#   agent-phase.sh <PLAN|WIP|REVIEW|MERGED|DONE>
#   agent-phase.sh --show
#   agent-phase.sh --clear
#
# Claude Code's agent view (`claude agents`) shows two state axes already:
# `status` (idle/busy — process level, set by the daemon) and `state`
# (working/blocked/done — turn level, set by the model). Neither says where a
# ticket is in ITS lifecycle: planning, implementing, in review, merged,
# finalized. This script encodes that third axis as a prefix on the session's
# display name, which is the only field that is model-writable, unbounded, and
# visible in both the TUI and `claude agents --json`:
#
#   [PLAN]   Sc74618 personalization api
#   [WIP]    Sc74618 personalization api
#   [REVIEW] Sc74618 personalization api
#
# Why the name and not the color: `/color` is declared `terminalOriented` with
# `requires:{ink:true}` and, unlike `/rename`, carries no `supportsNonInteractive`
# flag — a `--bg` session has no ink renderer, so a ticket agent cannot color
# itself when it changes phase. The palette is also only 8 colors and is already
# used per-agent-type in `.claude/agents/*.md` frontmatter, so overloading it
# would make a purple row ambiguous. Color stays free for a repo/project axis.
#
# Writes `~/.claude/jobs/<id>/state.json` directly. That file is Claude Code
# internals rather than documented API, so this is deliberately defensive: it
# no-ops (exit 0, silent) whenever it isn't looking at a background session it
# understands. The alternative — the supported `/rename` command — can only be
# driven by the model mid-conversation, not by a shell step in a hook or
# script, which is exactly where the phase transitions happen.
#
# Nothing here is authoritative. The phase is self-reported, so a session that
# dies mid-ticket keeps a stale prefix; `/board` recomputes true state from git
# + the tracker and is the thing to trust when they disagree.
#
# Exit codes: 0 always on the happy path AND on every "not applicable" case
#             (not a bg session, no job dir, unreadable state) — callers embed
#             this in larger workflows and must not abort over a cosmetic label.
#             1 usage error only (bad phase name).

set -euo pipefail

die() { printf 'agent-phase: %s\n' "$*" >&2; exit 1; }

PHASES="PLAN WIP REVIEW MERGED DONE"

usage() {
  printf 'usage: agent-phase.sh <%s>\n       agent-phase.sh --show | --clear\n' \
    "$(echo "$PHASES" | tr ' ' '|')" >&2
}

# ---- args -------------------------------------------------------------------
phase="" action="set"
case "${1:-}" in
  --show)    action="show" ;;
  --clear)   action="clear" ;;
  -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
  "")        usage; exit 1 ;;
  -*)        usage; die "unknown option: $1" ;;
  *)
    phase="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    case " $PHASES " in
      *" $phase "*) ;;
      *) usage; die "unknown phase '$1' (expected one of: $PHASES)" ;;
    esac
    ;;
esac

# ---- locate the session's state file ----------------------------------------
# CLAUDE_JOB_DIR is exported into every tool call of a background session and
# names that session's own job dir. Its absence means we're in an interactive
# session (iTerm launcher, plain `claude`), where there is no agent-view row to
# label — not an error, just nothing to do.
job_dir="${CLAUDE_JOB_DIR:-}"
[ -n "$job_dir" ] || exit 0

state_file="$job_dir/state.json"
[ -f "$state_file" ] && [ -r "$state_file" ] && [ -w "$state_file" ] || exit 0

command -v python3 >/dev/null || exit 0

# ---- rewrite the name's phase prefix ----------------------------------------
# Python rather than sed/jq: the write must be atomic (os.replace) because the
# daemon rewrites this same file on every status change, and a partial write
# would corrupt a session's state, not just its label. jq isn't guaranteed
# present; python3 ships with macOS.
PHASE="$phase" ACTION="$action" PHASES="$PHASES" python3 - "$state_file" <<'PY'
import json, os, re, sys, tempfile

path    = sys.argv[1]
phase   = os.environ["PHASE"]
action  = os.environ["ACTION"]
phases  = os.environ["PHASES"].split()

try:
    with open(path) as fh:
        state = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)          # unreadable or mid-write by the daemon; cosmetic, skip

name = state.get("name")
if not isinstance(name, str):
    sys.exit(0)

# Strip any prefix we previously applied. Anchored to the known phase set so a
# ticket whose real title happens to start with bracketed text (e.g.
# "[spike] try X") keeps it.
bare = re.sub(r"^\[(?:%s)\]\s*" % "|".join(phases), "", name)

if action == "show":
    m = re.match(r"^\[(%s)\]" % "|".join(phases), name)
    print(m.group(1) if m else "")
    sys.exit(0)

new = bare if action == "clear" else "[%s] %s" % (phase, bare)
if new == name:
    sys.exit(0)

state["name"] = new
# nameSource=user stops Claude Code's auto-naming from overwriting the phase
# prefix with a summary of the conversation partway through the ticket.
state["nameSource"] = "user"

# Atomic replace: write a sibling temp file, fsync, then rename over the
# original. Rename is atomic within a filesystem, so a concurrent daemon read
# sees either the old file or the new one, never a truncated one.
dirname = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=dirname, prefix=".state.json.")
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(state, fh, indent=2)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(0)          # never fail a ticket workflow over a display label

print(new)
PY
