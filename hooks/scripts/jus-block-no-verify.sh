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

# Block `--no-verify` only as an argument word of a segment that invokes git
# (commit, push, merge, …). Substring matching over the raw command string
# blocked quoted comment bodies, docs echoes, and greps of this script (#1985).
# Splitting/quote-stripping lives in lib/state.sh.
noverify_re='(^|[[:space:]])--no-verify([[:space:]]|$)'
noverify_found=0
while IFS= read -r segment; do
  if juscribe_sop_segment_invokes_git "$segment" \
      && [[ "$segment" =~ $noverify_re ]]; then
    noverify_found=1
    break
  fi
done < <(juscribe_sop_command_segments "$command")

if (( noverify_found )); then
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
