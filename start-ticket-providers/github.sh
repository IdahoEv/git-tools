# github provider for start-ticket.sh   — requires: gh (authed), jq
#
# `gh` infers the repo from the cwd's origin remote, so start-ticket.sh must be
# run from inside the target repo (any worktree). No --repo needed.
#
# Parent/epic detection uses `gh issue view --json parent` (sub-issues), which
# needs a recent gh; on older versions it's skipped and ST_PARENT stays empty.

provider::available() {
  command -v gh >/dev/null && command -v jq >/dev/null && gh auth status >/dev/null 2>&1
}

provider::fetch() {
  local id="$1" json state
  json="$(gh issue view "$id" --json number,title,body,state,url)" \
    || { echo "gh issue view #$id failed" >&2; return 1; }
  state="$(jq -r .state <<<"$json")"
  [ "$state" = OPEN ] || { echo "issue #$id is $state, not OPEN" >&2; return 1; }
  ST_TITLE="$(jq -r .title <<<"$json")"
  ST_BODY="$(jq -r .body   <<<"$json")"
  ST_URL="$(jq -r .url     <<<"$json")"
  # Separate, non-fatal call: `--json parent` errors on a gh too old for
  # sub-issues, and parent is optional metadata - don't abort fetch over it.
  ST_PARENT="$(gh issue view "$id" --json parent --jq '.parent.number // empty' 2>/dev/null || true)"
  ST_REF="GitHub issue #${id}"
  local slug
  slug="$(printf '%s' "$ST_TITLE" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -d- -f1-6)"
  [ -n "$slug" ] || slug="ticket"
  ST_BRANCH="${id}-${slug}"
}

provider::create_worktree() { "$WORKTREE_MANAGER" "$ST_BRANCH"; }

provider::mark_in_progress() {
  local me; me="$(gh api user --jq .login 2>/dev/null || true)"
  if [ -n "$me" ] && gh issue view "$1" --json assignees --jq '.assignees[].login' | grep -qx "$me"; then
    return 0   # already assigned to us — treat as already in progress, stay quiet
  fi
  gh issue edit    "$1" --add-assignee @me >/dev/null
  gh issue comment "$1" --body "🚧 In progress — branch \`${ST_BRANCH}\`." >/dev/null
}
