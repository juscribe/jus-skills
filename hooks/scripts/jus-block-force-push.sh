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
juscribe_sop_require_jus_project "$(jq -r '.cwd // ""' <<<"$input")"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")
[[ "$tool_name" != "Bash" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")

# Block --force, -f, --force-with-lease and a `+refspec` (`+main`, which forces
# that one ref with no flag at all) — but only as argument words of a
# segment that itself invokes `git push`. Substring matching over the raw
# command string blocked greps of this script, docs text quoting the rule, and
# jus comment bodies, and let a `-f` belonging to another chained command block
# a plain push. Splitting/quote-stripping lives in lib/state.sh.
#
# Heredoc bodies are stripped first, as jus-block-no-verify.sh does: the SOP
# writes board prose through `<<'EOF'`, and a body line quoting a forced push is
# a segment anchored at column 0. A ticket comment describing this guard was
# once refused while being written.
#
# Out of scope (guardrail, not sandbox): invocations smuggled through quoting
# (`bash -c "…"`, `'+main'`) or through a heredoc fed to a shell (`bash <<EOF`).
force_re='(^|[[:space:]])(--force-with-lease(=[^[:space:]]*)?|--force|-f|\+[^[:space:]]+)([[:space:]]|$)'
force_push_found=0
while IFS= read -r segment; do
  if juscribe_sop_segment_invokes_git "$segment" push \
      && [[ "$segment" =~ $force_re ]]; then
    force_push_found=1
    break
  fi
done < <(juscribe_sop_command_segments "$(juscribe_sop_strip_heredocs "$command")")

# The SOP is "never force-push", and --force-with-lease is still a force-push
# (just a safer one).
if (( force_push_found )); then
  cat >&2 <<'EOF'
[jus:hard-rules] BLOCKED: `git push --force` (and variants, `+refspec` too) is forbidden.

The Juscribe SOP is unambiguous: NEVER force-push. Force-pushing rewrites
shared history and destroys other people's work. Even `--force-with-lease`
is forbidden — the stakeholder pushes manually.

If you genuinely need to undo a published commit, use `git revert` to add a
NEW commit that reverses it, and let the stakeholder handle the push.
EOF
  exit 2
fi

exit 0
