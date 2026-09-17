#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|MultiEdit): block edits that introduce a NEW lint
# or type-check suppression comment.
#
# The Juscribe SOP forbids inline suppression of linters and type-checkers.
# Fix the underlying smell instead. This hook compares old vs. new content
# and only blocks when the count of a suppression pattern increases.
#
# ⚠️ THE TABLE IS NOT HERE — it is in lib/lint_suppressions.sh, shared with the
# commit-time guard (#4347). This hook only sees tool events, so a change made
# with `sed` or a heredoc walks straight past it; the commit guard is what
# closes that. Both read one array so they cannot disagree about what a
# suppression is.
#
# This one is kept because it is strictly better WHEN it fires: it stops the
# line before it exists and explains why at the moment of writing.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
# shellcheck source=lib/lint_suppressions.sh
source "$(dirname "$0")/lib/lint_suppressions.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
juscribe_sop_require_jus_project "$(jq -r '.cwd // ""' <<<"$input")"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")

case "$tool_name" in
  Edit)
    new_content=$(jq -r '.tool_input.new_string // ""' <<<"$input")
    old_content=$(jq -r '.tool_input.old_string // ""' <<<"$input")
    ;;
  Write)
    new_content=$(jq -r '.tool_input.content // ""' <<<"$input")
    old_content=""
    ;;
  MultiEdit)
    # MultiEdit isn't currently part of the matcher, but handle defensively:
    new_content=$(jq -r '[.tool_input.edits[]?.new_string // ""] | join("\n")' <<<"$input")
    old_content=$(jq -r '[.tool_input.edits[]?.old_string // ""] | join("\n")' <<<"$input")
    ;;
  *)
    exit 0
    ;;
esac

file_path=$(jq -r '.tool_input.file_path // ""' <<<"$input")

# The shebang clause of the type rule needs the file's FIRST line, and an Edit
# carries only the replaced fragment. Read it from disk when the file is there;
# a Write of a new shell script carries its own shebang in the content.
first_line=""
if [[ -n $file_path && -r $file_path ]]; then
  first_line=$(head -n 1 "$file_path" 2>/dev/null || true)
else
  first_line=$(head -n 1 <<<"$new_content")
fi

# An empty file_path stays fail-closed: the type stays empty and every pattern
# remains active when the target is unknown.
file_type=""
if [[ -n $file_path ]]; then
  jus_lint_suppression_type_into file_type "$file_path" "$first_line"
fi

while IFS= read -r row; do
  types=$(jus_lint_suppression_types "$row")
  jus_lint_suppression_applies "$types" "$file_type" || continue

  regex=$(jus_lint_suppression_regex "$row")
  # ⚠️ COUNTS, NOT A MATCH. An Edit whose old_string already carries the
  # suppression is moving a line rather than adding one, and blocking it would
  # make every later edit to that file impossible.
  new_count=$(grep -cE "$regex" <<<"$new_content" 2>/dev/null || true)
  old_count=$(grep -cE "$regex" <<<"$old_content" 2>/dev/null || true)
  # grep -c may emit "0" or empty; coerce to integer
  new_count=${new_count:-0}
  old_count=${old_count:-0}
  if ((new_count > old_count)); then
    jus_lint_suppression_explain \
      "Detected new occurrence of: $(jus_lint_suppression_label "$row")" >&2
    exit 2
  fi
done < <(jus_lint_suppression_rows)

exit 0
