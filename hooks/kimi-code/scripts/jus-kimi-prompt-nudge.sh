#!/usr/bin/env bash
# UserPromptSubmit hook: Kimi Code's mid-session commit reminder (#1977). Kimi
# ignores PostToolUse output entirely (observe-only), but stdout from an exit-0
# UserPromptSubmit hook IS injected into the model's context — so the reminder
# rides the next user prompt rather than the Nth edit.
#
# ⚠️ THIS HAS NO CLAUDE CODE COUNTERPART, AND THAT IS NOT AN OVERSIGHT (#3952).
# It began as the Kimi channel for `jus-dirty-tree-nudge.sh`, which was deleted
# because it emitted `systemMessage` only — a field the model never receives, so
# it had been reminding nobody for months. This one is context-injected and does
# reach the model, which is why it survived the same review. Deleting it for
# symmetry would remove the working half of the pair.
#
# CRITICAL: UserPromptSubmit is a BLOCKABLE event on Kimi — exit 2 here would
# block the user's own prompt. This script must always exit 0; every failure
# path is a silent allow.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0
jq . >/dev/null 2>&1 <<<"$input" || exit 0

cwd=$(jq -r '.cwd // ""' <<<"$input" 2>/dev/null) || exit 0
[[ -d "$cwd" ]] || exit 0
( cd "$cwd" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ) || exit 0

dirty_count=$( (cd "$cwd" && git status --porcelain 2>/dev/null) | wc -l | tr -d ' ' ) || exit 0
[[ "${dirty_count:-0}" -gt 0 ]] || exit 0

echo "[jus] The working tree has ${dirty_count} uncommitted change(s). The Juscribe SOP commits IMMEDIATELY after code changes are complete and linters pass — if these changes are done, lint and commit them before continuing."
exit 0
