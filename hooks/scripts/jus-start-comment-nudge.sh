#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): when a SOURCE file is edited on a ticket that
# has been transitioned to `started` but no start comment has been posted yet,
# emit a NON-BLOCKING `systemMessage` reminding Claude to post the start
# comment first. Mirrors dirty-tree-nudge.sh — it never blocks (exit 0 always).
#
# The start comment is the earliest stakeholder-facing signal that work began
# and where root-cause + plan + test intent are declared. It deliberately does
# NOT name a methodology (#2586): this bundle ships to projects that do not
# practise test-first development, and a nudge telling them they owe "TDD
# intent" asserts someone else's policy in text they cannot edit.
# It is prompt-only in
# both CLAUDE.md modes (no hook hard-blocks it); this nudge is the soft
# backstop so a run cannot silently skip it. See #1852.
#
# State is written by jus-post-bash-tracker.sh (PostToolUse Bash), which reads
# `jus api` calls:
#   active_ticket          — id of the ticket last transitioned to `started`
#   started_at             — when that transition happened
#   start_comment_posted   — set once a comment is POSTed to the active ticket
#   start_nudged           — set here so the nudge fires at most once per ticket

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
# Resolves a repo-relative recorded path so an extensionless shell script can be
# classified by its shebang (#2387). Without a base, such a path is not probed.
cwd=$(jq -r '.cwd // ""' <<<"$input")
base_dir=$(juscribe_sop_repo_toplevel "$cwd")
[[ -n "$base_dir" ]] || base_dir="$cwd"
state_dir=$(juscribe_sop_state_dir "$session_id")

# Only nudge for ticket work — a `started` transition must have been observed.
# Trim whitespace defensively so the ticket id renders cleanly in the message.
active=$(cat "${state_dir}/active_ticket" 2>/dev/null | tr -d '[:space:]' || echo "")
[[ -n "$active" ]] || exit 0
[[ -f "${state_dir}/started_at" ]] || exit 0

# Stay quiet once a start comment exists, or if we already nudged this ticket.
if [[ -f "${state_dir}/start_comment_posted" ]]; then exit 0; fi
if [[ -f "${state_dir}/start_nudged" ]]; then exit 0; fi

# Only nudge on source-file edits (the same set the pre-commit gate cares
# about) — doc/config edits do not require the start-comment-before-coding step.
if ! juscribe_sop_is_code_file "$file_path" "$base_dir"; then exit 0; fi

# Fire once.
mkdir -p "$state_dir"
date +%s > "${state_dir}/start_nudged"

jq -n --arg ticket "$active" '{
  systemMessage: ("[jus:hard-rules] You are editing a source file on ticket #" + $ticket + " but have not posted a start comment yet. The Juscribe SOP wants a \"Starting\" comment — root cause + plan + test intent — on the ticket BEFORE the first code edit. Post it now (jus api POST /workspaces/{ws}/tickets/" + $ticket + "/comments ...), then continue.")
}'

exit 0
