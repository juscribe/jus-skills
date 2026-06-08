#!/usr/bin/env bash
# PreToolUse hook (Bash): block any command that uses `--no-verify`.
#
# `--no-verify` skips git hooks (pre-commit, pre-push). The Juscribe SOP
# forbids skipping hooks — if a hook fails, fix the underlying issue rather
# than bypassing the check.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")
[[ "$tool_name" != "Bash" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")

if [[ "$command" =~ (^|[[:space:]])--no-verify([[:space:]]|$) ]]; then
  cat >&2 <<'EOF'
[jus:hard-rules] BLOCKED: `--no-verify` is forbidden.

`--no-verify` skips git hooks (pre-commit, pre-push). The Juscribe SOP forbids
skipping hooks — they exist to catch broken work before it's committed or
pushed. Bypassing them accumulates breakage that someone has to discover later.

If a hook is genuinely wrong, escalate to the stakeholder and fix the hook
itself. Do not silence it locally.
EOF
  exit 2
fi

exit 0
