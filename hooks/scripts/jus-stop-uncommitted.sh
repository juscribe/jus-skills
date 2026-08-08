#!/usr/bin/env bash
# Stop hook: prevent Claude from ending its turn when the working tree is
# dirty.
#
# The Juscribe SOP says "Treat an uncommitted change with the same urgency
# as an unsaved file." Stopping with uncommitted changes hides work from the
# stakeholder and risks losing it.
#
# Behaviour:
#   - If `stop_hook_active=true`, exit 0 (avoid infinite loops — Claude has
#     already been told to commit at least once this turn).
#   - If the cwd isn't a git repo, exit 0 (nothing to check).
#   - If the working tree is clean, exit 0.
#   - Otherwise, exit 2 with stderr listing the dirty files and instructions.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
cwd=$(jq -r '.cwd // ""' <<<"$input")
session_id=$(jq -r '.session_id // ""' <<<"$input")
stop_hook_active=$(jq -r '.stop_hook_active // false' <<<"$input")

# Already nudged once this turn — let Claude stop to avoid an infinite loop.
if [[ "$stop_hook_active" == "true" ]]; then
  exit 0
fi

[[ -z "$cwd" ]] && exit 0
command -v git >/dev/null 2>&1 || exit 0

if ! ( cd "$cwd" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 ); then
  exit 0
fi

# Resolve the repo root so porcelain paths are always root-relative, and run
# status from there rather than from an arbitrary cwd subdirectory.
toplevel=""
if pushd "$cwd" >/dev/null 2>&1; then
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  popd >/dev/null
fi
[[ -z "$toplevel" ]] && exit 0

# core.quotepath=false keeps non-ASCII paths literal so they match the
# absolute paths jus-track-edits records.
dirty=$(git -C "$toplevel" -c core.quotepath=false status --porcelain 2>/dev/null || echo "")
if [[ -z "$dirty" ]]; then
  exit 0
fi

# #2216: scope the block to files THIS session actually touched. With two
# agent sessions sharing one working tree, the dirty set includes the other
# session's in-flight edits — committing those under this ticket's `[#N]` is
# the failure this guard would otherwise cause. jus-track-edits records every
# Edit/Write/MultiEdit path (absolute) in edits.log; block only on the dirty
# files that appear there.
#
# Fallback: if the log is missing or empty, block on any dirty file exactly as
# before — a file written via Bash (sed, a generator, a heredoc) never passes
# through jus-track-edits, so without this fallback the guard would silently
# stop covering that work.
edits_log="$(juscribe_sop_state_dir "$session_id")/edits.log"
blocking="$dirty"
if [[ -s "$edits_log" ]]; then
  owned=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Porcelain v1: two status chars + a space, then the path. For a
    # rename/copy ("R  old -> new") the on-disk path is after " -> ".
    path="${line:3}"
    path="${path##* -> }"
    if grep -qxF "$toplevel/$path" "$edits_log"; then
      owned+="$line"$'\n'
    fi
  done <<<"$dirty"
  blocking="${owned%$'\n'}"
fi

if [[ -z "$blocking" ]]; then
  exit 0
fi

files=$(head -20 <<<"$blocking")

# Cap the file list so we don't flood the message
overflow=""
total=$( wc -l <<<"$blocking" | tr -d ' ' )
if (( total > 20 )); then
  overflow=$'\n... and '"$((total - 20))"' more'
fi

cat >&2 <<EOF
[jus:hard-rules] STOP BLOCKED: working tree is dirty.

The Juscribe SOP forbids ending a session or turn with uncommitted changes:
"Treat an uncommitted change with the same urgency as an unsaved file."

Files with pending changes:
${files}${overflow}

Required next action:
  1. Run the applicable linters on the modified files.
  2. Commit with a "[#N] Short description" message referencing the ticket.
  3. Then stop.

If the changes are intentional WIP that genuinely shouldn't be committed,
discuss with the stakeholder before stopping — don't silently abandon them.
EOF
exit 2
