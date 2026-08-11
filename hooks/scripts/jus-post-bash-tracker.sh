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
cwd=$(jq -r '.cwd // ""' <<<"$input")

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

# Git commit → maybe clear edit tracking. The tool_response carries no exit
# status (#1873), so "the commit succeeded" is verified against git itself:
# resolved means no tracked file is still dirty. Three outcomes (#2355):
#
#   resolved      → clear the log and leave the edits_cleared_at sentinel, so
#                   a missing log reads as "a commit resolved this session's
#                   edits", not "never tracked" — without it the #2216 scoping
#                   falls back to claiming every dirty file until the next
#                   edit, and the Stop gate instructs the session to commit
#                   other sessions' work.
#   unresolved    → the commit failed or was partial (or cwd is unverifiable):
#                   KEEP the log, so precise scoping keeps covering this
#                   session's own files. A sentinel here would let the session
#                   end its turn with its own work uncommitted.
#   never tracked → clear as before and write NO sentinel: a Bash-writing
#                   session's files are covered only by the block-everything
#                   fallback, which must survive its commits.
if juscribe_sop_is_git_commit "$command"; then
  if [[ -s "${state_dir}/edits.log" ]]; then
    toplevel=$(juscribe_sop_repo_toplevel "$cwd")
    [[ -z "$toplevel" ]] && exit 0
    # session_dirty_lines fails OPEN on a git-status error — right for its
    # advisory consumers, but here emptiness is a POSITIVE trust signal, so a
    # status failure must not read as "everything resolved".
    git -C "$toplevel" status --porcelain >/dev/null 2>&1 || exit 0
    # An absolute log entry outside this toplevel cannot have been resolved by
    # a commit verified HERE — e.g. `cd /other && git commit` runs with the
    # session's persistent cwd still pointing at this repo, and the foreign
    # entries would vacuously never intersect. Keep the log.
    while IFS= read -r logged; do
      case "$logged" in
        /*) [[ "$logged" == "$toplevel"/* ]] || exit 0 ;;
      esac
    done < "${state_dir}/edits.log"
    [[ -n "$(juscribe_sop_session_dirty_lines "$toplevel" "$session_id")" ]] && exit 0
    # The _anonymous state dir is shared by every session without an id; a
    # sentinel there would assert "owns nothing" on behalf of all of them,
    # permanently. No id → clear tracking without a sentinel (pre-#2355
    # semantics: the block-everything fallback stays).
    if [[ -n "$session_id" ]]; then
      date +%s > "${state_dir}/edits_cleared_at"
    fi
  fi
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
