#!/usr/bin/env bash
# GitHub Copilot → shared-script payload normalizer (#4260).
#
# Copilot's documented hook contract is camelCase and differs from the shared
# scripts' Claude-Code shape in four ways. This shim rewrites the payload, execs
# the real hook, and normalizes the exit code on the way back.
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
# Usage (from hooks/copilot/*.json):
#   jus-copilot-adapt.sh <shared-script> [args...]
#
# ⚠️ `toolArgs` IS A STRING CONTAINING JSON, NOT AN OBJECT. GitHub's own worked
# example re-parses it — `jq -r '.toolArgs'` then `jq -r '.command'` on the
# result. Treating it as an object gives every field as null, which reads as "no
# command" and passes every blocker silently. This is the Kimi `tool_response`
# failure (#4207) wearing a different name: a type mismatch that fails OPEN.
#
# ⚠️ EXIT CODES ARE NOT SYMMETRIC, AND THIS IS THE ADAPTER'S REAL DECISION.
# Copilot documents that for a `preToolUse` command hook, "exit 2, crashes, and
# other non-zero exits all fail-closed and deny the tool call". The shared
# scripts are deliberately fail-OPEN — a missing `jq`, malformed JSON or an
# unreadable state file exits 0 rather than wedging the session (see lib/state.sh)
# — but a genuine crash would exit 1, and under Copilot's rule that would BLOCK a
# tool call the hook never meant to judge. So this shim collapses every exit
# other than 2 to 0: a deliberate block stays a block, and a broken hook stays
# out of the way. Named in the README rather than left implicit, because it means
# a Copilot user gets marginally less protection from a hook that is itself
# broken, which is the right trade for a guard that must never be the reason
# somebody cannot work.
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

# Already Claude-shaped? Copilot's reference describes PascalCase event names as
# carrying snake_case fields, which would make the shim a passthrough — that is
# UNVERIFIED (no Copilot install here, see the README) and this branch is what
# makes the manifest correct either way rather than a bet on it.
if jq -e 'has("tool_name") or has("session_id")' >/dev/null 2>&1 <<<"$input"; then
  "$target" "$@" <<<"$input"
  ec=$?
  [[ "$ec" -eq 2 ]] && exit 2
  exit 0
fi

# ⚠️ TOOL NAMES ARE INFERRED FROM THE ARGUMENT SHAPE, NOT FROM A LIST OF NAMES.
# Only `bash` is documented; the edit/write/read tool names are not, and a guessed
# name that is wrong does not fail loudly — the hook simply never fires, which is
# the silent no-protection state this whole project exists to end. The shapes are
# forced: a shell tool carries `.command`, an edit carries `.old_string` +
# `.new_string`, a write carries `.content`. `bash` is still matched by name
# first, because that one IS documented and a name is cheaper than a shape.
args=$(jq -r '.toolArgs // ""' <<<"$input")
if ! jq -e . >/dev/null 2>&1 <<<"$args"; then
  args="{}"
fi

raw_name=$(jq -r '.toolName // ""' <<<"$input")
case "$raw_name" in
  bash | shell) claude_name="Bash" ;;
  *)
    if jq -e 'has("command")' >/dev/null 2>&1 <<<"$args"; then
      claude_name="Bash"
    elif jq -e 'has("edits")' >/dev/null 2>&1 <<<"$args"; then
      claude_name="MultiEdit"
    elif jq -e 'has("old_string") or has("new_string")' >/dev/null 2>&1 <<<"$args"; then
      claude_name="Edit"
    elif jq -e 'has("content")' >/dev/null 2>&1 <<<"$args"; then
      claude_name="Write"
    else
      claude_name="$raw_name"
    fi
    ;;
esac

normalized=$(jq --argjson args "$args" --arg name "$claude_name" '
  . as $in
  | {
      session_id: ($in.sessionId // $in.session_id // ""),
      cwd: ($in.cwd // ""),
      tool_name: $name,
      tool_input: $args,
      prompt: ($in.prompt // ""),
      stop_hook_active: ($in.stop_hook_active // false),
      transcript_path: ($in.transcriptPath // $in.transcript_path // "")
    }
  | if ($in | has("toolResult")) then .tool_response = $in.toolResult else . end
' <<<"$input" 2>/dev/null) || exit 0

"$target" "$@" <<<"$normalized"
ec=$?
[[ "$ec" -eq 2 ]] && exit 2
exit 0
