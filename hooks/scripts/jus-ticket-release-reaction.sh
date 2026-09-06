#!/usr/bin/env bash
# PostToolUse hook, Bash (#3684): when a transition just moved a ticket to a
# state where the work is over, take our 👀 back off it.
#
# THE MISSING HALF OF #3668. That ticket shipped the claim side — a
# UserPromptSubmit hook that puts the eyes on a ticket the moment a prompt names
# it. Nothing ever took them off. "Remove 👀 by toggling it off before or after
# transitioning to `finished`" existed only as prose, in .jus/sop/workflows.md
# and in the published ticket-workflow skill, and it competes for attention with
# the delivery comment, two transitions and a release-manifest row.
#
# Measured on the live board 2026-09-05, as the agent token: 12 of 34
# `delivered` tickets still carried our 👀, plus 3 `cancelled` ones. A third of
# the delivered column read as actively worked.
#
# ⚠️ IT RE-READS THE TICKET AND DECIDES FROM ITS REAL STATE. It never trusts a
# state parsed out of the command body. Two reasons, and the second is the one
# that bites: the body's quoting varies, and a PATCH that 422'd leaves the
# ticket exactly where it was — so the command says `delivered` while the board
# says `started`.
#
# ⚠️ THE ENDPOINT IS A TOGGLE, NOT A SETTER (CLAUDE.md, #3138). Firing it on a
# ticket that no longer carries our reaction ADDS one, which would make this
# hook the thing putting stale eyes on the board it exists to clear. Every
# toggle is gated on reading `reacted_by_me` first — the same guard, for the
# same reason, as its sibling on the claim side.
#
# Fails open everywhere. PostToolUse runs after a command the agent already ran;
# nothing here is worth failing that command over.
#
# Environment: TICKET_RELEASE_JUS (default: jus), TICKET_RELEASE_WORKSPACE
# (default: the walk-up in juscribe_sop_workspace_id).

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

JUS="${TICKET_RELEASE_JUS:-jus}"
command -v "$JUS" >/dev/null 2>&1 || exit 0

input=$(cat)
juscribe_sop_require_valid_json "$input"

[[ "$(jq -r '.tool_name // ""' <<<"$input")" == "Bash" ]] || exit 0

# A cancelled command may have died before the API ever saw it. The board is
# still the authority below, but there is no reason to ask.
[[ "$(jq -r '.tool_response.interrupted // false' <<<"$input")" == "true" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")
ids=$(juscribe_sop_transitioned_tickets "$command")
[[ -n "$ids" ]] || exit 0

cwd=$(jq -r '.cwd // ""' <<<"$input")
[[ -d "$cwd" ]] || cwd="$PWD"

WORKSPACE="${TICKET_RELEASE_WORKSPACE:-}"
if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE=$(juscribe_sop_workspace_id "$cwd") || exit 0
fi
[[ -n "$WORKSPACE" ]] || exit 0

session_id=$(jq -r '.session_id // ""' <<<"$input")
state_dir=$(juscribe_sop_state_dir "$session_id")

# The states in which the eyes are no longer telling the truth.
#
# ⚠️ `rejected` is deliberately absent, and it is the only one that needs
# arguing. A rejection goes straight back to `started` — the agent is about to
# pick the ticket up again, so the reaction still says something true. Removing
# it there would make the board flicker across a rejection cycle.
#
# `converted` and `archived` are states too, and omitting them was how the
# state-machine reference used to read as ending at accepted or cancelled.
released=""
while read -r id; do
  [[ -n "$id" ]] || continue

  ticket=$(cd "$cwd" && "$JUS" api GET \
    "/workspaces/${WORKSPACE}/tickets/${id}" 2>/dev/null || true)

  # A 404, an HTML error page or a truncated body all land here and are all
  # silence — this hook never reports on the API's behalf.
  jq -e '.ticket.id' >/dev/null 2>&1 <<<"$ticket" || continue

  case "$(jq -r '.ticket.state // ""' <<<"$ticket")" in
    finished | delivered | accepted | cancelled | converted | archived) ;;
    *) continue ;;
  esac

  reacted=$(jq -r '
    [.ticket.ticket_reactions[]? | select(.emoji == "👀") | .reacted_by_me] | any
  ' <<<"$ticket" 2>/dev/null || echo "false")
  [[ "$reacted" == "true" ]] || continue

  (cd "$cwd" && "$JUS" api POST \
    "/workspaces/${WORKSPACE}/tickets/${id}/ticket_reactions/toggle" \
    '{"emoji":"👀"}' >/dev/null 2>&1) || true

  # The claim hook fires once per ticket per session, guarded by this marker.
  # Left behind, it would assert a reaction that no longer exists and suppress
  # the 👀 on a later prompt naming the same ticket — a ticket reopened after
  # rejection, or simply asked about again.
  rm -f "${state_dir}/claimed_${id}"

  released+="#${id} "
done <<<"$ids"

[[ -n "$released" ]] || exit 0

# systemMessage is rendered to the terminal and never reaches the model
# (.jus/docs/skill-triggering.md, #3498), which is right here: the release is
# bookkeeping the agent has nothing to do about.
jq -n --arg ids "$released" \
  '{ systemMessage: ("[jus] 👀 released on " + ($ids | rtrimstr(" ")) + " — work is done.") }'

exit 0
