#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): record that a file was edited this session.
#
# Updates per-session state, read ONLY by `pre-commit-gate.sh`:
#   last_modified_at  — unix timestamp of this edit, so the gate can ask
#                       "have lints run since?"
#   edits.log         — the edited file paths, so the gate can ask "was any of
#                       this a code file, or is it a doc-only commit?"
#
# ⚠️ edits.log is NOT an ownership record. It used to double as one — the stop
# hook intersected it with `git status` to decide which dirty files a session
# could claim when several shared a checkout. That machinery was removed in
# #2392 (worktrees are the isolation strategy); the log survives purely as the
# lint gate's input, and a commit clears it so the gate does not re-fire.

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

exit 0
