#!/usr/bin/env bash
# PreToolUse hook (Bash): block `git commit` if linters haven't been run on
# the code edited since the last commit.
#
# Tracks per-session state in $CLAUDE_PLUGIN_DATA. State files:
#   last_modified_at  — unix timestamp of most recent code edit
#   last_linted_at    — unix timestamp of most recent successful lint command
#   edits.log         — newline-separated list of edited file paths
#
# Logic:
#   1. If the command itself isn't `git commit`, allow.
#   2. If the command chain includes a linter call before the commit, allow.
#   3. If no edits were tracked this session, allow (committing pre-existing
#      changes is fine — pre-commit hooks downstream will still run).
#   4. If only non-code files were edited (docs, json, yml), allow.
#   5. If linters ran AFTER the most recent code edit, allow.
#   6. Otherwise, block with a message listing which lints to run.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")
[[ "$tool_name" != "Bash" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")
session_id=$(jq -r '.session_id // ""' <<<"$input")

# (1) Only act on `git commit`
if ! juscribe_sop_is_git_commit "$command"; then
  exit 0
fi

# (2) Allow if the command chain itself runs a linter
if juscribe_sop_is_lint_command "$command"; then
  exit 0
fi

state_dir=$(juscribe_sop_state_dir "$session_id")

# (3) No edits tracked → nothing to gate
[[ ! -f "${state_dir}/last_modified_at" ]] && exit 0

# (4) Only doc/config files edited → no lint requirement
if [[ -f "${state_dir}/edits.log" ]]; then
  code_edited=0
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if juscribe_sop_is_code_file "$path"; then
      code_edited=1
      break
    fi
  done < "${state_dir}/edits.log"
  if [[ "$code_edited" == "0" ]]; then
    exit 0
  fi
fi

# (5) Lints ran after the last edit → allow
modified_at=$(juscribe_sop_read_num "${state_dir}/last_modified_at")
linted_at=$(juscribe_sop_read_num "${state_dir}/last_linted_at")
if (( linted_at >= modified_at )); then
  exit 0
fi

# (6) Block
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

If you've already linted but the gate is firing, the hook didn't see the lint
exit code. Re-run the lint command in its own Bash call (not chained), then
retry the commit.
EOF
exit 2
