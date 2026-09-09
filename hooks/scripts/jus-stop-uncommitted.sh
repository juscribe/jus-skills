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
#   - If this session locked a worktree, check THAT tree rather than the cwd's
#     (#3667 — see juscribe_sop_session_worktree).
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

# ⚠️ ASK THE RIGHT TREE FIRST (#3667). A session working in a worktree keeps its
# cwd at the MAIN checkout and cd's in per command, so `cwd` names a tree it
# never edits — and blocking a stop over another session's uncommitted files is
# both wrong and unfixable by the session it lands on. When a worktree is locked
# in this session's name, that is the tree to check. No such lock leaves the
# behaviour below exactly as it was.
session_worktree=$(juscribe_sop_session_worktree "$toplevel" "$session_id")
# When the tree checked is NOT the one the session's cwd names, the message has
# to say so. Its paths are relative to that worktree, so a reader who runs
# `git status` where they are standing sees a different set of files — or none —
# and the block reads as spurious. Empty in the ordinary case, so the message
# below is unchanged for a session that is already in the right place.
in_worktree=""
if [[ -n "$session_worktree" && "$session_worktree" != "$toplevel" ]]; then
  toplevel="$session_worktree"
  in_worktree=$'\n\nThese are in the worktree this session locked, not your cwd:\n  '"$toplevel"
fi

# The WHOLE tree, unscoped. This used to intersect against a per-session log of
# edited files so two sessions sharing a checkout would not claim each other's
# work; that machinery was removed in #2392 — worktrees are the isolation
# strategy, and in a worktree every dirty file is genuinely yours. Resolving
# WHICH worktree, above, is not that machinery coming back: nothing records what
# a session edited, and the statement it rests on is unchanged.
blocking=$(juscribe_sop_dirty_lines "$toplevel")
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
${files}${overflow}${in_worktree}

Required next action:
  1. Run the applicable linters on the modified files.
  2. Commit, with the ticket referenced in the message.
  3. Then stop.

If the changes are intentional WIP that genuinely shouldn't be committed,
discuss with the stakeholder before stopping — don't silently abandon them.
EOF
exit 2
