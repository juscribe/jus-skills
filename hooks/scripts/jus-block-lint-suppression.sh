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

# Each entry: regex pattern + human-readable label + the file types whose
# linter actually reads the directive. Outside those types the token is inert
# text (docs quoting a rule, shell test fixtures) and must not block (#1985).
# Extensionless entries (Gemfile, Rakefile) are matched by basename.
patterns=(
  '#[[:space:]]*rubocop:disable|rubocop:disable|rb rake gemspec ru Gemfile Rakefile'
  '#[[:space:]]*rubocop:todo|rubocop:todo|rb rake gemspec ru Gemfile Rakefile'
  ':reek:[A-Za-z]|:reek: comment|rb rake gemspec ru Gemfile Rakefile'
  '//[[:space:]]*eslint-disable|eslint-disable|ts tsx js jsx mjs cjs'
  '/\*[[:space:]]*eslint-disable|eslint-disable (block)|ts tsx js jsx mjs cjs'
  '//[[:space:]]*prettier-ignore|prettier-ignore|ts tsx js jsx mjs cjs'
  '/\*[[:space:]]*prettier-ignore|prettier-ignore (block)|ts tsx js jsx mjs cjs css scss'
  '//[[:space:]]*@ts-ignore|@ts-ignore|ts tsx js jsx'
  '//[[:space:]]*@ts-expect-error|@ts-expect-error|ts tsx js jsx'
  '//[[:space:]]*@ts-nocheck|@ts-nocheck|ts tsx js jsx'
  '#[[:space:]]*type:[[:space:]]*ignore|type: ignore (mypy)|py'
  '#[[:space:]]*pyright:[[:space:]]*ignore|pyright: ignore|py'
  '//[[:space:]]*nolint|nolint (Go)|go'
  '#nosec|#nosec (gosec)|go'
)

file_path=$(jq -r '.tool_input.file_path // ""' <<<"$input")
base="${file_path##*/}"
ext="${base##*.}" # extensionless files (Gemfile, Rakefile) yield the basename

for entry in "${patterns[@]}"; do
  pattern="${entry%%|*}"
  rest="${entry#*|}"
  label="${rest%%|*}"
  exts="${rest#*|}"
  # Skip patterns whose linter never reads this file type. An empty file_path
  # stays fail-closed: every pattern remains active when the target is unknown.
  if [[ -n "$file_path" && " $exts " != *" $ext "* ]]; then
    continue
  fi
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
