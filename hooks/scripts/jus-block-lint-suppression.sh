#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): block edits that introduce a NEW lint or
# type-check suppression comment.
#
# The Juscribe SOP forbids inline suppression of linters and type-checkers.
# Fix the underlying smell instead. This hook compares old vs. new content
# and only blocks when the count of a suppression pattern increases.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
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

# Each entry: regex pattern + human-readable label.
patterns=(
  '#[[:space:]]*rubocop:disable|rubocop:disable'
  '#[[:space:]]*rubocop:todo|rubocop:todo'
  ':reek:[A-Za-z]|:reek: comment'
  '//[[:space:]]*eslint-disable|eslint-disable'
  '/\*[[:space:]]*eslint-disable|eslint-disable (block)'
  '//[[:space:]]*prettier-ignore|prettier-ignore'
  '/\*[[:space:]]*prettier-ignore|prettier-ignore (block)'
  '//[[:space:]]*@ts-ignore|@ts-ignore'
  '//[[:space:]]*@ts-expect-error|@ts-expect-error'
  '//[[:space:]]*@ts-nocheck|@ts-nocheck'
  '#[[:space:]]*type:[[:space:]]*ignore|type: ignore (mypy)'
  '#[[:space:]]*pyright:[[:space:]]*ignore|pyright: ignore'
  '//[[:space:]]*nolint|nolint (Go)'
  '#nosec|#nosec (gosec)'
)

for entry in "${patterns[@]}"; do
  pattern="${entry%%|*}"
  label="${entry#*|}"
  new_count=$(grep -cE "$pattern" <<<"$new_content" 2>/dev/null || true)
  old_count=$(grep -cE "$pattern" <<<"$old_content" 2>/dev/null || true)
  # grep -c may emit "0" or empty; coerce to integer
  new_count=${new_count:-0}
  old_count=${old_count:-0}
  if (( new_count > old_count )); then
    cat >&2 <<EOF
[jus:hard-rules] BLOCKED: lint/type suppression added.

Detected new occurrence of: $label

The Juscribe SOP forbids inline suppression of linters and type-checkers.
Fix the underlying issue instead:

  - Refactor to remove the smell (smaller methods, better names, etc.).
  - For TypeScript: type the value correctly instead of @ts-ignore /
    @ts-expect-error / @ts-nocheck.
  - For genuine false positives: escalate to the stakeholder before
    silencing — never silence silently.

If a suppression is structurally accepted (e.g. an established pattern in
the codebase), discuss with the stakeholder before introducing more.
EOF
    exit 2
  fi
done

exit 0
