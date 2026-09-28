#!/usr/bin/env bash
# UserPromptSubmit hook (#3668): the moment a prompt names a ticket, hand the
# agent the ticket it would otherwise go and fetch, plus the exact command that
# takes the concurrency lock. Since #5118 it hands it over as a CANDIDATE, with
# hints, because a bare `#N` is as often a pull request — see `refs=` below.
#
# WHY THIS IS A HOOK AND NOT A RULE. Measured across 365 session transcripts in
# this project, over prompts naming exactly one ticket: median 21.0s from the
# ask to the `started` transition, p75 43.5s, p90 129.0s, 19% over a minute
# (n=411). The median ask spends two tool calls — typically a skill load and a
# GET of the ticket — before anything reaches the board, and the fastest claim
# in the entire corpus was 4.6s. That floor is structural: an agent cannot act
# until the model emits a tool call. UserPromptSubmit runs BEFORE the model
# does, so it is the only place anything can beat that floor.
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
# ⚠️ IT WRITES NOTHING AT ALL (#3796). Until then it also posted a 👀 on the
# ticket, and jus-ticket-release-reaction.sh took it off again on a transition.
# Measured across all 3,791 tickets on 2026-09-07: 62 carried the agent's 👀
# against 3 genuinely `started`, 47 of the stale ones `accepted`. Six paths left
# it on, and one of them no hook can reach — PostToolUse does not run when the
# Bash command exits non-zero, which `jus api PATCH … | jq …` always does. The
# per-session marker went with it: it existed only to stop the toggle firing
# twice, and the release hook was the one thing that cleared it. Keeping it
# would answer a follow-up from the snapshot taken at the first prompt, which is
# wrong exactly when the ticket moved in between.
#
# `started` plus an assignee is the concurrency lock, and always was.
#
# ⚠️ IT ALSO CARRIES THE jus CLI FLOOR CHECK (#5080), once a session, on any
# prompt — a ticket named or not. This is the one UserPromptSubmit hook every
# manifest registers, so riding it reached all nine without a new registration.
# lib/cli_floor.sh holds the check and the why.
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
# shellcheck source=lib/cli_floor.sh
source "$(dirname "$0")/lib/cli_floor.sh"
juscribe_sop_require_jq

JUS="${TICKET_CLAIM_JUS:-jus}"
MAX="${TICKET_CLAIM_MAX:-3}"

input=$(cat)
juscribe_sop_require_valid_json "$input"

[[ "$(jq -r '.hook_event_name // ""' <<<"$input")" == "UserPromptSubmit" ]] || exit 0

cwd=$(jq -r '.cwd // ""' <<<"$input")
[[ -d "$cwd" ]] || cwd="$PWD"

emit() { # <context for the agent> <line for the user>
  jq -n --arg ctx "${1:0:7800}" --arg msg "$2" '
    { systemMessage: $msg,
      hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $ctx } }'
}

# The project guard runs here only on the check's first prompt, so a prompt
# naming no ticket still costs no `git` call on every later one.
cli_notice=""
if juscribe_sop_cli_floor_due "$JUSCRIBE_SOP_SESSION"; then
  juscribe_sop_require_jus_project "$cwd"
  cli_notice=$(juscribe_sop_cli_floor_check "$JUS")
fi
cli_for_agent="[jus:cli-version] ${cli_notice} Pass this on to the user in those words; it is theirs to run."
cli_for_user="[jus] ${cli_notice}"

# Every way out from here says the CLI notice, when there is one.
finish() {
  [[ -z "$cli_notice" ]] || emit "$cli_for_agent" "$cli_for_user"
  exit 0
}

command -v "$JUS" >/dev/null 2>&1 || finish

prompt=$(jq -r '.prompt // ""' <<<"$input")
[[ -n "$prompt" ]] || finish

