#!/usr/bin/env bash
# PostToolUse hook (Bash): track linter and commit completions.
#
# - On a successful linter command, write `last_linted_at` so the pre-commit
#   gate knows lints have run since the last edit.
# - On a successful `git commit`, clear edit tracking so the gate doesn't
#   re-fire on the next commit.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")
[[ "$tool_name" != "Bash" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")
interrupted=$(jq -r '.tool_response.interrupted // false' <<<"$input")
session_id=$(jq -r '.session_id // ""' <<<"$input")

# Claude Code's Bash tool_response carries no exit status — only stdout, stderr,
# interrupted, and isImage. We therefore cannot tell a passing lint from a
# failing one here (an earlier version read `.tool_response.exit_code`, which is
# always absent → defaulted to "failed" → last_linted_at was never written and
# the pre-commit gate's state-tracked rule was permanently dead; see #1873).
# Skip only a cancelled command; otherwise treat it as having run. A failed lint
# recording last_linted_at is harmless: lefthook re-runs the real linters at
# commit time and blocks a genuinely broken commit. This tracker only powers the
# "did you remember to lint" gate, not the quality enforcement itself.
[[ "$interrupted" == "true" ]] && exit 0

state_dir=$(juscribe_sop_state_dir "$session_id")

# Track ticket lifecycle for the start-comment nudge (jus-start-comment-nudge.sh).
# A `started` transition marks the active ticket and resets the comment/nudge
# flags; a comment POST to that same ticket records that the start comment
# exists. These are `jus api` calls — neither a git commit nor a lint — so they
# fall through the branches below.
started_id=$(juscribe_sop_started_ticket "$command")
if [[ -n "$started_id" ]]; then
  mkdir -p "$state_dir"
  printf '%s' "$started_id" > "${state_dir}/active_ticket"
  date +%s > "${state_dir}/started_at"
  rm -f "${state_dir}/start_comment_posted" "${state_dir}/start_nudged"
fi
commented_id=$(juscribe_sop_commented_ticket "$command")
if [[ -n "$commented_id" ]]; then
  active=$(cat "${state_dir}/active_ticket" 2>/dev/null || echo "")
  if [[ -n "$active" && "$commented_id" == "$active" ]]; then
    mkdir -p "$state_dir"
    date +%s > "${state_dir}/start_comment_posted"
  fi
fi

# Git commit → clear edit tracking, so the lint gate does not re-fire on the
# next commit.
#
# Unconditional, and that is the point of #2392. This branch used to VERIFY the
# commit against `git status` before clearing, because edits.log doubled as an
# ownership record and clearing it wrongly let one session claim another's
# in-flight files. Five tickets of partitioning, pruning and precedence-ordered
# markers went into getting that judgement right. The log is now only the lint
# gate's input, so there is nothing to be right about: a commit ends the current
# edit cycle, full stop.
if juscribe_sop_is_git_commit "$command"; then
  rm -f "${state_dir}/last_modified_at" \
        "${state_dir}/edits.log"
  exit 0
fi

# Linter command → mark linted
if juscribe_sop_is_lint_command "$command"; then
  mkdir -p "$state_dir"
  date +%s > "${state_dir}/last_linted_at"
fi

exit 0
