#!/usr/bin/env bash
# PreToolUse hook (Bash): block any command that skips the git hooks.
#
# The Juscribe SOP forbids skipping hooks — if a hook fails, fix the underlying
# issue rather than bypassing the check.
#
# ⚠️ A BYPASS IS A CLASS, NOT A STRING (#4446). This matched `--no-verify` and
# nothing else, and every hook runner in common use also ships an environment
# variable that skips the same checks. Measured on dispatch 680 (#4283): an
# agent with no ruby in its sandbox reached for
# `LEFTHOOK_EXCLUDE=rubocop,reek git commit` and this hook said nothing. The
# commit was refused by `jus-pre-commit-gate.sh` instead — on "linters have not
# been run since the last code edit", which is a different property that
# happened to be unhappy. A session that had run the linters, edited nothing and
# then bypassed would have had both hooks green.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

input=$(cat)
juscribe_sop_require_valid_json "$input"
juscribe_sop_require_jus_project "$(jq -r '.cwd // ""' <<<"$input")"
tool_name=$(jq -r '.tool_name // ""' <<<"$input")
[[ "$tool_name" != "Bash" ]] && exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")

# Block a bypass only as an argument word of a segment that invokes git.
# Substring matching over the raw command string blocked quoted comment bodies,
# docs echoes, and greps of this script (#1985). Splitting and quote-stripping
# live in lib/state.sh — a quoted string is removed entirely, which is what
# makes matching a bare `-n` safe: `git commit -m "fix the -n bug"` reduces to
# `git commit -m ` before this sees it.
#
# ⚠️ HEREDOC-STRIPPED, unlike the version before #4446 (#3921 is the precedent).
# The splitter turns every newline into a separator, so a heredoc body line
# beginning `LEFTHOOK_EXCLUDE=… git commit` is a segment anchored at column 0.
# The SOP mandates writing prose through `<<'EOF'`, so a board comment or a
# commit body DESCRIBING a bypass is the normal shape here — and this ticket's
# own description contains one. A heredoc body is data, never the command word.
#
# `--no-verify` is matched on any subcommand that takes it. `-n` is matched on
# `commit` ALONE: the same letter is `--dry-run` on push and clean, `--no-stat`
# on merge, and a commit count on log, so matching it everywhere would refuse
# ordinary work — and a guard that refuses ordinary work is one people turn off,
# which leaves a wider hole than the one it closed.
noverify_re='(^|[[:space:]])(--no-verify)([[:space:]]|$)'
shortn_re='(^|[[:space:]])(-[A-Za-z]*n[A-Za-z]*)([[:space:]]|$)'

# The runner switches, NAMED rather than inferred from shape, for the reason
# above: "any VAR=value prefix on a git command" refuses `CI=true git commit`
# and `GIT_AUTHOR_DATE=… git commit`, both of which are ordinary and common.
#
# Read from each runner's own documentation rather than from a list:
#   husky       HUSKY=0                                 (typicode.github.io/husky)
#   lefthook    LEFTHOOK=0, LEFTHOOK_EXCLUDE=<tags>     (lefthook.dev)
#   pre-commit  SKIP=<hook-ids>, PRE_COMMIT_ALLOW_NO_CONFIG=1
#
# ⚠️ `HUSKY` AND `LEFTHOOK` TAKE A FALSY VALUE and the other three do not. A
# non-falsy `HUSKY` is meaningful — `HUSKY=2` is husky's debug mode — so
# matching the bare name would refuse a legitimate setting. The other three
# exist only to skip, so the name alone is the bypass whatever it holds.
runner_re='(^|[[:space:]])((HUSKY|LEFTHOOK)=(0|false)?|(LEFTHOOK_EXCLUDE|SKIP|PRE_COMMIT_ALLOW_NO_CONFIG)=[^[:space:]]*)([[:space:]]|$)'

bypass=""
while IFS= read -r segment; do
  juscribe_sop_segment_invokes_git "$segment" || continue

  if [[ "$segment" =~ $noverify_re ]]; then
    bypass="${BASH_REMATCH[2]}"
    break
  fi
  if [[ "$segment" =~ $runner_re ]]; then
    bypass="${BASH_REMATCH[2]}"
    break
  fi
  if juscribe_sop_segment_invokes_git "$segment" "commit" \
      && [[ "$segment" =~ $shortn_re ]]; then
    bypass="${BASH_REMATCH[2]}"
    break
  fi
done < <(juscribe_sop_command_segments "$(juscribe_sop_strip_heredocs "$command")")

if [[ -n "$bypass" ]]; then
  # ⚠️ THE REFUSAL NAMES WHAT IT SAW. It said `--no-verify` whatever it matched
  # until #4446, so a reader who had typed `-n` or a runner variable was sent
  # looking for a flag that was not in their command.
  cat >&2 <<EOF
[jus:hard-rules] BLOCKED: \`${bypass}\` skips the git hooks.

Every hook runner has a switch that turns the checks off, and they are all the
same thing as \`--no-verify\`: git's own \`-n\`, husky's \`HUSKY=0\`, lefthook's
\`LEFTHOOK=0\` and \`LEFTHOOK_EXCLUDE\`, pre-commit's \`SKIP\` and
\`PRE_COMMIT_ALLOW_NO_CONFIG\`.

The hooks exist to catch broken work before it is committed or pushed.
Bypassing them accumulates breakage that someone has to discover later.

If the check cannot run here — a missing toolchain, a sandbox without the
language — that is worth saying out loud rather than silencing: commit the part
that passes, or escalate. If a hook is genuinely wrong, fix the hook. Do not
silence it locally.
EOF
  exit 2
fi

exit 0
