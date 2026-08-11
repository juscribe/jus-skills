#!/usr/bin/env bash
# Shared helpers for hooks. Sourced — not executed directly.

set -euo pipefail

# Fail-open if `jq` is missing on the host. We never want a missing dependency
# to break the user's session — better to skip enforcement than to wedge the
# tool call. The README lists `jq` as a prerequisite.
juscribe_sop_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    exit 0
  fi
}

# Fail open if stdin is not valid JSON. Same philosophy as require_jq: a hook
# must never break a tool call because the harness handed it unexpected input —
# a parse error becomes a silent no-op (exit 0) rather than a non-zero exit
# (jq exits 5 on malformed JSON, which under `set -euo pipefail` would otherwise
# abort the hook). Call immediately after reading stdin.
# Argument: $1 = the raw stdin string.
juscribe_sop_require_valid_json() {
  jq . >/dev/null 2>&1 <<<"${1:-}" || exit 0
}

# Resolve the per-session state directory.
# Argument: $1 = session_id (may be empty)
# Echoes the directory path. Caller decides whether to mkdir.
juscribe_sop_state_dir() {
  local session_id="${1:-}"
  local base="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/jus}"
  if [[ -z "$session_id" ]]; then
    echo "$base/sessions/_anonymous"
  else
    echo "$base/sessions/$session_id"
  fi
}

# Read a numeric counter file (returns 0 if missing).
juscribe_sop_read_num() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Echo the git repository toplevel for a working directory, or nothing when it
# is not a git worktree (or git is unavailable). Callers resolve the toplevel
# rather than using the cwd directly so porcelain paths are always
# root-relative, whatever subdirectory the tool call happened in.
juscribe_sop_repo_toplevel() {
  local cwd="${1:-}"
  [[ -z "$cwd" ]] && return 0
  command -v git >/dev/null 2>&1 || return 0
  git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true
}

# Echo the `git status --porcelain` lines for the dirty files THIS session
# edited — one line per file, so callers can either display them or count them.
#
# #2216: with two agent sessions sharing a checkout, the dirty set includes the
# other session's in-flight edits, and acting on those under this ticket is the
# failure the scoping prevents. jus-track-edits records every Edit/Write/
# MultiEdit path (absolute) in edits.log; keep only the dirty files listed there.
#
# Fallback: when the log is missing or empty, echo every dirty line. A file
# written via Bash (sed, a generator, a heredoc) never passes through
# jus-track-edits, so without this the caller would silently stop covering it.
#
# #2355: a missing log is ambiguous — jus-post-bash-tracker deletes it on a
# successful `git commit`, and for the window until the next tracked edit the
# fallback would claim every dirty line, i.e. other sessions' files. The
# tracker therefore leaves an `edits_cleared_at` sentinel when a commit
# resolves tracked edits: log missing + sentinel present means this session
# owns nothing. No sentinel keeps the never-tracked fallback above intact.
#
# Shared by jus-stop-uncommitted.sh and jus-dirty-tree-nudge.sh (#2352). It
# lives here rather than in either of them because the two subtleties below —
# the rename form and quotepath — were each paid for once already, and a second
# copy is where the next fix fails to land.
#
# Arguments: $1 = repo toplevel, $2 = session_id
juscribe_sop_session_dirty_lines() {
  local toplevel="$1" session_id="${2:-}"
  local state_dir dirty edits_log owned="" line path

  # core.quotepath=false keeps non-ASCII paths literal so they match the
  # absolute paths jus-track-edits records. -uall lists files INSIDE untracked
  # directories individually — default porcelain collapses them to one
  # "?? newdir/" line, which can never match a logged file inside it, so the
  # intersection silently skipped such files and the #2355 resolution check
  # read them as already committed (#2355).
  dirty=$(git -C "$toplevel" -c core.quotepath=false status --porcelain -uall 2>/dev/null || echo "")
  [[ -z "$dirty" ]] && return 0

  state_dir=$(juscribe_sop_state_dir "$session_id")
  edits_log="$state_dir/edits.log"
  if [[ ! -s "$edits_log" ]]; then
    [[ -f "$state_dir/edits_cleared_at" ]] && return 0
    printf '%s\n' "$dirty"
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Porcelain v1: two status chars + a space, then the path. For a
    # rename/copy ("R  old -> new") the on-disk path is after " -> ".
    path="${line:3}"
    path="${path##* -> }"
    # Both forms, because the recorded path is whatever the harness reported.
    # Claude Code sends an absolute file_path; Codex's `*** Update File:` header
    # is REPO-RELATIVE, so jus-codex-adapt normalizes a relative path into
    # edits.log. Matching only the absolute form left the intersection
    # permanently empty on Codex — the scoping silently stopped covering
    # anything, while still exiting 0 (#2352).
    if grep -qxF "$toplevel/$path" "$edits_log" || grep -qxF "$path" "$edits_log"; then
      owned+="$line"$'\n'
    fi
  done <<<"$dirty"

  printf '%s' "$owned"
}

