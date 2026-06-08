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
