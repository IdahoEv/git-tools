#!/usr/bin/env bash
# setup-ticket-profile.sh — install the iTerm2 "Ticket" dynamic profile that
# start-ticket.sh relies on for a locked, non-clobberable tab title.
#
# Writes ~/Library/Application Support/iTerm2/DynamicProfiles/ticket-tab.json.
# iTerm2 reloads that directory live, so the profile is available immediately.
# start-ticket.sh degrades to the Default profile if it's absent, making this
# a one-time setup step (e.g. on a fresh machine).
#
# Idempotent and non-destructive: if the file already exists it is left as-is,
# so any local customization to the profile is preserved.

set -euo pipefail

dir="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
file="$dir/ticket-tab.json"

if [ -f "$file" ]; then
  printf 'Ticket profile already present at %s — leaving it untouched.\n' "$file"
  exit 0
fi

mkdir -p "$dir"

cat > "$file" <<'JSON'
{
  "Profiles": [
    {
      "Name": "Ticket",
      "Guid": "1AC7831D-A9E6-4A67-9E90-14097AD448DA",
      "Dynamic Profile Parent Name": "Default",
      "Title Components": 1,
      "Allow Title Setting": false
    }
  ]
}
JSON

printf 'Installed Ticket profile at %s\n' "$file"
printf 'iTerm2 picks up DynamicProfiles live; "Ticket" is available now.\n'
