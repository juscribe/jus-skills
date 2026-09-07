#!/usr/bin/env bash
# PreToolUse hook (Bash): say something when a dependency is written with a time
# in its text and no date in its columns.
#
# A blocker carries `due_on` (`YYYY-MM-DD`) and `due_kind`, and the board reads
# both: `wait_until` is a hard do-not-start-before, `review_on` brings someone
# back to decide, `expected_by` is a forecast. A blocker whose own condition IS a
# time — "over a full 7-day window", "three days after the rollout" — and whose
# date column is null gives the board nothing to bring anyone back with, so the
# ticket reads as blocked forever and is found only when a human goes looking.
#
# The SOP's other blocker rules are about STRUCTURE and WORDING — one row per
# independently-clearing condition, each row stating only its own condition, the
# title patched beside the description — and a dateless time blocker passes every
# one of them. Measured on the project this hook was written in: a blocker read
# "over a full 7-day window" and sat dateless until the stakeholder asked.
#
# ⚠️ IT NUDGES AND NEVER REFUSES. Whether a phrase is a constraint or incidental
# prose is not something a pattern can settle: the blocker above also quoted
# "SINCE 7 days ago" out of a log query, and no regex separates the two. A hook
# that refused would block correct blockers and teach people to word around it.
# jus-block-force-push.sh refuses because the cost is a rewritten history; the
# cost here is a missing date.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
[[ "$(jq -r '.tool_name // ""' <<<"$input")" == "Bash" ]] || exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")
[[ -n "$command" ]] || exit 0
payload_cwd=$(jq -r '.cwd // ""' <<<"$input")
[[ -d "$payload_cwd" ]] || payload_cwd="$PWD"

# Only a write that WORDS a blocker. GET and DELETE carry no text, and the verb
# is part of the match so neither reaches the route test below.
#
# `|| true` because grep exits 1 on no-match and `set -e` would turn "this is not
# a dependency write" into a hook crash on every unrelated Bash command.
match=$(grep -oE "(bin/)?jus[[:space:]]+api[[:space:]]+(POST|PATCH)[[:space:]]+['\"]?/workspaces/[^[:space:]'\"]+" \
  <<<"$command" | tail -1 || true)
[[ -n "$match" ]] || exit 0
route="/workspaces${match#*/workspaces}"

# Anchored, so a trailing segment falls out: `.../dependencies/631/resolve`
# closes a blocker rather than wording one, and must stay silent.
if ! [[ $route =~ ^/workspaces/[0-9]+/(tickets|projects)/[0-9]+/dependencies$ ]] &&
   ! [[ $route =~ ^/workspaces/[0-9]+/dependencies/[0-9]+$ ]]; then
  exit 0
fi

body="${command#*"$match"}"

# ⚠️ THE BODY IS USUALLY NOT IN THE COMMAND. The SOP forbids inlining prose into
# a shell argument — one apostrophe ends a quoted string — so the prescribed form
# writes the JSON to a file and passes `"$(cat file)"`. Read what we can reach.
readable=""
while IFS= read -r reference; do
  [[ -n "$reference" ]] || continue
  path=${reference#*cat }
  path=${path%)}
  path=$(tr -d "\"'" <<<"$path" | sed -E 's/^ +| +$//g')
  [[ "$path" == /* ]] || path="${payload_cwd}/${path}"
  [[ -r "$path" ]] || continue
  readable+=$(cat "$path")
done < <(grep -oE '\$\(cat [^)]+\)' <<<"$body" || true)
body+="$readable"

# A quoted value rather than mere presence: clearing a date sets both halves to
# null on purpose, and that is not a row missing its date.
grep -qE '"?due_on"?[[:space:]]*:[[:space:]]*"' <<<"$body" && exit 0

# A duration however it is spelled, an ISO date, a month-and-day, or a cadence.
# ⚠️ No `\b` — BSD grep spells it `[[:<:]]` and GNU spells it `\b`, so the right
# edge is a non-letter instead. That trailing guard is what keeps `dec` out of
# "decision 3" and `3 day` out of a version string.
TIME_PATTERNS='[0-9]+[ -]?(second|minute|hour|day|week|month|quarter|year)s?([^a-z]|$)'
TIME_PATTERNS+='|(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)[ -](second|minute|hour|day|week|month|quarter|year)s?([^a-z]|$)'
TIME_PATTERNS+='|[0-9]{4}-[0-9]{2}-[0-9]{2}'
TIME_PATTERNS+='|(january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)[.,]? [0-9]{1,2}([^0-9]|$)'
TIME_PATTERNS+='|(daily|weekly|monthly|quarterly|nightly|overnight|fortnight)'

reason=""
if grep -qiE "$TIME_PATTERNS" <<<"$body"; then
  reason="This blocker's text names a time and the row carries no date."
elif [[ -z "${body//[[:space:]\"\']/}" || ( "$body" == *'$(cat '* && -z "$readable" ) ]]; then
  # The body is behind a variable this hook cannot expand, so whether it names a
  # time is unknowable from here. Dependency writes are rare, so asking once per
  # write is cheap, and a silent miss is the failure this exists to catch.
  reason="This hook cannot read the body of this dependency write."
fi
[[ -n "$reason" ]] || exit 0

jq -n --arg reason "$reason" '{
  systemMessage: ("[jus:hard-rules] " + $reason + " A blocker whose own condition is a time MUST carry both `due_on` (YYYY-MM-DD) and `due_kind`, or nothing on the board ever brings anyone back to it and the ticket reads as blocked forever. Pick the kind: `wait_until` (a hard do-not-start-before), `review_on` (revisit and decide, and push the date if the condition still is not met), `expected_by` (a forecast, informational). Neither half works alone — each without the other is a 422. If the condition genuinely has no time in it, carry on.")
}'

exit 0
