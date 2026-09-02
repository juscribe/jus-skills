#!/usr/bin/env bash
# Docs nudge — surface the project doc for a subsystem at the moment the
# information can still change the plan. Two trigger moments, one dedup:
#
# 1. TICKET PICKUP (PostToolUse Bash, #2487): when a `jus api` command
#    transitions a ticket to `started`, fetch its title + labels (one sparse
#    GET) and match them against `label:`/`kw:` rows in the map. By the first
#    edit the approach is usually already chosen — measured on #2090, where
#    the container threat model doc was mapped by path but never surfaced,
#    because nothing keyed on picking the ticket up.
# 2. FIRST EDIT under a mapped path (PostToolUse Edit|Write|MultiEdit,
#    #2285/#2277): the original trigger, for work whose relevance shows in
#    the files touched rather than the ticket's shape.
#
# Fires at most once per doc per active ticket (session fallback) ACROSS both
# moments — a pickup nudge suppresses the edit nudge for the same doc. Every
# other outcome is a silent exit 0, including every failure of the pickup
# fetch (no `jus` on PATH, network error, non-JSON response): this is a
# nudge, never a gate.
#
# The map is PROJECT data, never bundled: tab-separated, one rule per line,
# in `.jus/docs-nudges.tsv` at the project root:
#   <project-relative path prefix>\t<doc path>[\t<when-to-read hint>]
#   label:<name>\t<doc path>[\t<when-to-read hint>]   # ticket label, case-insensitive
#   kw:<word>\t<doc path>[\t<when-to-read hint>]      # title substring, case-insensitive
# Path rows fire on edits; label:/kw: rows fire at pickup. No map file → this
# hook is a silent no-op, so shipping it in the bundle is safe for projects
# that keep no docs directory. A path-only map costs the pickup path nothing:
# with no trigger rows there is no fetch.
#
# THE HINT IS OPTIONAL (#3393). Omit the third column and the hint is read
# from the docs index beside the doc — see docs_index_hint below. A row is two
# kinds of work and only one is expensive: the trigger is a judgement nothing
# can derive, while the hint needs someone to have read the doc, and a project
# that keeps an index has already written it. Hand-duplicating it is what left
# 50 of this project's 81 deep-dives with no row at all.
#
# UserPromptSubmit was considered as a third trigger for work that never gets
# a ticket, and DECLINED (#2487): the SOP requires a ticket for every piece
# of work, and keyword-matching conversational prose false-positives far more
# than ticket titles — noise erodes exactly the trust an advisory nudge runs
# on. Revisit with measurement if ticketless work keeps missing docs.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")

case "$tool_name" in
  Edit|Write|MultiEdit|Bash) ;;
  *) exit 0 ;;
esac

project_dir="${CLAUDE_PROJECT_DIR:-}"
[[ -n "$project_dir" ]] || exit 0
map_file="${project_dir}/.jus/docs-nudges.tsv"
[[ -f "$map_file" ]] || exit 0

session_id=$(jq -r '.session_id // ""' <<<"$input")
state_dir=$(juscribe_sop_state_dir "$session_id")

# Dedup flag for a doc within a scope (a ticket id, or "session" as the
# fallback). One naming scheme for both trigger moments is what makes a
# pickup nudge and an edit nudge for the same doc collapse into one message.
docs_nudge_flag() {
  local scope="$1" doc="$2"
  printf '%s/docs_nudged_%s_%s' "$state_dir" "$scope" "$(tr -c 'a-zA-Z0-9' '_' <<<"$doc")"
}

