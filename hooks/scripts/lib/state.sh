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

# Echo the `git status --porcelain` lines for the dirty files in a worktree —
# ALL of them, one per line, so callers can display or count them.
#
# ⚠️ There is deliberately no per-session scoping here (#2392). This used to
# intersect the dirty set against a log of the files each session had edited, so
# two sessions sharing one checkout would not claim each other's work. That
# apparatus — an ownership log, three precedence-ordered markers, and a
# verification step on every commit — was removed: **worktrees are the isolation
# strategy**, and under a worktree "every dirty file in my tree is mine" is
# simply true, which is what the scoping spent five tickets approximating.
#
# The trade is real and accepted: in a SHARED checkout this again reports
# another session's files as yours. Use a worktree per work stream.
#
# Fails open (a git error becomes "nothing dirty"): every consumer is a guard or
# a nudge, and one that cannot read the tree should stay quiet rather than
# guess. -uall lists files inside untracked directories individually, and
# core.quotepath=false keeps non-ASCII paths literal.
#
# Argument: $1 = repo toplevel
juscribe_sop_dirty_lines() {
  local toplevel="$1"
  git -C "$toplevel" -c core.quotepath=false status --porcelain -uall 2>/dev/null || true
}

# Programs that count as "the shell linter ran".
#
# The bare TOOL names are the portable contract: a PUBLISHED bundle cannot know
# a project's wrapper name. The wrapper alternations cover the common naming
# shapes as a convenience — never the only way to clear the gate.
# juscribe_sop_command_invokes allows any directory prefix, so bin/lint-shell,
# ./bin/lint-shell and an absolute path all reduce to the same name.
#
# `<shell> -n` is a genuine syntax check, and it is what keeps this list honest
# for zsh and ksh — shellcheck refuses those outright (SC1071).
JUSCRIBE_SOP_SHELL_LINTERS='shellcheck|shfmt|(lint|check)[-_](shell|sh|bash|zsh)|(shell|sh|bash|zsh)[-_](lint|check)|(sh|bash|zsh|ksh|dash)[[:space:]]+-n'

# Remove heredoc BODIES from a command string before it is segmented.
#
# ⚠️ juscribe_sop_command_segments turns every NEWLINE into a separator, so each
# line of a heredoc body becomes a segment anchored at column 0 — segment
# anchoring alone does NOT stop prose from matching. Measured: a commit body
# line beginning "shellcheck and bin/lint-shell now record ..." otherwise reads
# as a shellcheck run and disarms the gate for the very commit shipping it. The
# SOP mandates writing prose through `<<'EOF'` heredocs, so this is the normal
# shape here, not an exotic one.
#
# Strips only when the terminator is actually FOUND, and only for a word-shaped
# delimiter not preceded by a third `<` (so `<<<` here-strings are untouched).
# An unterminated match was not a heredoc — restore the text rather than
# swallowing what might be a real invocation.
juscribe_sop_strip_heredocs() {
  local cmd="$1" line delim="" out="" body="" stripped
  local hd='(^|[^<])<<-?[[:space:]]*["'"'"']?([A-Za-z_][A-Za-z0-9_]*)'
  while IFS= read -r line; do
    if [[ -n "$delim" ]]; then
      body+="$line"$'\n'
      stripped="${line#"${line%%[![:space:]]*}"}"
      if [[ "$stripped" == "$delim" ]]; then
        delim=""
        body=""
      fi
      continue
    fi
    out+="$line"$'\n'
    if [[ "$line" =~ $hd ]]; then
      delim="${BASH_REMATCH[2]}"
    fi
  done <<<"$cmd"
  printf '%s%s' "$out" "$body"
}

# Does any simple-command segment of $1 invoke the program named by the ERE in
# $2? Anchored at segment start — the same shape as
# juscribe_sop_segment_invokes_git (#2363) — so prose that merely MENTIONS the
# tool cannot match, but tolerant of the shapes an invocation actually takes:
#
#   VAR=val prefix   SHELLCHECK_OPTS=-x bin/lint-shell f
#   directory prefix ./bin/lint-shell, /abs/bin/lint-shell, .jus/bin/lint-shell
#   a runner         xargs shellcheck, npx shellcheck, env shellcheck
#   find's -exec     find . -name '*.sh' -exec shellcheck {} +
#
# There is no recursive mode in shellcheck, so xargs/-exec IS its multi-file
# form. (Do not start this line with the tool's name — a comment beginning
# "# shellcheck " is parsed as a DIRECTIVE and fails the lint with SC1072.)
#
# `command`, `which` and `type` are deliberately NOT runners. A `command -v`
# probe is how an agent checks whether the tool is installed, and counting it
# would disarm the gate at exactly that moment.
juscribe_sop_command_invokes() {
  local cmd="$1" program="$2" seg
  local assigns='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
  local runner='((xargs|env|time|nice|sudo|npx|bunx)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?'
  local dir='([^[:space:]]*/)?'
  local head='^[[:space:]]*'"$assigns$runner$dir"'('"$program"')([[:space:]]|$)'
  local xexec='[[:space:]]-exec[[:space:]]+'"$dir"'('"$program"')([[:space:]]|$)'
  while IFS= read -r seg; do
    [[ -n "$seg" ]] || continue
    [[ "$seg" =~ $head ]] && return 0
    [[ "$seg" =~ $xexec ]] && return 0
  done < <(juscribe_sop_command_segments "$(juscribe_sop_strip_heredocs "$cmd")")
  return 1
}

