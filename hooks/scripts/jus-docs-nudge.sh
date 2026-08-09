#!/usr/bin/env bash
# PostToolUse hook (Edit|Write|MultiEdit): on the FIRST edit under a path the
# project has mapped in `.jus/docs-nudges.tsv`, emit a non-blocking
# systemMessage naming the project doc for that subsystem and its when-to-read
# hint. Fires at most once per doc per active ticket (session fallback);
# every other outcome is a silent exit 0.
#
# Why (#2285/#2277): prompt-level doc pointers are read once at session start
# and forgotten under mid-task pressure — a documented gotcha was measured
# being re-derived from scratch 15 hours after being written up. This is the
# start-comment-nudge machinery applied to documentation.
#
# The map is PROJECT data, never bundled: tab-separated, one rule per line,
# in `.jus/docs-nudges.tsv` at the project root:
#   <project-relative path prefix>\t<doc path>\t<when-to-read hint>
# No map file → this hook is a silent no-op, so shipping it in the bundle is
# safe for projects that keep no docs directory.

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

project_dir="${CLAUDE_PROJECT_DIR:-}"
[[ -n "$project_dir" ]] || exit 0
map_file="${project_dir}/.jus/docs-nudges.tsv"
[[ -f "$map_file" ]] || exit 0

file_path=$(jq -r '.tool_input.file_path // ""' <<<"$input")
[[ -n "$file_path" ]] || exit 0

# Only project files can match project-relative prefixes.
case "$file_path" in
  "$project_dir"/*) relative_path="${file_path#"$project_dir"/}" ;;
  *) exit 0 ;;
esac

# Longest-prefix match so a specific rule can override a broader one.
matched_doc=""
matched_hint=""
matched_len=0
while IFS=$'\t' read -r prefix doc hint; do
  [[ -n "$prefix" && -n "$doc" ]] || continue
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

session_id=$(jq -r '.session_id // ""' <<<"$input")
state_dir=$(juscribe_sop_state_dir "$session_id")

# Dedup scope: once per doc per ACTIVE TICKET, not per session — the limit is
# on the reminder, never on reading. Long sessions span many tickets, and
# context compaction can drop an hours-old nudge; each ticket pickup
# re-surfaces the relevant doc once. With no active ticket the scope falls
# back to the session.
active_ticket=$(cat "${state_dir}/active_ticket" 2>/dev/null | tr -d '[:space:]' || echo "")
scope="${active_ticket:-session}"
flag="${state_dir}/docs_nudged_${scope}_$(tr -c 'a-zA-Z0-9' '_' <<<"$matched_doc")"
[[ -f "$flag" ]] && exit 0

mkdir -p "$state_dir"
date +%s > "$flag"

jq -n --arg doc "$matched_doc" --arg hint "$matched_hint" '{
  systemMessage: ("[jus:docs] You are editing files this project documents in `" + $doc + "` — " + $hint + ". Read it before going further; the project docs index maps the rest.")
}'

exit 0
