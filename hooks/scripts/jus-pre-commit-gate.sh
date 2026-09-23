#!/usr/bin/env bash
# PreToolUse hook (Bash): block a `git commit` that adds a lint suppression,
# or that follows code edits no linter has run on since.
#
# Tracks per-session state in $CLAUDE_PLUGIN_DATA. State files:
#   last_modified_at  — unix timestamp of most recent code edit
#   last_linted_at    — unix timestamp of most recent successful lint command
#   edits.log         — newline-separated list of edited file paths
#
# Logic:
#   1. If the command itself isn't `git commit`, allow.
#   2. If the commit would add a lint suppression, block.
#   3. If the command chain includes a linter call before the commit, allow.
#   4. If no edits were tracked this session, allow (committing pre-existing
#      changes is fine — pre-commit hooks downstream will still run).
#   5. If only non-code files were edited (docs, json, yml), allow.
#   6. If linters ran AFTER the most recent code edit, allow.
#   7. Otherwise, block with a message listing which lints to run.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
# shellcheck source=lib/lint_suppressions.sh
source "$(dirname "$0")/lib/lint_suppressions.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")
[[ "$tool_name" != "Bash" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")
session_id=$(jq -r '.session_id // ""' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")
juscribe_sop_require_jus_project "$cwd"

# (1) Only act on `git commit`
if ! juscribe_sop_is_git_commit "$command"; then
  exit 0
fi

repo=$(juscribe_sop_repo_toplevel "$cwd")

# (2) Refuse a newly added lint suppression, whatever wrote it. The Edit/Write
# guard never sees a change made through the shell; this fires on the commit.
#
# ⚠️ THE SCOPE IS A TRADE, CHOSEN KNOWINGLY. Nothing is staged yet when a
# `git add … && git commit` chain reaches this hook, so a staged-only scan
# would miss that chain entirely. So a command that stages is scanned against
# the whole working tree, and may be refused over a suppression in a file it
# was not committing. Every other commit is scanned on exactly what is staged.
#
# Runs ahead of every early allow below: a linter in the chain, or a session
# with no tracked edits, says nothing about what the diff adds. No repository
# resolved from cwd means nothing to scan, and the hook fails open.
if [[ -n "$repo" ]]; then
  scope=staged
  juscribe_sop_command_stages "$command" && scope=worktree
  findings=$(cd "$repo" && jus_lint_suppression_scan "$scope") || true
  if [[ -n "$findings" ]]; then
    if [[ "$scope" == worktree ]]; then
      findings+=$'\n\n'"This command stages files before committing, so changes not yet staged"
      findings+=$'\n'"and untracked files were scanned too."
    fi
    jus_lint_suppression_explain "$findings" >&2
    exit 2
  fi
fi

# (3) Allow if the command chain itself runs a linter
if juscribe_sop_is_lint_command "$command"; then
  exit 0
fi

state_dir=$(juscribe_sop_state_dir "$session_id")

# (4) No edits tracked → nothing to gate
[[ ! -f "${state_dir}/last_modified_at" ]] && exit 0

# (5) Only doc/config files edited → no lint requirement
if [[ -f "${state_dir}/edits.log" ]]; then
  # Scope the scan to the repo being committed to. #2388 keeps out-of-repo
  # entries — scratchpad scripts, auto-memory — in the log for the session's
  # whole life by design, and they are not part of THIS commit, so demanding
  # lints for them would raise a gate no lint in this repo can lower. Only when
  # a toplevel resolves: with no cwd (the shape the harness sometimes sends) the
  # scan stays unscoped, exactly as before.
  base_dir=${repo:-$cwd}
  code_edited=0
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ -n "$base_dir" ]]; then
      case "$path" in
        /*) [[ "$path" == "$base_dir"/* ]] || continue ;;
      esac
    fi
    if juscribe_sop_is_code_file "$path" "$base_dir"; then
      code_edited=1
      break
    fi
  done < "${state_dir}/edits.log"
  if [[ "$code_edited" == "0" ]]; then
    exit 0
  fi
fi

# (6) Lints ran after the last edit → allow
modified_at=$(juscribe_sop_read_num "${state_dir}/last_modified_at")
linted_at=$(juscribe_sop_read_num "${state_dir}/last_linted_at")
if (( linted_at >= modified_at )); then
  exit 0
fi

# (7) Block
cat >&2 <<'EOF'
[jus:hard-rules] BLOCKED: linters have not been run since the last code edit.

The Juscribe SOP requires running linters BEFORE every commit. Run the
applicable linters scoped to the files you changed, then retry the commit.

  Ruby files (.rb):
    bin/rubocop <files>
    bin/reek <files>
    bin/rspec                 # full backend suite

  Frontend files (.ts/.tsx/.css):
    pnpm exec eslint <files>
    pnpm exec prettier --check <files>
    pnpm exec tsc --noEmit    # always project-wide
    pnpm test                 # full vitest suite

  Mobile files (mobile/):
    cd mobile && pnpm test

  Go files (station/):
    bin/ci --station

  Shell scripts (.sh, or extensionless with a shell shebang):
    shellcheck <files>        # or the project's wrapper, e.g. bin/lint-shell

If you've already linted but the gate is firing, the hook didn't see the lint
exit code. Re-run the lint command in its own Bash call (not chained), then
retry the commit.
EOF
exit 2
