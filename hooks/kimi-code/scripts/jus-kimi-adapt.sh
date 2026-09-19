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

# ⚠️ AN EMPTY `path` MUST NOT BE COPIED, AND MUST NEVER OVERWRITE A GOOD
# `file_path`. This is the empty-string-versus-null class (#4261, audited across
# all seven shims on #4428) in its inverted shape: the test was `!= null`, so a
# `"path": ""` both propagated as an empty `file_path` and clobbered whatever
# was already there.
#
# ⚠️ HYPOTHETICAL RATHER THAN MEASURED, AND SAYING SO IS THE POINT. Kimi was
# driven against a local stub on 2026-09-19 (kimi-code, `Edit` / `Write`): every
# payload carried an absolute `tool_input.path` and no `file_path` sibling at
# all, so neither half has been seen live. The model chooses that argument, so
# an empty one is reachable; the guard costs a clause.
normalized=$(jq 'if (.tool_input | type == "object")
    and ((.tool_input.path? // "") != "")
    and ((.tool_input.file_path? // "") == "")
  then .tool_input.file_path = .tool_input.path
  else . end' <<<"$input" 2>/dev/null) || exit 0

exec "$target" "$@" <<<"$normalized"
