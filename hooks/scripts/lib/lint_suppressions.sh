#!/usr/bin/env bash
# The lint / type-check suppression table — ONE array, several readers.
# Sourced, not executed directly.
#
# The Juscribe SOP forbids inline suppression of linters and type-checkers.
# Two guards enforce it and they must never disagree about what a suppression
# is, so the table lives here rather than inside either one:
#
#   jus/hooks/scripts/jus-block-lint-suppression.sh   PreToolUse — stops the
#       line before it exists and explains why at the moment of writing.
#   the project's own commit-time guard — reads the staged diff, and so cannot
#       be routed around by a heredoc, `sed`, python, or a tool nobody has
#       thought of yet.
#
# ⚠️ THE SECOND EXISTS BECAUSE THE FIRST IS MATCHED ON `Edit|Write|MultiEdit`
# (#4347). In bypass-permissions mode the harness instructs the agent to edit
# with `sed`, heredocs and scripts — none of which is a tool event — so the
# PreToolUse guard fired zero times across a long session on 2026-09-16 while
# eight of the nine types it covers had no other check anywhere.

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
# ⚠️ `printf -v` RATHER THAN A PRINTED RESULT, because the census resolves a
# type for every tracked file in the repository and `$(...)` there is one fork
# per file — thousands of them, on a pre-commit path that has to stay inside a
# second or two. Measured: the printing form took about four times as long.
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

# The block text both guards print. Kept here so the two cannot drift into
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
