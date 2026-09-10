# shortcut provider for start-ticket.sh   — requires: short CLI
#
# `short` has no JSON export; we parse `short story <id>` text output and let
# `worktree-manager.sh --sc` resolve the branch + write .ticket.local.md.
#
# VERIFY against your `short` version — the field labels parsed below and the
# `story update --state` syntax are best-guess. Set the in-progress state name
# via `shortcut_in_progress_state=` in .start-ticket.conf or
# $SHORTCUT_IN_PROGRESS_STATE (default: "In Development").

provider::available() { command -v short >/dev/null; }

provider::fetch() {
  local id="$1" out
  out="$(short story "$id" --quiet 2>/dev/null)" || { echo "short story $id failed" >&2; return 1; }
  # awk (not `sed ... | head -1`): a pipe that closes early can hand `sed` a
  # SIGPIPE, which `set -o pipefail` in start-ticket.sh turns into an abort of
  # this unguarded fetch. `match`+`substr`+`exit` stops at the first hit with
  # no pipe, and is portable across BSD/GNU awk.
  ST_TITLE="$(awk  'match($0,/^[Nn]ame:[[:space:]]*/){print substr($0,RLENGTH+1);exit}'      <<<"$out")"
  ST_URL="$(awk    'match($0,/^[Uu][Rr][Ll]:[[:space:]]*/){print substr($0,RLENGTH+1);exit}' <<<"$out")"
  ST_PARENT="$(awk 'match($0,/^[Ee]pic:[[:space:]]*/){print substr($0,RLENGTH+1);exit}'      <<<"$out")"
  ST_BODY="$out"
  ST_REF="Shortcut story ${id}"
  ST_BRANCH=""                       # let `worktree-manager --sc` decide
}

provider::create_worktree() { "$WORKTREE_MANAGER" --sc "$1"; }

# after the worktree exists, prefer the richer detail file worktree-manager wrote
provider::post_worktree() {
  local tf="$2/.ticket.local.md"
  [ -f "$tf" ] && ST_BODY="$(cat "$tf")"
  return 0
}

provider::mark_in_progress() {
  local state
  state="$(conf_get shortcut_in_progress_state || true)"
  state="${state:-${SHORTCUT_IN_PROGRESS_STATE:-In Development}}"
  short story update "$1" --state "$state" >/dev/null 2>&1 \
    || echo "shortcut: couldn't set state '$state' on $1 (check 'short story update' syntax / state name)" >&2
}