# The hint for a row that omitted its third column, read from the docs index
# that sits BESIDE the doc — `docs/css.md` looks in `docs/INDEX.md`. Resolved
# relative to the doc rather than the project, because a bundled hook cannot
# assume any one docs directory. One entry per line, in the shape the index
# already uses:
#
#   - [css.md](css.md) — When to read: adding or modifying any styles — and …
#
# Only the FIRST CLAUSE is taken, cut at the first em-dash clause break or the
# first sentence end. The full entries run long — measured over this project's
# 81 docs, a median of 398 characters and one at 4718 — and the systemMessage
# below is one line built with no truncation, so interpolating a whole entry
# would bury the doc name the message exists to deliver. The first clause is a
# median of 116 characters with 2 over 250.
#
# A cut that lands INSIDE a parenthetical drops the rest of it rather than
# leaving the bracket open: 4 of those 81 end mid-aside, and `(#2870` hanging
# off the end of a one-line reminder reads as the truncation being a bug.
#
# EVERY failure is an empty result, and the callers read that as "no nudge":
# no index file, no entry for this doc, an index in some other format. That is
# the property that makes a two-column row safe to ship to a project that keeps
# no index at all — the row degrades to silence, never to an error and never to
# a half-written message with an empty hint dangling off it.
docs_index_hint() {
  local doc="$1" index_file
  index_file="${project_dir}/$(dirname "$doc")/INDEX.md"
  [[ -f "$index_file" ]] || return 0
  jq -Rrs --arg name "$(basename "$doc")" '
    ($name | gsub("[.]"; "[.]")) as $q
    | ((split("\n")
        | map(select(test("^[[:space:]]*-[[:space:]]*\\[" + $q + "\\]")))
        | first) // "")
    | (capture("When to read:[[:space:]]*(?<h>.+)$") // {h: ""}).h
    | split("\\s+\u2014\\s+|[.]\\s+"; null)[0]
    | (if ([scan("[(]")] | length) > ([scan("[)]")] | length)
       then sub("[[:space:]]*[(][^()]*$"; "") else . end)
    | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")
  ' < "$index_file" 2>/dev/null || return 0
}

# ---- pickup trigger (Bash) --------------------------------------------------

if [[ "$tool_name" == "Bash" ]]; then
  command=$(jq -r '.tool_input.command // ""' <<<"$input")
  interrupted=$(jq -r '.tool_response.interrupted // false' <<<"$input")
  [[ "$interrupted" == "true" ]] && exit 0

  # The same signal that maintains active_ticket (jus-post-bash-tracker.sh),
  # read from the command itself so there is no ordering dependency on the
  # tracker having run first — hooks on one event may run concurrently.
  ticket_id=$(juscribe_sop_started_ticket "$command")
  [[ -n "$ticket_id" ]] || exit 0

  # Zero-cost for path-only maps: no trigger rows means no fetch and no nudge.
  grep -Eq '^(label|kw):' "$map_file" || exit 0

  command -v jus >/dev/null 2>&1 || exit 0
  [[ "$command" =~ workspaces/([0-9]+)/tickets/${ticket_id}/transition ]] || exit 0
  workspace_id="${BASH_REMATCH[1]}"

  # One sparse GET, from the project directory so the jus CLI finds its
  # config. Any failure from here on is a silent allow.
  response=$(cd "$project_dir" && jus api GET \
    "/workspaces/${workspace_id}/tickets/${ticket_id}?fields=title,labels&include_label_objects=false" \
    2>/dev/null) || exit 0
  title=$(jq -r '.ticket.title // ""' <<<"$response" 2>/dev/null) || exit 0
  labels=$(jq -r '(.ticket.labels // []) | join("\n")' <<<"$response" 2>/dev/null) || exit 0
  title_lc=$(tr '[:upper:]' '[:lower:]' <<<"$title")
  labels_lc=$(tr '[:upper:]' '[:lower:]' <<<"$labels")

  # Collect matching trigger rows — ordered, unique by doc, skipping docs
  # already nudged for this ticket. Strings rather than arrays: hooks must
  # run on macOS's stock bash 3.2.
  matched=""
  seen_docs=$'\n'
  while IFS=$'\t' read -r trigger doc hint; do
    [[ -n "$trigger" && -n "$doc" ]] || continue
    hit=""
    case "$trigger" in
      label:*)
        want=$(tr '[:upper:]' '[:lower:]' <<<"${trigger#label:}")
        [[ -n "$want" ]] || continue
        while IFS= read -r label; do
          [[ "$label" == "$want" ]] && hit=1 && break
        done <<<"$labels_lc"
        ;;
      kw:*)
        want=$(tr '[:upper:]' '[:lower:]' <<<"${trigger#kw:}")
        [[ -n "$want" && "$title_lc" == *"$want"* ]] && hit=1
        ;;
      *) continue ;;
    esac
    [[ -n "$hit" ]] || continue
    # A row with no hint of its own takes one from the index; one that cannot
    # is skipped rather than marked seen, so a later row naming the same doc
    # with an explicit hint still gets its chance.
    [[ -n "$hint" ]] || hint=$(docs_index_hint "$doc")
    [[ -n "$hint" ]] || continue
    [[ "$seen_docs" == *$'\n'"$doc"$'\n'* ]] && continue
    [[ -f "$(docs_nudge_flag "$ticket_id" "$doc")" ]] && continue
    seen_docs+="$doc"$'\n'
    matched+="$doc"$'\t'"$hint"$'\n'
  done < "$map_file"

  [[ -n "$matched" ]] || exit 0

  mkdir -p "$state_dir"
  docs_list=""
  while IFS=$'\t' read -r doc hint; do
    [[ -n "$doc" ]] || continue
    date +%s > "$(docs_nudge_flag "$ticket_id" "$doc")"
    [[ -n "$docs_list" ]] && docs_list+="; "
    docs_list+="\`${doc}\` — ${hint}"
  done <<<"$matched"

  jq -n --arg ticket "$ticket_id" --arg docs "$docs_list" '{
    systemMessage: ("[jus:docs] Picking up ticket #" + $ticket + " — this project maps docs to areas it touches: " + $docs + ". Read them before planning the work; the project docs index maps the rest.")
  }'
  exit 0
