#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): once enough edits have accumulated without a
# commit, emit a `systemMessage` reminding Claude to commit.
#
# Threshold is intentionally low — the SOP says "commit IMMEDIATELY after code
# changes." This nudge fires when the working tree has stayed dirty across
# multiple consecutive edits.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

NUDGE_THRESHOLD="${JUSCRIBE_SOP_NUDGE_THRESHOLD:-5}"

input=$(cat)
juscribe_sop_require_valid_json "$input"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")

case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

session_id=$(jq -r '.session_id // ""' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")

state_dir=$(juscribe_sop_state_dir "$session_id")
count=$(juscribe_sop_read_num "${state_dir}/unsaved_edits")

if (( count < NUDGE_THRESHOLD )); then
  exit 0
fi

# Verify the working tree is actually dirty before nudging — the user may
# have committed via a tool we didn't see, leaving the counter stale.
if [[ -z "$cwd" ]] || ! command -v git >/dev/null 2>&1; then
  exit 0
fi

if ! ( cd "$cwd" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ); then
  exit 0
fi

dirty=""
if pushd "$cwd" >/dev/null 2>&1; then
  dirty=$(git status --porcelain 2>/dev/null | head -1)
  popd >/dev/null
fi
if [[ -z "$dirty" ]]; then
  echo 0 > "${state_dir}/unsaved_edits"
  exit 0
fi

# Reset the counter so the nudge fires once per N edits, not on every edit
# past the threshold.
echo 0 > "${state_dir}/unsaved_edits"

# Emit a system message via JSON output. Exit 0 with valid JSON on stdout
# is processed by Claude Code as structured hook output.
jq -n --argjson count "$count" '{
  systemMessage: ("[jus:hard-rules] You have made " + ($count|tostring) + " file edits without committing. The Juscribe SOP requires committing IMMEDIATELY after code changes are complete and linters pass. Treat an uncommitted change like an unsaved file — commit before responding to the user, before self-review, before anything else.")
}'

exit 0
