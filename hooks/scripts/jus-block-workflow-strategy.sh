#!/usr/bin/env bash
# PreToolUse hook (Bash): hold a CLI session to the workspace's workflow strategy.
#
# A dispatched agent is told where its work lands — the station receives
# `branch_strategy` in its payload. An ordinary `jus` CLI session was told
# nothing, which is how an iOS codebase got worked on `main` (#3832). This is
# the deterministic half of that: the skill reads the setting, the served SOP
# states it, and this refuses the two commands that contradict it.
#
# ⚠️ TWO COMMANDS, NOT THREE. A `git merge` is deliberately NOT blocked. Under
# `branch` the landing merge is the person's — but a project's own instructions
# may hand it to the agent, and this project's do: monumental's CLAUDE.md makes
# merging each worktree branch into local `main` the last step of the work. A
# bundle-wide merge block would refuse that on every ticket. What IS blocked is
# committing on the default branch under a strategy that says otherwise, which
# is the failure #3832 was actually filed about, and pushing under a strategy
# that forbids it.
#
# Fails open everywhere: no workspace id, no CLI, no answer from the API, or a
# strategy this hook does not recognise all mean silence. A guard that cannot
# establish the rule must not invent one.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

JUS="${WORKFLOW_STRATEGY_JUS:-jus}"

input=$(cat)
juscribe_sop_require_valid_json "$input"
[[ "$(jq -r '.tool_name // ""' <<<"$input")" == "Bash" ]] || exit 0

command=$(jq -r '.tool_input.command // ""' <<<"$input")
[[ -n "$command" ]] || exit 0

cwd=$(jq -r '.cwd // ""' <<<"$input")
[[ -d "$cwd" ]] || cwd="$PWD"

# What the command is trying to do. Neither, and there is nothing to rule on.
pushing=0
while IFS= read -r segment; do
  [[ -n "$segment" ]] || continue
  if juscribe_sop_segment_invokes_git "$segment" push; then
    pushing=1
    break
  fi
done < <(juscribe_sop_command_segments "$(juscribe_sop_strip_heredocs "$command")")

committing=0
juscribe_sop_is_git_commit "$command" && committing=1

(( pushing || committing )) || exit 0

# Everything past here needs the setting, so resolve it before deciding.
strategy=$(juscribe_sop_workflow_strategy "$cwd" "$JUS") || exit 0
[[ -n "$strategy" ]] || exit 0

# ⚠️ ONLY the three this hook knows how to rule on. A value added after this
# version shipped goes SILENT rather than being guessed at — a guard that
# refuses a command on a rule it does not have is worse than no guard.
#
# `SopGenerator` deliberately does the OPPOSITE with the same input, falling
# back to the default strategy's prose: it renders text, where being slightly
# stale costs a sentence, and this refuses commands, where being wrong costs
# somebody their workflow.
case "$strategy" in
  main|branch|pull_request) ;;
  *) exit 0 ;;
esac

setting_line="The workspace's Workflow setting is \`${strategy}\`. Change it in Workspace Settings → General → Workflow."

# A push is forbidden unless the strategy is the one that ends in a push.
if (( pushing )) && [[ "$strategy" != "pull_request" ]]; then
  cat >&2 <<EOF
[jus:hard-rules] BLOCKED: this workspace's workflow strategy does not push.

${setting_line}

Under \`main\` and \`branch\` the work stays on this machine: a person pushes,
or lands the branch with the Merge button on the ticket. Commit and stop there.
EOF
  exit 2
fi

# A commit on the default branch is the failure this ticket was filed about:
# an agent that quietly worked on `main` in somebody's existing codebase.
if (( committing )) && [[ "$strategy" != "main" ]]; then
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  default_branch=$(juscribe_sop_default_branch "$cwd")
  if [[ -n "$branch" && "$branch" == "$default_branch" ]]; then
    cat >&2 <<EOF
[jus:hard-rules] BLOCKED: committing on \`${branch}\` under the \`${strategy}\` workflow strategy.

${setting_line}

Cut the ticket's branch first — \`<ticket-id>-<slug>\`, which is the form that
links the branch to its ticket — and commit there:

  git switch -c <ticket-id>-<slug>
EOF
    exit 2
  fi
fi

exit 0
