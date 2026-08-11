#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): record that a file was edited this session.
#
# Updates per-session state used by `pre-commit-gate.sh` and
# `dirty-tree-nudge.sh`:
#   last_modified_at  — unix timestamp of this edit
#   edits.log         — append the edited file path
#
# An `unsaved_edits` counter used to live here too. It was removed in #2352:
# edits.log already knows which files are outstanding, and a counter cannot
# survive the same hook being registered twice (#2353) — it double-counted, so
# the nudge fired at 3 edits while reporting 5. Anything that needs "how much
# is outstanding" derives it from edits.log ∩ `git status` instead, via
# juscribe_sop_session_dirty_lines.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")

case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

session_id=$(jq -r '.session_id // ""' <<<"$input")
file_path=$(jq -r '.tool_input.file_path // ""' <<<"$input")

state_dir=$(juscribe_sop_state_dir "$session_id")
mkdir -p "$state_dir"

date +%s > "${state_dir}/last_modified_at"

if [[ -n "$file_path" ]]; then
  echo "$file_path" >> "${state_dir}/edits.log"
  # A recorded edit supersedes any post-commit edits_cleared_at sentinel
  # (#2355): the log is non-empty again, so scoping returns to intersecting
  # against it, and the sentinel must not linger into the next commit cycle.
  rm -f "${state_dir}/edits_cleared_at"
fi

exit 0