# Recognize a Bash command string as a linter or test invocation.
# Returns 0 if matched, 1 otherwise.
juscribe_sop_is_lint_command() {
  local cmd="$1"
  # Ruby
  if [[ "$cmd" =~ (^|[[:space:]]|\&\&[[:space:]]*)bin/(rubocop|reek|rspec)([[:space:]]|$) ]]; then
    return 0
  fi
  if [[ "$cmd" =~ (^|[[:space:]]|\&\&[[:space:]]*)bundle[[:space:]]+exec[[:space:]]+(rubocop|reek|rspec) ]]; then
    return 0
  fi
  # Frontend
  if [[ "$cmd" =~ pnpm[[:space:]]+(exec[[:space:]]+)?(eslint|prettier|tsc|vitest|jest) ]]; then
    return 0
  fi
  if [[ "$cmd" =~ (^|[[:space:]]|\&\&[[:space:]]*)pnpm[[:space:]]+test([[:space:]]|$) ]]; then
    return 0
  fi
  # Go
  if [[ "$cmd" =~ golangci-lint[[:space:]]+run ]]; then
    return 0
  fi
  if [[ "$cmd" =~ (^|[[:space:]]|\&\&[[:space:]]*)go[[:space:]]+test([[:space:]]|$) ]]; then
    return 0
  fi
  # Project CI wrapper
  if [[ "$cmd" =~ (^|[[:space:]]|\&\&[[:space:]]*)bin/ci([[:space:]]|$) ]]; then
    return 0
  fi
  return 1
}

# Recognize a Bash command string as a `git commit` invocation.
juscribe_sop_is_git_commit() {
  local cmd="$1"
  # Match `git commit` but not `git commit-tree`. Allow chained (&&) and
  # quoted contexts.
  [[ "$cmd" =~ (^|[[:space:]]|\&\&[[:space:]]*|\;[[:space:]]*)git[[:space:]]+commit([[:space:]]|$) ]]
}

# Recognize a code file (one whose changes should require linting before commit).
juscribe_sop_is_code_file() {
  local path="$1"
  [[ "$path" =~ \.(rb|ts|tsx|js|jsx|mjs|cjs|css|scss|sass|py|go|rs|java|kt|swift|c|cc|cpp|h|hpp)$ ]]
}

# If the command is a `jus api` ticket transition to `started`, echo the ticket
# id (used by jus-start-comment-nudge.sh to know a ticket is in progress).
# Always echoes (empty when no match) and returns 0 so callers under `set -e`
# are safe.
juscribe_sop_started_ticket() {
  local cmd="$1"
  if [[ "$cmd" =~ tickets/([0-9]+)/transition ]]; then
    local id="${BASH_REMATCH[1]}"
    if [[ "$cmd" =~ \"state\"[[:space:]]*:[[:space:]]*\"started\" ]]; then
      printf '%s' "$id"
    fi
  fi
  return 0
}

# Split a Bash command string into simple-command segments, one per output
# line. Newlines become separators, quoted regions are removed, and the
# remainder splits on ;, |, &, parens/braces, and backticks. A quoted string
# can only ever be an ARGUMENT of a command — never the command being invoked —
# so dropping quoted regions means prose or JSON that merely mentions a
# forbidden invocation can't produce a matching segment (#1985). Known
# limitation: an unmatched apostrophe in unquoted prose can mis-pair with a
# later quote and hide a real invocation — these hooks are a guardrail, not a
# sandbox.
juscribe_sop_command_segments() {
  local cmd="$1"
  tr '\n' ';' <<<"$cmd" \
    | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g" \
    | tr ';|&(){}`' '\n'
}

# Does a segment invoke git — optionally a specific subcommand ($2, a word or
# ERE)? Tolerates leading whitespace, VAR=val env prefixes, and git global
# options between `git` and the subcommand (-C <path>, -c <k>=<v>, --long[=v]).
juscribe_sop_segment_invokes_git() {
  local seg="$1" sub="${2:-[A-Za-z-]+}"
  local assigns='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
  local gitopts='([[:space:]]+(-[Cc][[:space:]]*[^[:space:]]+|--[A-Za-z][A-Za-z-]*(=[^[:space:]]*)?))*'
  local re='^[[:space:]]*'"$assigns"'git'"$gitopts"'[[:space:]]+'"$sub"'([[:space:]]|$)'
  [[ "$seg" =~ $re ]]
}

# If the command POSTs a comment to a ticket, echo that ticket id. Matches
# `tickets/<id>/comments` only when `comments` is NOT followed by `/` — so a
# comment-reaction toggle (`.../comments/<cid>/reactions/...`) does NOT count as
# posting a start comment. Requires a POST so a GET listing never trips it.
juscribe_sop_commented_ticket() {
  local cmd="$1"
  [[ "$cmd" =~ (^|[[:space:]])POST([[:space:]]) ]] || return 0
  if [[ "$cmd" =~ tickets/([0-9]+)/comments([^/]|$) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
  return 0
}
