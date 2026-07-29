#!/usr/bin/env bash
# Codex → shared-script payload normalizer (#1976).
#
# Codex hook payloads already match the shared scripts' contract for Bash and
# Stop (tool_name "Bash" with a string tool_input.command; Stop carries
# stop_hook_active + cwd). The one divergence is file edits: Codex sends
# tool_name "apply_patch" with tool_input.command holding the RAW PATCH TEXT
# ("*** Begin Patch" format) — there is no file_path / old_string /
# new_string. This shim rewrites such payloads into the Edit shape the shared
# scripts consume — added (+) lines become new_string, removed (-) lines
# old_string, the first "*** Update|Add File:" path becomes file_path — then
# execs the real hook with the normalized payload on stdin. Every other
# payload passes through untouched, so the same shim can front any shared
# script in the Codex manifest.
#
# Usage (from hooks/codex/hooks.json):
#   jus-codex-adapt.sh <shared-script> [args...]
#
# Fail-open philosophy matches lib/state.sh: missing target, missing jq, or
# malformed input exits 0 rather than wedging the tool call.
set -euo pipefail

target="${1:-}"
shift || true
if [[ -z "$target" || ! -x "$target" ]]; then
  exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
jq . >/dev/null 2>&1 <<<"$input" || exit 0

tool_name=$(jq -r '.tool_name // ""' <<<"$input")
if [[ "$tool_name" != "apply_patch" ]]; then
  exec "$target" "$@" <<<"$input"
fi

patch=$(jq -r '.tool_input.command // ""' <<<"$input")
file_path=$(grep -m1 -E '^\*\*\* (Update|Add) File: ' <<<"$patch" | sed -E 's/^\*\*\* (Update|Add) File: //' || true)
# Patch body lines: +added / -removed. Header lines all start with "***".
new_string=$(grep -E '^\+' <<<"$patch" | sed 's/^+//' || true)
old_string=$(grep -E '^-' <<<"$patch" | sed 's/^-//' || true)

normalized=$(jq --arg fp "$file_path" --arg new "$new_string" --arg old "$old_string" \
  '.tool_name = "Edit" | .tool_input = {file_path: $fp, new_string: $new, old_string: $old}' \
  <<<"$input" 2>/dev/null) || exit 0

exec "$target" "$@" <<<"$normalized"
