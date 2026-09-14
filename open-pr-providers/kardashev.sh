# kardashev provider for open-pr.sh   — requires: gh (authed)
#
# Encapsulates Kardashev's PR conventions and review wiring so open-pr.sh stays
# per-repo-family agnostic (mirrors start-ticket-providers/):
#   - branch convention `<NNN>-slug`  → issue number NNN
#   - PR title convention `Is<NNN>: <short title>`
#   - PR body  convention `Closes #NNN`
#   - review triggers: Copilot (manual GraphQL `requestReviews`) + Claude
#     (manual `claude.yml` workflow_dispatch, smoke test only)
#
# Trigger mode is "manual": `/open-pr` dispatches these explicitly, after the
# user approves. "auto" (review triggers firing on push, no explicit dispatch)
# is a future work-environment provider's concern — keep this seam in place,
# don't fold it in here.
#
# See docs/plans/ship-command.md (in the Kardashev repo) for the full reasoning
# behind the Copilot bot-id resolution and the inlined-array GraphQL mutation.

PROVIDER_TRIGGER_MODE="manual"

provider::available() {
  command -v gh >/dev/null && gh auth status >/dev/null 2>&1
}

provider::issue_from_branch() {  # <branch> → echoes issue number, or nothing
  local branch="$1"
  if [[ "$branch" =~ ^([1-9][0-9]*)-.+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
  return 0
}

provider::pr_title() {  # <issue> <title> → "Is<NNN>: <title>" (idempotent)
  local issue="$1" t="$2"
  if [ -z "$issue" ]; then
    printf '%s\n' "$t"
  elif [[ "$t" =~ ^Is${issue}:[[:space:]] ]]; then
    printf '%s\n' "$t"
  else
    printf 'Is%s: %s\n' "$issue" "$t"
  fi
}

provider::pr_body() {  # <issue> → "Closes #NNN"
  printf 'Closes #%s\n' "$1"
}

provider::trigger_reviews() {  # <pr_number> <level: copilot|copilot+claude>
  local pr_number="$1" level="$2"
  local pr_node_id copilot_bot_id

  pr_node_id="$(gh pr view "$pr_number" --json id --jq '.id')"

  # Copilot's reviewer bot is a fixed bot account; resolve its node id live
  # rather than hardcoding it, in case it ever differs per install.
  copilot_bot_id="$(gh api "users/copilot-pull-request-reviewer%5Bbot%5D" --jq '.node_id' 2>/dev/null || true)"
  if [ -n "$copilot_bot_id" ]; then
    # botIds must be inlined into the query body, not passed as a `-F`/`-f`
    # variable — gh api's field flags pass JSON-array-shaped strings through
    # as literal strings rather than deserializing them into a GraphQL list.
    # (Confirmed against this exact mutation.)
    gh api graphql -f query="
      mutation(\$pid: ID!) {
        requestReviews(input: { pullRequestId: \$pid, botIds: [\"$copilot_bot_id\"], union: true }) {
          clientMutationId
        }
      }" -f pid="$pr_node_id" >/dev/null \
      && echo "open-pr: requested Copilot review on #$pr_number" >&2 \
      || echo "open-pr: WARN Copilot review request failed" >&2
  else
    echo "open-pr: WARN couldn't resolve Copilot bot id, skipping Copilot review request" >&2
  fi

  if [ "$level" = "copilot+claude" ]; then
    if gh workflow view claude.yml >/dev/null 2>&1; then
      gh workflow run claude.yml -f "pr_number=$pr_number" >/dev/null \
        && echo "open-pr: dispatched claude.yml review for #$pr_number" >&2 \
        || echo "open-pr: WARN claude.yml dispatch failed" >&2
    else
      echo "open-pr: WARN no claude.yml workflow in this repo — skipping Claude review dispatch" >&2
    fi
  fi
}
