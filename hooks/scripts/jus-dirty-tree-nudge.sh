#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): when this session has left enough DISTINCT
# files dirty AND checks have run since the last edit, emit a `systemMessage`
# reminding Claude to commit.
#
# ── it counts files, derived, rather than accumulating a counter (#2352) ──────
#
# An earlier version incremented `unsaved_edits` on every edit and nudged at 5.
# That was a second source of truth for something edits.log already knew, and
# the two disagreed in three ways:
#
#   * DOUBLE COUNTING. A repo that registers these hooks both from its own
#     settings and from the installed plugin (#2353) delivers every event
#     twice, so the counter reached 5 in 3 edits — and then reported "5 file
#     edits", a number that had not happened. A derived count is the same
#     however many times it is asked.
#   * OPERATIONS, NOT FILES. Five Edits refining one method tripped a nudge
#     whose text said "file edits".
#   * NO SELF-CLEARING. The counter needed an explicit reset on commit;
#     committed files simply leave the dirty set.
#
# ── and it waits for checks to have run ──────────────────────────────────────
#
# On a project that writes the failing test first — this bundle's default, though
# the ordering is the installing project's to set (#2586) — the tree is
# necessarily dirty and the suite necessarily red across that span, lefthook
# would reject the commit anyway, and there is no correct commit to make. A
# nudge there fires where compliance is impossible, which trains its reader to
# filter it out — and then it is absent on the occasion the tree is genuinely
# dirty because attention drifted.
#
# `last_linted_at >= last_modified_at` means checks have run since the last
# edit: a commit was possible and did not happen. That is the only window in
# which this message names something actionable.
#
# ⚠️ It reads as "checks were RUN", not "checks PASSED" — the Bash
# tool_response carries no exit status, so jus-post-bash-tracker records a
# failing lint too (#1873, deliberate). lefthook remains the thing that blocks a
# broken commit; this only decides when to speak.
#
# The end-of-turn case is covered separately and harder by
# jus-stop-uncommitted.sh, which blocks rather than nudges.
#
# ── AND IT FIRES ONCE PER TICKET, NOT ONCE PER EDIT (#3507) ──────────────────
#
# Measured before this dedup: 288 fires across 52 sessions — median 4, and 32 in
# the worst single session. Every one said the same thing. A message repeated 32
# times is a message read zero times, and the cost lands on the occasion the tree
# is genuinely dirty because attention drifted.
#
# The dedup scope is the active ticket, falling back to the session, matching
# jus-docs-nudge.sh exactly — including the reason for the fallback: work that
# never picked up a ticket still gets one nudge rather than none. The flag is
# cleared when the tree goes clean, so a second unrelated batch of uncommitted
# work in the same ticket is nudged again. That is the point: it tracks
# "you have work sitting" rather than "you have been told once, ever".
#
# ⚠️ THIS HOOK WAS ONCE SLATED FOR DELETION AND SHOULD NOT BE (#3507). The
# argument was that jus-stop-uncommitted.sh covers the same ground. It does not:
# Stop runs on ONE of the four ways a turn ends, and an interrupted or errored
# turn never dispatches it. This hook fires during the turn, so it is the only
# thing that speaks at all on those paths. See .jus/docs/skill-triggering.md.

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
modified_at=$(juscribe_sop_read_num "${state_dir}/last_modified_at")
linted_at=$(juscribe_sop_read_num "${state_dir}/last_linted_at")

if (( linted_at < modified_at )); then
  exit 0
fi

toplevel=$(juscribe_sop_repo_toplevel "$cwd")
if [[ -z "$toplevel" ]]; then
  exit 0
fi

# Dedup scope: the active ticket, or "session" when no ticket has been picked
# up. Same scheme as jus-docs-nudge.sh, so the two behave alike.
active_ticket=$(cat "${state_dir}/active_ticket" 2>/dev/null | tr -d '[:space:]' || echo "")
nudge_flag="${state_dir}/dirty_tree_nudged_${active_ticket:-session}"

# Unscoped — see juscribe_sop_dirty_lines. The per-session ownership scoping was
# removed in #2392; worktrees are the isolation strategy.
count=$(juscribe_sop_dirty_lines "$toplevel" | grep -c . || true)

# A clean tree clears the flag, so the NEXT batch of uncommitted work is nudged
# again. Without this the hook speaks once per ticket for the ticket's lifetime,
# which is the opposite failure from firing 32 times.
if (( count == 0 )); then
  rm -f "$nudge_flag"
  exit 0
fi

if (( count < NUDGE_THRESHOLD )); then
  exit 0
fi

# Already spoke for this ticket, and the tree has not been clean since.
[[ -e "$nudge_flag" ]] && exit 0
mkdir -p "$state_dir"
: > "$nudge_flag"

# Emit a system message via JSON output. Exit 0 with valid JSON on stdout
# is processed by Claude Code as structured hook output.
jq -n --argjson count "$count" '{
  systemMessage: ("[jus:hard-rules] " + ($count|tostring) + " files are uncommitted, and checks have run since your last edit. The Juscribe SOP requires committing IMMEDIATELY once code changes are complete and linters pass — treat an uncommitted change like an unsaved file. If these are not ready to commit together, commit the part that is.")
}'

exit 0