# Ticket references in the prompt, one line per id in order of first mention:
# `<id> TAB <explicit 0|1> TAB <word hint>`.
#
# ⚠️ A BARE `#N` IS A CANDIDATE, NOT A CERTAIN TICKET (#5118). Juscribe ids and
# GitHub pull-request/issue numbers both count up from 1, so a lookup cannot
# tell them apart and only the prompt's wording can. The server already cedes
# bare `#N` to GitHub on the commit side (Scm::ReferenceParser, #3778). The
# stakeholder's call: never block, never skip a fetch on a keyword — fetch, and
# tell the MODEL what the wording suggests.
#
# Two passes over one token stream. The outer split keeps `_./-`, so `jus-41`
# survives whole while a URL's `…/jus-41` or `my_jus-41` stays one token that
# does not START with `jus-` — the same guard as `ReferenceParser#prefixed`.
# `jus-N` is the form GitHub cannot produce, so it is marked explicit.
#
# Everything else is split again on anything neither alphanumeric nor `#`, the
# rule this hook has always had: `(#3668)` and `#3668,` yield `#3668`, while
# `ab#1234` and `gh#1234` stay one token that does not start with `#`. Two
# digits minimum keeps "the #1 thing" from costing an API call.
#
# The word hint is the token RIGHT before the number, when it names another
# system. `pull` and `merge` count as the phrase "pull request" / "merge
# request", where the word before the number is `request`. Lengths are checked
# with length() rather than an `{n,m}` interval, which older mawk lacks.
refs=$(tr -c '[:alnum:]#_./-' ' ' <<<"$prompt" | tr -s ' ' '\n' | awk '
  BEGIN { n = split("pr pull issue mr github gh", w, " "); for (i = 1; i <= n; i++) sys[w[i]] = 1 }
  function note(id, explicit, word) {
    if (!(id in seen)) { seen[id] = 1; order[++count] = id; words[id] = "" }
    if (explicit) expl[id] = 1
    if (word != "" && index(words[id], "\"" word "\"") == 0) {
      words[id] = words[id] (words[id] == "" ? "" : " or ") "\"" word "\""
      if (index(word, " ")) phrase[id] = 1
    }
  }
  function step(t) { prev2 = prev; prev = t }
  {
    tok = $0
    if (tolower(tok) ~ /^jus-[0-9]+\.*$/) {
      id = substr(tok, 5); sub(/\.+$/, "", id)
      if (length(id) <= 6) note(id, 1, "")
      step(tok); next
    }
    gsub(/[^A-Za-z0-9#]+/, " ", tok)
    parts = split(tok, part, " ")
    for (i = 1; i <= parts; i++) {
      t = part[i]
      if (t ~ /^#[0-9]+$/ && length(t) >= 3 && length(t) <= 7) {
        p = tolower(prev); word = ""
        if (p in sys) word = prev
        else if (p == "request" && (tolower(prev2) == "pull" || tolower(prev2) == "merge")) word = prev2 " " prev
        note(substr(t, 2), 0, word)
      }
      step(t)
    }
  }
  END {
    for (i = 1; i <= count; i++) {
      id = order[i]; hint = ""
      if (words[id] != "") hint = (phrase[id] ? "the words before it are " : "the word before it is ") words[id]
      printf "%s\t%d\t%s\n", id, (id in expl), hint
    }
  }' | head -n "$MAX" || true)
[[ -n "$refs" ]] || finish

juscribe_sop_require_jus_project "$cwd"

# ⚠️ SILENCE RATHER THAN A DEFAULT. This hook shipped with `1` hardcoded while
# it was monumental-only (#3668); in the bundle that would fetch a REAL ticket
# belonging to somebody else's workspace 1 and feed it to the model as if it
# were theirs. An unresolvable workspace means this is not a jus project, which
# is not an error worth saying anything about. See juscribe_sop_workspace_id,
# which carries the why-not-the-git-toplevel note.
WORKSPACE="${TICKET_CLAIM_WORKSPACE:-}"
if [[ -z "$WORKSPACE" ]]; then
  WORKSPACE=$(juscribe_sop_workspace_id "$cwd") || finish
fi
[[ -n "$WORKSPACE" ]] || finish

# The remote hint, read from local git config — no network call, and silence
# outside a checkout. It is the host, not the whole URL, that is matched: a
# remote NAMED `github`, or a path like `…/mirrors/github-tools.git` on another
# host, says nothing about where this repo's pull requests live. A self-hosted
# GitLab under an unrelated hostname goes unnoticed; that is the price of not
# asking the network.
remote_hints=()
remote_hosts=$(git -C "$cwd" config --get-regexp '^remote\..*\.url$' 2>/dev/null \
                 | cut -d' ' -f2- \
                 | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://##; s#^[^@/]*@##; s#[:/].*$##' \
                 | tr '[:upper:]' '[:lower:]' || true)
grep -q 'github' <<<"$remote_hosts" && remote_hints+=("this repo has a GitHub remote")
grep -q 'gitlab' <<<"$remote_hosts" && remote_hints+=("this repo has a GitLab remote")

blocks=""
summaries=""
mentions=()

while IFS=$'\t' read -r id explicit word_hint; do
  [[ -n "$id" ]] || continue

  ticket=$(cd "$cwd" && "$JUS" api GET \
    "/workspaces/${WORKSPACE}/tickets/${id}?include_comments=true" 2>/dev/null || true)

  # A 404, an HTML error page or a truncated body all land here and are all
  # silence — this hook never reports on the API's behalf.
  jq -e '.ticket.id' >/dev/null 2>&1 <<<"$ticket" || continue

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

  # The hints, only those that apply. `jus-N` settles the question on its own,
  # so it carries that and nothing else; a bare `#N` carries the wording and
  # the remote, either of which may point away from Juscribe.
  hints=()
  if [[ "$explicit" == 1 ]]; then
    mention="jus-${id}"
    hints+=("written as jus-${id}, an explicit Juscribe reference")
  else
    mention="#${id}"
    [[ -n "$word_hint" ]] && hints+=("$word_hint")
    hints+=(${remote_hints[@]+"${remote_hints[@]}"})
  fi
  hint_line=""
  if (( ${#hints[@]} > 0 )); then
    hint_line="Hints: $(printf '%s; ' "${hints[@]}")"
    hint_line="${hint_line%; }."
  fi

  block=$(jq -r --arg id "$id" --arg claim "$claim" --arg hints "$hint_line" '
    .ticket as $t
    | [ "### #" + $id + " — " + ($t.title // "(untitled)") ]
      + (if $hints == "" then [] else [$hints] end)
      + [
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
          ["If this is the ticket meant AND a request to WORK it (a question about"
           + " it is not), take the concurrency lock now:",
           "", "```sh", $claim, "```", ""] end)
    | join("\n")
  ' <<<"$ticket" 2>/dev/null || true)

  # A ticket whose id parsed but whose body did not render contributes NOTHING.
  # Appending an empty block would still satisfy the guard below and produce a
  # message telling the agent the ticket was fetched, with no ticket in it.
  [[ -n "$block" ]] || continue
  summaries+="#${id} "
  mentions+=("$mention")
  blocks+="${block}"$'\n'
done <<<"$refs"

[[ -n "$blocks" ]] || finish

# A candidate, not a certainty (#5118): the model has the whole prompt and the
# hook has a regex, so the hook says what it noticed and the model decides. The
# ask-the-user clause is narrow on purpose — a question suspends the turn, so it
# is for a genuinely unclear number whose answer changes what gets done.
if (( ${#mentions[@]} == 1 )); then
  named="${mentions[0]}"
  offer="If it means a Juscribe ticket, here it is"
  ignore="ignore this block"
else
  named="$(printf '%s, ' "${mentions[@]:0:${#mentions[@]}-1}")"
  named="${named%, } and ${mentions[${#mentions[@]}-1]}"
  offer="If they mean Juscribe tickets, here they are"
  ignore="ignore that number's block"
fi

context="[jus:pickup] Your prompt contains ${named}. ${offer}, already fetched — do NOT spend a call re-fetching it. Nothing has been written to the board.
If the wording points to another system (a pull request, a GitHub or GitLab issue, another tracker), or the number is only an example, ${ignore}. Ask the user only if it is truly unclear AND the answer changes what you would do.

${blocks}
Pre-start gate: a ticket needs a description and points before it goes to \`started\`, and \`stakeholder_id\` set. Transition BEFORE investigating — it is the concurrency lock. Then load the \`ticket-workflow\` skill for the steps after it."

fetched="[jus] ${summaries% } — fetched before the turn started."

# The notice goes FIRST: the context is cut at 7800 characters, and a ticket
# body is what can afford to lose its tail.
if [[ -n "$cli_notice" ]]; then
  emit "${cli_for_agent}"$'\n\n'"${context}" "${cli_for_user}"$'\n'"${fetched}"
else
  emit "$context" "$fetched"
fi

exit 0