# Is $1 a shell script, decided by its SHEBANG? $2 is the base directory a
# repo-relative path resolves against.
#
# Extension alone is not enough here. Measured in this repo: 18 files end in
# `.sh`, but 76 are shell scripts by shebang — the bin/* majority is
# extensionless, so an extension-only rule leaves most of the shell surface
# ungated (#2387).
juscribe_sop_is_shell_script() {
  local path="$1" base_dir="${2:-}" base first=""
  case "$path" in
    /*) ;;
    *)
      # A recorded path may be repo-relative: Codex's `*** Update File:` header
      # and Kimi's `path` key are both root-relative (#2352). With no base we
      # must NOT probe — `[[ -f ]]` on a bare relative path consults the HOOK
      # PROCESS's cwd, so an unrelated checkout's file would answer the
      # question, and here that answer can BLOCK a commit.
      [[ -n "$base_dir" ]] || return 1
      path="$base_dir/$path"
      ;;
  esac
  base="${path##*/}"
  # ⚠️ LOAD-BEARING: this guard, not the clause order in is_code_file, is what
  # keeps synthetic and nonexistent paths off the filesystem. An extension we do
  # not recognise is positive evidence of some other file type. `${base#.}` so
  # dotfiles (.envrc) still get probed.
  case "${base#.}" in
    *.*) return 1 ;;
  esac
  # -f, not -e: a FIFO or device would hang the read against the hook timeout.
  # -n 200 bounds it — an extensionless blob with no newline would otherwise be
  # slurped whole.
  [[ -f "$path" && -r "$path" ]] || return 1
  IFS= read -r -n 200 first < "$path" 2>/dev/null || true
  case "$first" in
    '#!'*bash* | '#!'*zsh* | '#!'*ksh* | '#!'*dash* | '#!'*/sh | '#!'*/sh[[:space:]]* | '#!'*'env sh' | '#!'*'env sh '*)
      return 0
      ;;
  esac
  return 1
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
  # Shell. Segment-anchored rather than the loose whitespace forms above,
  # because `brew install shellcheck` and `command -v shellcheck` are commands
  # an agent plausibly runs in the very session it is editing shell, and a false
  # positive here silently disarms the gate (#2387).
  if juscribe_sop_command_invokes "$cmd" "$JUSCRIBE_SOP_SHELL_LINTERS"; then
    return 0
  fi
  return 1
}

# Recognize a Bash command string as a `git commit` invocation.
juscribe_sop_is_git_commit() {
  local cmd="$1" seg
  # Match `git commit` but not `git commit-tree`, across chained and quoted
  # contexts.
  #
  # ⚠️ This required `git` IMMEDIATELY followed by `commit`, so `git -C . commit`
  # and `git -c core.editor=true commit` matched NOTHING — and the pre-commit
  # gate therefore never ran for them. A session could commit unlinted code just
  # by phrasing the commit with a global option, which agents emit routinely
  # when avoiding `cd` (#2363).
  #
  # juscribe_sop_segment_invokes_git already tolerates env-var prefixes and git
  # global options, so the fix is to reuse it rather than grow a second regex
  # that has to be kept in step with the first. `commit` as the subcommand still
  # excludes `commit-tree`: the pattern requires whitespace or end-of-string
  # after it, and `commit-tree` has a hyphen.
  while IFS= read -r seg; do
    [[ -n "$seg" ]] || continue
    juscribe_sop_segment_invokes_git "$seg" "commit" && return 0
  done < <(juscribe_sop_command_segments "$cmd")
  return 1
}

# Recognize a code file (one whose changes should require linting before commit).
#
# Extension first, because it answers for most files without touching the disk.
# Only an EXTENSIONLESS path falls through to the shebang probe — which is where
# the shell scripts are: `.sh` is the minority spelling (#2387).
#
# Argument $2 is optional and only used to resolve a repo-relative path; without
# it such a path is never probed. See juscribe_sop_is_shell_script.
juscribe_sop_is_code_file() {
  local path="$1" base_dir="${2:-}"
  if [[ "$path" =~ \.(rb|ts|tsx|js|jsx|mjs|cjs|css|scss|sass|py|go|rs|java|kt|swift|c|cc|cpp|h|hpp|sh|bash|zsh)$ ]]; then
    return 0
  fi
  juscribe_sop_is_shell_script "$path" "$base_dir"
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
