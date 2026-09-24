#!/usr/bin/env bash
# The lint / type-check suppression table — ONE array, several readers.
# Sourced, not executed directly.
#
# The Juscribe SOP forbids inline suppression of linters and type-checkers.
# Several guards enforce it and they must never disagree about what a
# suppression is, so the table lives here rather than inside any one of them:
#
#   jus/hooks/scripts/jus-block-lint-suppression.sh   PreToolUse on file edits —
#       stops the line before it exists and explains why at the moment of
#       writing.
#   jus/hooks/scripts/jus-pre-commit-gate.sh          PreToolUse on `git commit`
#       — runs the diff scan below, so a heredoc, `sed` or a script ends at the
#       same place.
#   a project's own git pre-commit job, where it has one — the same scan over
#       the staged diff, for commits no agent hook sees.
#
# ⚠️ THE EDIT GUARD ALONE IS NOT ENOUGH. It is matched on
# `Edit|Write|MultiEdit`, and auto and bypass-permissions modes tell the agent
# to edit through the shell, which is no tool event at all.

# Each row: regex | human-readable label | the file types whose linter actually
# reads the directive.
#
# ⚠️ THE TYPE COLUMN IS NOT DECORATION (#1985). Outside the types whose linter
# reads it, the token is inert text — documentation quoting a rule, a shell
# test fixture, a pattern in a string — and blocking there makes the guard
# unusable rather than strict.
#
# ⚠️ NO PIPE CHARACTER IN ANY FIELD: the row is split on it.
JUS_LINT_SUPPRESSION_PATTERNS=(
  '#[[:space:]]*rubocop:disable|rubocop:disable|rb rake gemspec ru Gemfile Rakefile'
  '#[[:space:]]*rubocop:todo|rubocop:todo|rb rake gemspec ru Gemfile Rakefile'
  ':reek:[A-Za-z]|:reek: comment|rb rake gemspec ru Gemfile Rakefile'
  '//[[:space:]]*eslint-disable|eslint-disable|ts tsx js jsx mjs cjs'
  '/\*[[:space:]]*eslint-disable|eslint-disable (block)|ts tsx js jsx mjs cjs'
  '//[[:space:]]*prettier-ignore|prettier-ignore|ts tsx js jsx mjs cjs'
  '/\*[[:space:]]*prettier-ignore|prettier-ignore (block)|ts tsx js jsx mjs cjs css scss'
  '//[[:space:]]*@ts-ignore|@ts-ignore|ts tsx js jsx'
  '//[[:space:]]*@ts-expect-error|@ts-expect-error|ts tsx js jsx'
  '//[[:space:]]*@ts-nocheck|@ts-nocheck|ts tsx js jsx'
  '#[[:space:]]*type:[[:space:]]*ignore|type: ignore (mypy)|py'
  '#[[:space:]]*pyright:[[:space:]]*ignore|pyright: ignore|py'
  '//[[:space:]]*nolint|nolint (Go)|go'
  '#nosec|#nosec (gosec)|go'
  '#[[:space:]]*shellcheck[[:space:]]+disable|shellcheck disable|sh bash zsh'
)

# Every row, one per line — and the ONLY reader of the array above, so a
# consumer iterates rows instead of reaching into a global. That is also what
# keeps the array honestly used: a sourced library whose data nothing in it
# touches is an unused variable to shellcheck, and this project does not
# silence a linter to make a point.
jus_lint_suppression_rows() {
  printf '%s\n' "${JUS_LINT_SUPPRESSION_PATTERNS[@]}"
}

# The three fields of one row. Split in one place, so no reader can get the
# order wrong in its own copy.
jus_lint_suppression_regex() {
  printf '%s' "${1%%|*}"
}

