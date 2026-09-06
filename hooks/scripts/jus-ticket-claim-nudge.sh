#!/usr/bin/env bash
# UserPromptSubmit hook (#3668): the moment a prompt names a ticket, put the
# 👀 on it and hand the agent the ticket it would otherwise go and fetch.
#
# WHY THIS IS A HOOK AND NOT A RULE. Measured across 365 session transcripts in
# this project, over prompts naming exactly one ticket: median 21.0s from the
# ask to the `started` transition, p75 43.5s, p90 129.0s, 19% over a minute
# (n=411). The median ask spends two tool calls — typically a skill load and a
# GET of the ticket — before anything reaches the board, and the fastest claim
# in the entire corpus was 4.6s. That floor is structural: an agent cannot
# react until the model emits a tool call. UserPromptSubmit runs BEFORE the
# model does, so it is the only place the reaction can beat that floor.
#
# ⚠️ IT DOES NOT TRANSITION THE TICKET, AND THAT IS THE DESIGN, NOT A TODO.
# Also measured: of 551 prompts naming a single ticket, only 79% were followed
# by that ticket being started. The remaining 21% are questions and asides —
# "how come i dont see changes that #3266 made?", "does this at all affect
# #2411?", "put the time in #2891 in pacific". Auto-starting would wrongly move
# about one ticket in five into `current`, and #2487 already declined
# keyword-matching conversational prose for a merely ADVISORY nudge; the bar
# for a mutation is higher, not lower.
#
# So the hook takes the half that is always true — the agent is about to look —
# and leaves the state change to the agent's judgement. What it buys there is
# that the judgement now happens on the agent's FIRST call rather than its
# third, because the ticket and the exact claim command are already in context.
#
# ⚠️ THE REACTION ENDPOINT IS A TOGGLE (CLAUDE.md, #3138). Firing it on a
# ticket that already carries our 👀 REMOVES it, so this reads `reacted_by_me`
# and keeps a per-session marker. Both guards matter: the marker alone would
# still double-toggle across two sessions.
#
# Fails open everywhere. UserPromptSubmit is a BLOCKABLE event — exit 2 would
# swallow the user's message — so nothing here is worth a non-zero exit.
#
# Environment: TICKET_CLAIM_JUS (default: jus), TICKET_CLAIM_WORKSPACE
# (default: read from .jus/config/workspace_id — see juscribe_sop_workspace_id),
# TICKET_CLAIM_MAX (3 tickets per prompt — the hook is synchronous on the
# user's keystroke, so a batch ask must not fan out into a dozen calls).

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

JUS="${TICKET_CLAIM_JUS:-jus}"
MAX="${TICKET_CLAIM_MAX:-3}"

command -v "$JUS" >/dev/null 2>&1 || exit 0

input=$(cat)
juscribe_sop_require_valid_json "$input"

[[ "$(jq -r '.hook_event_name // ""' <<<"$input")" == "UserPromptSubmit" ]] || exit 0

prompt=$(jq -r '.prompt // ""' <<<"$input")
[[ -n "$prompt" ]] || exit 0

# Ticket ids in the prompt. Everything that is neither alphanumeric nor `#`
# becomes a separator, so `(#3668)` and `#3668,` yield the token `#3668` while
# `ab#1234` stays one token that does not START with `#` and is therefore not a
# reference. Two digits minimum keeps ordinary prose ("the #1 thing") from
# costing an API call on the user's keystroke.
ids=$(tr -c '[:alnum:]#' ' ' <<<"$prompt" \
        | tr ' ' '\n' \
        | grep -E '^#[0-9]{2,6}$' \
        | tr -d '#' \
        | awk '!seen[$0]++' \
        | head -n "$MAX" || true)
[[ -n "$ids" ]] || exit 0

session_id=$(jq -r '.session_id // ""' <<<"$input")
state_dir=$(juscribe_sop_state_dir "$session_id")
cwd=$(jq -r '.cwd // ""' <<<"$input")
[[ -d "$cwd" ]] || cwd="$PWD"

# ⚠️ SILENCE RATHER THAN A DEFAULT. This hook shipped with `1` hardcoded while
# it was monumental-only (#3668); in the bundle that would fetch a REAL ticket
# belonging to somebody else's workspace 1, and react to it. An unresolvable
# workspace means this is not a jus project, which is not an error worth saying
# anything about. The walk-up itself is shared with the release hook (#3684) —
# see juscribe_sop_workspace_id, which carries the why-not-the-git-toplevel note.
WORKSPACE="${TICKET_CLAIM_WORKSPACE:-}"
if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE=$(juscribe_sop_workspace_id "$cwd") || exit 0
fi
[[ -n "$WORKSPACE" ]] || exit 0

