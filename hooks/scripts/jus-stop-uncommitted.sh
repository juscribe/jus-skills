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
#     (see juscribe_sop_session_worktree).
#   - If the working tree is clean, exit 0.
#   - Otherwise, exit 2 with stderr naming the command that lists the dirty
#     files, with the tree it checked already in it.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
cwd=$(jq -r '.cwd // ""' <<<"$input")
juscribe_sop_require_jus_project "$cwd"
session_id=$(jq -r '.session_id // ""' <<<"$input")
stop_hook_active=$(jq -r '.stop_hook_active // false' <<<"$input")

# Already nudged once this turn — let Claude stop to avoid an infinite loop.
if [[ "$stop_hook_active" == "true" ]]; then
  exit 0
fi

toplevel=$(juscribe_sop_repo_toplevel "$cwd")
[[ -z "$toplevel" ]] && exit 0

# ⚠️ ASK THE RIGHT TREE FIRST. A session working in a worktree keeps its
# cwd at the MAIN checkout and cd's in per command, so `cwd` names a tree it
# never edits — and blocking a stop over another session's uncommitted files is
# both wrong and unfixable by the session it lands on. When a worktree is locked
# in this session's name, that is the tree to check. No such lock leaves the
# behaviour below exactly as it was.
session_worktree=$(juscribe_sop_session_worktree "$toplevel" "$session_id")
# An earlier version also added a paragraph saying which tree had been checked,
# because the file list was relative to it and a reader standing in the main
# checkout saw a different set. The message now names the command instead of
# the files, with this path already in it — so it says which tree AND is
# runnable from wherever the reader is. One message form, no branch.
if [[ -n "$session_worktree" ]]; then
  toplevel="$session_worktree"
fi

# The WHOLE tree, unscoped. This used to intersect against a per-session log of
# edited files so two sessions sharing a checkout would not claim each other's
# work; that machinery was removed — worktrees are the isolation
# strategy, and in a worktree every dirty file is genuinely yours. Resolving
# WHICH worktree, above, is not that machinery coming back: nothing records what
# a session edited, and the statement it rests on is unchanged.
# Only read to decide WHETHER to block. What is dirty is the agent's to look up,
# which is what makes the message O(1) rather than one line per file.
blocking=$(juscribe_sop_dirty_lines "$toplevel")

if [[ -z "$blocking" ]]; then
  exit 0
fi

# What is blocked, the one command that shows what is blocking it, and what to
# do with what it shows. The tree is checked WHOLE, so in a checkout two
# sessions share it lists the other session's files too, and "Commit them" told
# a read-only session to commit someone else's work, several times over. The SOP quote and
# the numbered commit steps that used to sit here are justification and restated
# gate — CLAUDE.md is in context at the moment this fires, and the hook gets one
# shot per turn (`stop_hook_active`), so the shot is spent on instruction.
cat >&2 <<EOF
[jus:hard-rules] STOP BLOCKED: uncommitted changes.

git -C ${toplevel} status --porcelain

Commit the files you changed. A file you did not change is not yours to commit:
in a shared checkout it can be another session's work in progress. Leave it,
and tell the user it is there. Never abandon your own changes silently.
EOF
exit 2
