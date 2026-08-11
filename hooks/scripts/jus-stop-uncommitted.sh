#!/usr/bin/env bash
# Stop hook: prevent Claude from ending its turn when the working tree is
# dirty.
#
# The Juscribe SOP says "Treat an uncommitted change with the same urgency
# as an unsaved file." Stopping with uncommitted changes hides work from the
# stakeholder and risks losing it.
#
# Behaviour:
#   - If `stop_hook_active=true`, exit 0 (avoid infinite loops — Claude has
#     already been told to commit at least once this turn).
#   - If the cwd isn't a git repo, exit 0 (nothing to check).
#   - If the working tree is clean, exit 0.
#   - Otherwise, exit 2 with stderr listing the dirty files and instructions.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
cwd=$(jq -r '.cwd // ""' <<<"$input")
session_id=$(jq -r '.session_id // ""' <<<"$input")
stop_hook_active=$(jq -r '.stop_hook_active // false' <<<"$input")

# Already nudged once this turn — let Claude stop to avoid an infinite loop.
if [[ "$stop_hook_active" == "true" ]]; then
  exit 0
fi

toplevel=$(juscribe_sop_repo_toplevel "$cwd")
[[ -z "$toplevel" ]] && exit 0

# Scoped to the files THIS session touched (#2216) by the shared helper, which
# jus-dirty-tree-nudge.sh also uses so both hooks answer "which dirty files does
# this session own" identically by construction (#2352).
blocking=$(juscribe_sop_session_dirty_lines "$toplevel" "$session_id")
blocking="${blocking%$'\n'}"

if [[ -z "$blocking" ]]; then
  exit 0
fi

files=$(head -20 <<<"$blocking")

# Cap the file list so we don't flood the message
overflow=""
total=$( wc -l <<<"$blocking" | tr -d ' ' )
if (( total > 20 )); then
  overflow=$'\n... and '"$((total - 20))"' more'
fi

cat >&2 <<EOF
[jus:hard-rules] STOP BLOCKED: working tree is dirty.

The Juscribe SOP forbids ending a session or turn with uncommitted changes:
"Treat an uncommitted change with the same urgency as an unsaved file."

Files with pending changes:
${files}${overflow}

Required next action:
  1. Run the applicable linters on the modified files.
  2. Commit with a "[#N] Short description" message referencing the ticket.
  3. Then stop.

If the changes are intentional WIP that genuinely shouldn't be committed,
discuss with the stakeholder before stopping — don't silently abandon them.
EOF
exit 2
