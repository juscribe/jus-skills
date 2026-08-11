#!/usr/bin/env bash
# PreToolUse hook (Bash): refuse a `jus api PATCH` that edits the DESCRIPTION of
# an accepted or cancelled ticket.
#
# The SOP forbids it already — a shipped runbook is a historical record, and
# rewriting one makes a finished release look like it has unrun commands (the
# 2026-08-06 incident). It was violated anyway on 2026-08-10: #2266 was patched
# while `accepted`.
#
# ⚠️ THE MECHANISM IS WHY A PROMPT-LEVEL RULE COULD NOT PREVENT IT. The state
# check and the PATCH were issued in the SAME command block, so the "accepted"
# reading came back AFTER the write had already gone. A check that cannot gate
# the action is not a check, it is a receipt. This hook runs before the tool
# call, which is the only place the ordering is guaranteed.
#
# NOT blocked, deliberately:
#   - POST .../comments on any state. Recording a correction on an accepted
#     manifest is the SANCTIONED path; blocking it would push people toward the
#     very edit this prevents.
#   - PATCH .../transition, .../reorder and friends — sub-resources, not the
#     description.
#   - A PATCH whose body does not mention description (labels, assignees, points).
#
# Fails OPEN when the ticket's state cannot be read. A guardrail that blocks
# every ticket edit the moment the API is unreachable would be worse than the
# thing it guards; the warning still prints. Same "guardrail, not sandbox"
# posture as jus-block-force-push.sh.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")
[[ "$tool_name" != "Bash" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")

# Must be a PATCH to a ticket ROOT: /workspaces/<ws>/tickets/<id>. Extracted with
# grep rather than a bash regex — the bracket-expression form needed here is easy
# to get subtly wrong, and a guard that silently never matches is worse than no
# guard at all.
# `|| true` because grep exits 1 on no-match and `set -e` would turn "this is
# not a ticket PATCH" into a hook crash — which fails CLOSED on every unrelated
# Bash command.
match=$(grep -oE "(bin/)?jus[[:space:]]+api[[:space:]]+PATCH[[:space:]]+[\"']?/workspaces/[0-9]+/tickets/[0-9]+" <<<"$command" | tail -1 || true)
[[ -n "$match" ]] || exit 0
ticket_id="${match##*/}"

# A trailing sub-resource means it is not a description rewrite:
# .../tickets/123/transition, /reorder, /dependencies all pass through.
[[ "$command" == */tickets/"$ticket_id"/* ]] && exit 0

# Only a description rewrite is forbidden. Editing labels, points or assignees
# on a closed ticket is ordinary bookkeeping.
[[ "$command" == *description* ]] || exit 0

# ⚠️ `jus api` prints an "HTTP 200" status line (with colour codes) BEFORE the
# JSON body, so piping it straight into jq fails with "Invalid numeric literal"
# — and because this hook fails open, that silently turned the whole guard into
# a no-op. `sed -n '/{/,$p'` drops everything before the first brace.
state=$(jus api GET "/workspaces/1/tickets/${ticket_id}?fields=state" 2>/dev/null \
  | sed -n '/{/,$p' \
  | jq -r '.ticket.state // empty' 2>/dev/null || true)

if [[ -z "$state" ]]; then
  printf '[jus:hard-rules] could not read state for #%s — allowing the PATCH.\n' \
    "$ticket_id" >&2
  printf '  Verify by hand that it is not accepted before rewriting a description.\n' >&2
  exit 0
fi

case "$state" in
  accepted | cancelled)
    cat >&2 <<EOF
[jus:hard-rules] BLOCKED: #${ticket_id} is ${state} — do not rewrite its description.

A shipped runbook is a historical record. Rewriting one makes a finished release
look like it has unrun commands, which is the 2026-08-06 incident inverted and
just as misleading.

If you need to correct or add to it, POST A COMMENT instead — that is the
sanctioned path and this hook never blocks it:

  jus api POST /workspaces/1/tickets/${ticket_id}/comments "\$(cat body.json)"

If the work genuinely is not shipped, the answer is a NEW manifest, not an edit
to an accepted one.
EOF
    exit 2
    ;;
esac

exit 0
