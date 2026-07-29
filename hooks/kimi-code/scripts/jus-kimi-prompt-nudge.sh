#!/usr/bin/env bash
# UserPromptSubmit hook: Kimi Code's replacement channel for the dirty-tree
# nudge (#1977). Kimi ignores PostToolUse output entirely (observe-only), but
# stdout from an exit-0 UserPromptSubmit hook IS injected into the model's
# context — so the commit-immediately reminder rides the next user prompt
# instead of the Nth edit.
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