fi

# ---- edit trigger (Edit|Write|MultiEdit) ------------------------------------

file_path=$(jq -r '.tool_input.file_path // ""' <<<"$input")
[[ -n "$file_path" ]] || exit 0

# Only project files can match project-relative prefixes.
case "$file_path" in
  "$project_dir"/*) relative_path="${file_path#"$project_dir"/}" ;;
  *) exit 0 ;;
esac

# Longest-prefix match so a specific rule can override a broader one.
# label:/kw: rows are pickup triggers, never path prefixes.
matched_doc=""
matched_hint=""
matched_len=0
while IFS=$'\t' read -r prefix doc hint; do
  [[ -n "$prefix" && -n "$doc" ]] || continue
  case "$prefix" in
    label:* | kw:*) continue ;;
  esac
  case "$relative_path" in
    "$prefix"*)
      if (( ${#prefix} > matched_len )); then
        matched_doc="$doc"
        matched_hint="$hint"
        matched_len=${#prefix}
      fi
      ;;
  esac
done < "$map_file"

[[ -n "$matched_doc" ]] || exit 0

# Resolved BEFORE the dedup flag is written: a row whose hint cannot be
# resolved produces no nudge, and must not burn the one nudge this doc gets
# for this ticket on a message that was never sent.
[[ -n "$matched_hint" ]] || matched_hint=$(docs_index_hint "$matched_doc")
[[ -n "$matched_hint" ]] || exit 0

# Dedup scope: once per doc per ACTIVE TICKET, not per session — the limit is
# on the reminder, never on reading. Long sessions span many tickets, and
# context compaction can drop an hours-old nudge; each ticket pickup
# re-surfaces the relevant doc once. With no active ticket the scope falls
# back to the session.
active_ticket=$(cat "${state_dir}/active_ticket" 2>/dev/null | tr -d '[:space:]' || echo "")
scope="${active_ticket:-session}"
flag="$(docs_nudge_flag "$scope" "$matched_doc")"
[[ -f "$flag" ]] && exit 0

mkdir -p "$state_dir"
date +%s > "$flag"

jq -n --arg doc "$matched_doc" --arg hint "$matched_hint" '{
  systemMessage: ("[jus:docs] You are editing files this project documents in `" + $doc + "` — " + $hint + ". Read it before going further; the project docs index maps the rest.")
}'

exit 0
