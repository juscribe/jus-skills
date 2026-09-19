#!/usr/bin/env bash
# GitHub Copilot → shared-script payload normalizer (#4260).
#
# Copilot's hook payload is camelCase and differs from the shared scripts'
# Claude-Code shape. This shim rewrites the payload, execs the real hook, and
# translates the result back into a signal Copilot understands.
#
#   Copilot                      shared scripts
#   ---------------------------  -------------------------
#   sessionId                    session_id
#   toolName                     tool_name
#   toolArgs  (a JSON *STRING*)  tool_input (an object)
#   toolResult                   tool_response
#   transcriptPath               transcript_path
#   cwd, prompt, stop_hook_active are already the same
#
# ⚠️ `toolArgs` IS A STRING CONTAINING JSON, NOT AN OBJECT. GitHub's own worked
# example re-parses it — `jq -r '.toolArgs'` then `jq -r '.command'` on the
# result. Treating it as an object gives every field as null, which reads as "no
# command" and passes every blocker silently. This is the Kimi `tool_response`
# failure (#4207) wearing a different name: a type mismatch that fails OPEN.
#
# ⚠️ THE TOOL ARGUMENT NAMES ARE NOT CLAUDE'S, AND THIS SHIPPED WRONG. Measured
# against copilot 1.0.85 on 2026-09-17 by reading the `tools` array the CLI sends
# its model: the edit tool is `edit` and carries `path`/`old_str`/`new_str`, the
# write tool is `create` and carries `path`/`file_text`, the read tool is `view`
# and carries `path`. The first cut of this shim inferred `Edit` from
# `old_string`/`new_string` and `Write` from `content` — Claude's names, which
# Copilot never sends — so every edit-based blocker fell through to its
# `tool_name` guard and exited 0. A live `# rubocop:disable` edit went straight
# into the file. The tests passed because they were built from the same guess.
# Hence both a NAME map and a FIELD map below, with shape inference kept only as
# the fallback for a tool neither covers.
#
# ⚠️ EXIT CODES ARE NOT SYMMETRIC, AND THIS IS THE ADAPTER'S REAL DECISION.
# Copilot denies the tool call on ANY non-zero exit — measured: exit 1 blocks and
# reports "(hook errored)". The shared scripts are deliberately fail-OPEN — a
# missing `jq`, malformed JSON or an unreadable state file exits 0 rather than
# wedging the session (see lib/state.sh) — but a genuine crash exits 1, which
# under Copilot's rule would BLOCK a tool call the hook never meant to judge. So
# this shim collapses every exit other than 2 to 0: a deliberate block stays a
# block, and a broken hook stays out of the way.
#
# ⚠️ A BARE exit 2 LOSES THE REASON. Measured: the model is told only "Denied by
# preToolUse hook: hook exited with code 2", so the SOP text the blocker wrote to
# stderr — which says what to do instead — reaches nobody. Copilot's other deny
# signal carries it: `{"permissionDecision":"deny","permissionDecisionReason":…}`
# on stdout renders as "Denied by preToolUse hook: <reason>". So on a block this
# shim emits BOTH, which measured as blocking and carrying the reason. The exit
# code is the backstop if a future version stops reading stdout.
#
# ⚠️ The `hookSpecificOutput` wrapper Claude Code uses FAILS OPEN here — measured,
# the tool ran and nothing was reported. Do not "harmonise" the two shapes.
#
# Usage (from hooks/copilot/*.json):
#   jus-copilot-adapt.sh <shared-script> [args...]
#
# Fail-open philosophy matches lib/state.sh: missing target, missing jq, or
# malformed input exits 0 rather than wedging the tool call.
set -uo pipefail

target="${1:-}"
shift || true
if [[ -z "$target" || ! -x "$target" ]]; then
  exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
jq . >/dev/null 2>&1 <<<"$input" || exit 0

# `toolName`/`toolArgs` are what make an event a TOOL event, and only a tool
# event has a permission decision to express. An agentStop or prompt hook keeps
# the plain exit-2-plus-stderr form, which is what Copilot renders to the
# terminal for those.
is_tool_event=0
jq -e 'has("toolName") or has("toolArgs") or has("tool_name")' >/dev/null 2>&1 <<<"$input" \
  && is_tool_event=1