jus_lint_suppression_label() {
  local rest=${1#*|}
  printf '%s' "${rest%%|*}"
}

jus_lint_suppression_types() {
  local rest=${1#*|}
  printf '%s' "${rest#*|}"
}

# Resolve the type token a path is keyed by INTO the variable named by $1.
#   $1  the name of the variable to set
#   $2  the path
#   $3  its first line, when the caller has one (optional)
#
# ⚠️ `printf -v` RATHER THAN A PRINTED RESULT, because a scan resolves a type
# for every path it reads and `$(...)` there is one fork per path, on a
# pre-commit path that has to stay inside a second or two. Measured over every
# tracked file in a repository: the printing form took about four times as long.
#
# ⚠️ A SHELL SHEBANG WINS OVER THE EXTENSION, and that clause is the whole
# reason `shellcheck disable` can be in the table at all (#4347). Most shell
# scripts in a repository like this one are extensionless — `bin/ci`,
# `script/dev/gate`, `.jus/bin/jus` — so they type as `ci`, `gate` and `jus`,
# and a `sh bash` column would reach almost none of the corpus. The shellcheck
# lefthook lane settled the same question the same way years earlier: it
# matches by shebang rather than by extension.
#
# Without a shebang the extension decides, falling back to the BASENAME for an
# extensionless file — which is how `Gemfile` and `Rakefile` are matched.
jus_lint_suppression_type_into() {
  local base first=${3:-}

  if [[ $first == '#!'* && $first =~ (bash|zsh|/sh|[[:space:]]sh)([[:space:]]|$) ]]; then
    printf -v "$1" '%s' sh
    return
  fi

  base=${2##*/}
  printf -v "$1" '%s' "${base##*.}"
}

# Does this row's linter read that file type?
#   $1  the row's type column
#   $2  the file type
#
# An EMPTY type is fail-closed: when the target is unknown, every row stays
# active rather than silently letting all of them through.
jus_lint_suppression_applies() {
  [[ -z $2 ]] && return 0
  [[ " $1 " == *" $2 "* ]]
}

# The block text every guard prints. Kept here so they cannot drift into
# explaining the same rule differently.
#   $1  the findings, already formatted — one per line
jus_lint_suppression_explain() {
  cat <<EXPLANATION
[jus:hard-rules] BLOCKED: lint/type suppression added.

$1

The Juscribe SOP forbids inline suppression of linters and type-checkers.
Fix the underlying issue instead:

  - Refactor to remove the smell (smaller methods, better names, etc.).
  - For TypeScript: type the value correctly instead of @ts-ignore /
    @ts-expect-error / @ts-nocheck.
  - For genuine false positives: escalate to the stakeholder before
    silencing — never silence silently.

If a suppression is structurally accepted (e.g. an established pattern in
the codebase), discuss with the stakeholder before introducing more.
EXPLANATION
}

# ── THE DIFF SCAN ────────────────────────────────────────────────────────────

# The rows with their three fields split ONCE, into the JUS_LINT_ROW_* arrays.
# The scan tests every added line against every applicable row, so splitting
# inside that loop would be a fork per row per line.
jus_lint_suppression_load_rows() {
  JUS_LINT_ROW_REGEX=()
  JUS_LINT_ROW_LABEL=()
  JUS_LINT_ROW_TYPES=()
  local row
  while IFS= read -r row; do
    JUS_LINT_ROW_REGEX+=("$(jus_lint_suppression_regex "$row")")
    JUS_LINT_ROW_LABEL+=("$(jus_lint_suppression_label "$row")")
    JUS_LINT_ROW_TYPES+=("$(jus_lint_suppression_types "$row")")
  done < <(jus_lint_suppression_rows)
  JUS_LINT_ROW_COUNT=${#JUS_LINT_ROW_REGEX[@]}
}

# Is this path in JUS_LINT_SUPPRESSION_EXEMPT_PATHS? A caller that sets no such
# array exempts nothing. The `+` expansion keeps an unset array legal under
# `set -u` on bash 3.2, which macOS ships.
jus_lint_suppression_exempt() {
  local candidate
  for candidate in ${JUS_LINT_SUPPRESSION_EXEMPT_PATHS[@]+"${JUS_LINT_SUPPRESSION_EXEMPT_PATHS[@]}"}; do
    [[ $1 == "$candidate" ]] && return 0
  done
  return 1
}

# Every row whose linter reads this file type, tested against one added line.
#   $1 path  $2 line number  $3 the line  $4 the file type
#
# A bash regex match rather than a `grep` per row: this runs per added line on
# every commit, and a fork there is the difference between instant and noticed.
jus_lint_suppression_check_line() {
  local index=0
  while ((index < JUS_LINT_ROW_COUNT)); do
    if jus_lint_suppression_applies "${JUS_LINT_ROW_TYPES[index]}" "$4" &&
      [[ $3 =~ ${JUS_LINT_ROW_REGEX[index]} ]]; then
      printf '  %s:%s  %s\n' "$1" "$2" "${JUS_LINT_ROW_LABEL[index]}"
    fi
    index=$((index + 1))
  done
}

# The added lines of a `-U0` diff on stdin, as `<line number><TAB><content>`.
# The hunk header carries the new-side start line, which is the only way to
# report a number the reader can go to. `${header#*+}` lands on `+c,d` because
# the `-a,b` before it has no plus. A `+++` file header precedes the first
# hunk, so nothing before a hunk counts as an addition.
jus_lint_suppression_added_lines() {
  local lineno=0 line new in_hunk=0
  while IFS= read -r line; do
    case $line in
      '@@'*)
        new=${line#*+}
        new=${new%% *}
        lineno=${new%%,*}
        in_hunk=1
        ;;
      '+'*)
        ((in_hunk)) || continue
        printf '%s\t%s\n' "$lineno" "${line#+}"
        lineno=$((lineno + 1))
        ;;
    esac
  done
}

# Scan the NUL-separated paths on stdin, each diffed against one source:
#   staged     the index against HEAD — what a commit takes
#   untracked  the whole file, which has no earlier version
#   <tree>     the working tree against that tree
#
# The first line feeds the shebang clause of the type rule, so it is read from
# what the scan is looking at: the staged blob, or the file on disk.
jus_lint_suppression_scan_paths() {
  local from=$1 path first file_type lineno content
  while IFS= read -r -d '' path; do
    jus_lint_suppression_exempt "$path" && continue

    first=""
    if [[ $from == staged ]]; then
      first=$(git show ":$path" 2>/dev/null | head -n 1) || true
    else
      IFS= read -r first <"$path" 2>/dev/null || true
    fi
    jus_lint_suppression_type_into file_type "$path" "$first"

    while IFS=$'\t' read -r lineno content; do
      jus_lint_suppression_check_line "$path" "$lineno" "$content" "$file_type"
    done < <(jus_lint_suppression_diff "$from" "$path" | jus_lint_suppression_added_lines)
  done
}

# `--no-ext-diff` because a configured external diff driver would replace the
# unified format this parser reads.
jus_lint_suppression_diff() { # <source> <path>
  case $1 in
    staged) git diff --cached -U0 --no-color --no-ext-diff -- "$2" ;;
    untracked) git diff --no-index -U0 --no-color --no-ext-diff -- /dev/null "$2" || true ;;
    *) git diff "$1" -U0 --no-color --no-ext-diff -- "$2" ;;
  esac
}

# One finding per ADDED suppression in the repository at the current directory,
# as `  <path>:<line>  <label>`. Prints nothing when clean, and always returns 0
# so a caller under `set -e` decides on the output alone.
#   $1  staged     what the index holds against HEAD
#       worktree   the working tree against HEAD, plus untracked files — what a
#                  command that stages before it commits can take
#
# ACMR on the path lists: a deletion has no added lines. `-z` so a path git
# would otherwise quote is passed back to it verbatim.
jus_lint_suppression_scan() {
  local base
  [[ -n ${JUS_LINT_ROW_COUNT:-} ]] || jus_lint_suppression_load_rows

  if [[ $1 == staged ]]; then
    git diff --cached --name-only -z --diff-filter=ACMR | jus_lint_suppression_scan_paths staged || true
    return 0
  fi

  # A repository with no commit yet diffs against the empty tree.
  base=$(git rev-parse -q --verify HEAD) || base=$(git hash-object -t tree /dev/null)
  git diff "$base" --name-only -z --diff-filter=ACMR | jus_lint_suppression_scan_paths "$base" || true
  git ls-files -z --others --exclude-standard | jus_lint_suppression_scan_paths untracked || true
  return 0
}
