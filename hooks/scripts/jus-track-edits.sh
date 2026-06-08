#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): record that a file was edited this session.
#
# Updates per-session state used by `pre-commit-gate.sh` and
# `dirty-tree-nudge.sh`:
#   last_modified_at  — unix timestamp of this edit
#   edits.log         — append the edited file path
#   unsaved_edits     — increment counter for the dirty-tree nudge

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
fi

count=$(juscribe_sop_read_num "${state_dir}/unsaved_edits")
echo $((count + 1)) > "${state_dir}/unsaved_edits"

exit 0
