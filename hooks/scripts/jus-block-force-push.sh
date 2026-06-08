#!/usr/bin/env bash
# PreToolUse hook (Bash): block `git push --force` and variants.
#
# Force-pushing rewrites shared history and is destructive. The Juscribe SOP
# forbids it. This is a deterministic backstop for the prompt-level rule in
# `jus:hard-rules`.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")
[[ "$tool_name" != "Bash" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")

# Only inspect commands that include `git push`.
if ! [[ "$command" =~ (^|[[:space:]])git[[:space:]]+push([[:space:]]|$) ]]; then
  exit 0
fi

# Block --force, -f, and --force-with-lease. The SOP is "never force-push", and
# --force-with-lease is still a force-push (just a safer one).
if [[ "$command" =~ (--force-with-lease|--force([^[:alnum:]_-]|$)|[[:space:]]-f([[:space:]]|$)) ]]; then
  cat >&2 <<'EOF'
[jus:hard-rules] BLOCKED: `git push --force` (and variants) is forbidden.

The Juscribe SOP is unambiguous: NEVER force-push. Force-pushing rewrites
shared history and destroys other people's work. Even `--force-with-lease`
is forbidden — the stakeholder pushes manually.

If you genuinely need to undo a published commit, use `git revert` to add a
NEW commit that reverses it, and let the stakeholder handle the push.
EOF
  exit 2
fi

exit 0