blocks=""
summaries=""

while read -r id; do
  [[ -n "$id" ]] || continue

  # Fire once per ticket per session. A follow-up naming the same ticket must
  # not toggle the reaction back off.
  marker="${state_dir}/claimed_${id}"
  [[ -f "$marker" ]] && continue

  ticket=$(cd "$cwd" && "$JUS" api GET \
    "/workspaces/${WORKSPACE}/tickets/${id}?include_comments=true" 2>/dev/null || true)

  # A 404, an HTML error page or a truncated body all land here and are all
  # silence — this hook never reports on the API's behalf.
  jq -e '.ticket.id' >/dev/null 2>&1 <<<"$ticket" || continue

  mkdir -p "$state_dir"
  : > "$marker"

  reacted=$(jq -r '
    [.ticket.ticket_reactions[]? | select(.emoji == "👀") | .reacted_by_me] | any
  ' <<<"$ticket" 2>/dev/null || echo "false")

  if [[ "$reacted" != "true" ]]; then
    (cd "$cwd" && "$JUS" api POST \
      "/workspaces/${WORKSPACE}/tickets/${id}/ticket_reactions/toggle" \
      '{"emoji":"👀"}' >/dev/null 2>&1) || true
  fi

  state=$(jq -r '.ticket.state // ""' <<<"$ticket")

  # The lock the agent still owes. `/transition` steps ONE state at a time, so
  # an icebox ticket needs the intermediate `prioritized` hop spelled out —
  # without it the agent spends a round trip discovering the 422. A ticket
  # already in flight gets no command at all: starting a `started` ticket is
  # itself a 422.
  claim=""
  case "$state" in
    unprioritized)
      claim="jus api PATCH /workspaces/${WORKSPACE}/tickets/${id}/transition '{\"state\":\"prioritized\"}' && jus api PATCH /workspaces/${WORKSPACE}/tickets/${id}/transition '{\"state\":\"started\"}'"
      ;;
    prioritized|rejected)
      claim="jus api PATCH /workspaces/${WORKSPACE}/tickets/${id}/transition '{\"state\":\"started\"}'"
      ;;
  esac

  block=$(jq -r --arg id "$id" --arg claim "$claim" '
    .ticket as $t
    | [ "### #" + $id + " — " + ($t.title // "(untitled)"),
        "state: " + ($t.state // "?")
          + " | points: " + (($t.points // "unset") | tostring)
          + " | blocked: " + (($t.blocked // false) | tostring)
          + " | assignees: " + (([$t.assignees[]?.username] | join(", ")) // "none"),
        "",
        "description:",
        (($t.description // "(none)") | .[0:1400]),
        ""
      ]
      + (if ($t.comments | length) > 0
         then ["recent comments:"]
              + ([$t.comments[-3:][] | "- " + (.user.username // "?") + ": "
                   + ((.body // "") | gsub("\\s+"; " ") | .[0:320])])
              + [""]
         else [] end)
      + (if $claim == "" then [] else
          ["To take the concurrency lock, run this now (only if this really is a"
           + " request to WORK the ticket — a question about it is not):",
           "", "```sh", $claim, "```", ""] end)
    | join("\n")
  ' <<<"$ticket" 2>/dev/null || true)

  # A ticket whose id parsed but whose body did not render contributes NOTHING.
  # Appending an empty block would still satisfy the guard below and produce a
  # message telling the agent the ticket was fetched, with no ticket in it.
  [[ -n "$block" ]] || continue
  summaries+="#${id} "
  blocks+="${block}"$'\n'
done <<<"$ids"

[[ -n "$blocks" ]] || exit 0

context="[jus:pickup] Your prompt named a ticket. I have already posted the 👀 on the board, and fetched it for you — do NOT spend a call re-fetching it.

${blocks}
Pre-start gate: a ticket needs a description and points before it goes to \`started\`, and \`stakeholder_id\` set. Transition BEFORE investigating — it is the concurrency lock."

jq -n --arg ctx "${context:0:7800}" --arg ids "$summaries" '
  {
    systemMessage: ("[jus] 👀 " + ($ids | rtrimstr(" ")) + " — fetched and reacted before the turn started."),
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $ctx }
  }'

exit 0
