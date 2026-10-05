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

provider::pr_body() {  # <issue> → "Closes #NNN" (default body, no --body-file)
  printf 'Closes #%s\n' "$1"
}

provider::pr_body_footer() {  # <issue> → "Closes #NNN", appended to a drafted body
  # GitHub issues share a namespace with PRs here, so the auto-close keyword is
  # meaningful and belongs on every PR — including ones whose body /open-pr
  # drafted. open-pr.sh skips this when the body already contains it.
  printf 'Closes #%s\n' "$1"
}

provider::trigger_reviews() {  # <pr_number> <level: copilot|copilot+claude>
  local pr_number="$1" level="$2"

  # Delegates to request-review.sh (single source of truth for the Copilot
  # requestReviews mutation + claude.yml dispatch) so the same logic is also
  # reachable standalone — e.g. to re-request a Copilot review after a later
  # push, which doesn't happen automatically. $SCRIPT_DIR is open-pr.sh's,
  # inherited since this provider is sourced into its process.
  "$SCRIPT_DIR/request-review.sh" --pr "$pr_number" --level "$level" >/dev/null \
    || echo "open-pr: WARN review request failed (see request-review output above)" >&2
}
