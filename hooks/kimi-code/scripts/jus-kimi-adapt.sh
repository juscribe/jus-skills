#!/usr/bin/env bash
# Kimi Code → shared-script payload normalizer (#1977).
#
# Kimi Code hook payloads use Claude's tool names (Bash/Edit/Write) and — for
# the suppression blocker — Claude's own arg keys (new_string / old_string /
# content). The single divergence, captured empirically on kimi-code 0.29.2,
# is that the file path key is `path` where the shared scripts read
# `tool_input.file_path`. This shim copies path → file_path (leaving
# everything else untouched) and execs the real hook with the normalized
# payload on stdin. Payloads without tool_input.path pass through unchanged.
#
# Usage (from hooks/kimi-code/config-hooks.toml or kimi.plugin.json):
#   jus-kimi-adapt.sh <shared-script> [args...]
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

normalized=$(jq 'if (.tool_input | type == "object") and (.tool_input.path? != null)
  then .tool_input.file_path = .tool_input.path
  else . end' <<<"$input" 2>/dev/null) || exit 0

exec "$target" "$@" <<<"$normalized"