# Runs the target, then reports the block the way Copilot reads it. Stdout is
# forwarded on a pass so a shared script that prints keeps doing so; on a block
# the decision object replaces it, because stdout is the channel the decision
# travels on.
run_target() {
  local payload="$1"; shift
  local err_file stdout_text err_text ec=0
  if ! err_file=$(mktemp 2>/dev/null); then
    # No temp file, so no reason to relay — but a block is still a block.
    "$target" "$@" <<<"$payload" >/dev/null 2>&1 || ec=$?
    [[ "$ec" -eq 2 ]] && return 2
    return 0
  fi
  stdout_text=$("$target" "$@" <<<"$payload" 2>"$err_file") || ec=$?
  err_text=$(cat "$err_file" 2>/dev/null)
  rm -f "$err_file"

  if [[ "$ec" -ne 2 ]]; then
    [[ -n "$stdout_text" ]] && printf '%s\n' "$stdout_text"
    [[ -n "$err_text" ]] && printf '%s\n' "$err_text" >&2
    return 0
  fi

  if [[ "$is_tool_event" -eq 1 ]]; then
    jq -n --arg reason "${err_text:-Blocked by a jus enforcement hook.}" \
      '{permissionDecision: "deny", permissionDecisionReason: $reason}'
  fi
  [[ -n "$err_text" ]] && printf '%s\n' "$err_text" >&2
  return 2
}

# Already Claude-shaped? Copilot's reference describes PascalCase event names as
# carrying snake_case fields. Not observed on 1.0.85 — every payload measured was
# camelCase — but the branch costs nothing and makes the shim correct either way.
if jq -e 'has("tool_name") or has("session_id")' >/dev/null 2>&1 <<<"$input"; then
  run_target "$input" "$@"
  exit $?
fi

args=$(jq -r '.toolArgs // ""' <<<"$input")
if ! jq -e . >/dev/null 2>&1 <<<"$args"; then
  args="{}"
fi

# Copilot's own names, read off the `tools` array it sends its model (1.0.85).
# The shape fallback stays for anything not on this list — a renamed or
# plugin-provided tool — because a name that is merely unknown must not silently
# disable a blocker.
raw_name=$(jq -r '.toolName // ""' <<<"$input")
case "$raw_name" in
  bash | shell) claude_name="Bash" ;;
  edit) claude_name="Edit" ;;
  create) claude_name="Write" ;;
  view) claude_name="Read" ;;
  *)
    if jq -e 'has("command")' >/dev/null 2>&1 <<<"$args"; then
      claude_name="Bash"
    elif jq -e 'has("edits")' >/dev/null 2>&1 <<<"$args"; then
      claude_name="MultiEdit"
    elif jq -e 'has("old_str") or has("new_str") or has("old_string") or has("new_string")' >/dev/null 2>&1 <<<"$args"; then
      claude_name="Edit"
    elif jq -e 'has("file_text") or has("content")' >/dev/null 2>&1 <<<"$args"; then
      claude_name="Write"
    else
      claude_name="$raw_name"
    fi
    ;;
esac

# Field names, same measurement. Each rename is applied only when the
# Claude-shaped key is absent, so a payload that already carries it is untouched.
args=$(jq '
  def rename($from; $to):
    if has($from) and (has($to) | not) then .[$to] = .[$from] else . end;
  rename("path"; "file_path")
  | rename("old_str"; "old_string")
  | rename("new_str"; "new_string")
  | rename("file_text"; "content")
' <<<"$args" 2>/dev/null) || args='{}'

normalized=$(jq --argjson args "$args" --arg name "$claude_name" '
  # ⚠️ `//` IS NOT A FALLBACK OPERATOR FOR STRINGS. It falls back on `null` and
  # `false` only, so an empty string WINS a chain and a better later source is
  # never reached (#4261, audited across all seven shims on #4428). The two
  # camelCase/snake_case pairs below read as that class, so they go through
  # `pick` — but neither is REACHABLE today, and saying so is the point of the
  # note. The passthrough branch above returns early on
  # `has("tool_name") or has("session_id")`, so by the time this program runs
  # the payload provably has no `session_id` and the second candidate is always
  # absent. `pick` is what keeps them correct if that branch is ever narrowed;
  # it is not a defect being fixed.
  #
  # ⚠️ `cwd` KEEPS `//` DELIBERATELY: Copilot sends no second source for it, so
  # the chain has one candidate and both spellings agree. An empty `cwd` there
  # reaches the shared scripts and lands on their own `$PWD` fallback, which
  # stays deliberately — the reasoning is on
  # `juscribe_sop_require_jus_project` in ../../scripts/lib/state.sh.
  # ⚠️ UNVERIFIED: Copilot is not installed on the machine this was written on,
  # so whether it ever sends an empty string is unmeasured.
  def pick: map(select(. != null and . != false and . != "")) | first // "";
  . as $in
  | {
      session_id: ([$in.sessionId, $in.session_id] | pick),
      cwd: ($in.cwd // ""),
      tool_name: $name,
      tool_input: $args,
      prompt: ($in.prompt // ""),
      stop_hook_active: ($in.stop_hook_active // false),
      transcript_path: ([$in.transcriptPath, $in.transcript_path] | pick)
    }
  | if ($in | has("toolResult")) then .tool_response = $in.toolResult else . end
' <<<"$input" 2>/dev/null) || exit 0

run_target "$normalized" "$@"
exit $?
