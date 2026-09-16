#!/usr/bin/env bash
# Cursor → shared-script payload normalizer (#4261).
#
# Cursor is the closest of the adapters to a straight passthrough: its
# `preToolUse` / `postToolUse` payloads already carry `tool_name` and
# `tool_input` under exactly those names, and exit 2 blocks. What differs is
# that Cursor splits shells, file edits and prompts into their OWN events, each
# with its own field names and none of them carrying `tool_name` at all.
#
#   Cursor event           carries                    normalized to
#   ---------------------  -------------------------  -----------------------
#   preToolUse             tool_name, tool_input      passthrough
#   postToolUse            tool_name, tool_input,     tool_response = tool_output
#                          tool_output
#   beforeShellExecution   command, cwd, sandbox      tool_name "Bash"
#   afterShellExecution    command, output, duration  tool_name "Bash" + response
#   afterFileEdit          file_path, edits[]         tool_name "MultiEdit"
#   beforeSubmitPrompt     prompt, attachments        prompt (unchanged)
#   stop                   status, loop_count         cwd + stop_hook_active
#
# Usage (from hooks/cursor/hooks.json):
#   jus-cursor-adapt.sh <shared-script> [args...]
#
# ⚠️ THE SHELL EVENTS ARE WHY THIS ADAPTER IS ROBUST. `beforeShellExecution`
# hands over `command` directly, so the five command blockers never have to guess
# what Cursor calls its shell tool. Only `jus-block-lint-suppression.sh` has to
# ride `preToolUse` and infer from the argument shape, because Cursor has no
# before-file-edit event at all — `afterFileEdit` fires once the write has
# happened.
#
# ⚠️ `stop` CARRIES NEITHER `cwd` NOR `stop_hook_active`, AND BOTH MATTER.
# The workspace comes from the common `workspace_roots` array; the loop guard
# comes from `loop_count`, which Cursor increments each time the stop hook has
# already run this turn. Map either one wrongly and the stop hook either never
# fires or fires forever — and neither failure announces itself.
#
# ⚠️ NO EXIT-CODE COLLAPSE HERE, UNLIKE THE COPILOT SHIM. Cursor documents any
# non-zero exit other than 2 as fail-OPEN by default, which is already this
# bundle's doctrine, so a crashing hook cannot wedge a session. Do not add
# `failClosed: true` to the manifest without reading hooks/copilot/README.md
# first — that flag turns a broken `jq` into a stopped agent.
set -uo pipefail

target="${1:-}"
shift || true
if [[ -z "$target" || ! -x "$target" ]]; then
  exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
jq . >/dev/null 2>&1 <<<"$input" || exit 0

event=$(jq -r '.hook_event_name // ""' <<<"$input")

# `workspace_roots` is the only cwd the shell-less events carry. `cwd` wins where
# an event has one, because a shell can run outside the first root.
normalized=$(jq '
  . as $in
  | (.cwd // (.workspace_roots // [] | .[0]) // "") as $cwd
  | (.hook_event_name // "") as $event
  | {
      session_id: ($in.conversation_id // ""),
      cwd: $cwd,
      transcript_path: ($in.transcript_path // ""),
      prompt: ($in.prompt // "")
    }
  | if $event == "beforeShellExecution" or $event == "afterShellExecution" then
      .tool_name = "Bash" | .tool_input = { command: ($in.command // "") }
    elif $event == "afterFileEdit" then
      .tool_name = "MultiEdit"
      | .tool_input = { file_path: ($in.file_path // ""), edits: ($in.edits // []) }
    else
      .tool_name = ($in.tool_name // "") | .tool_input = ($in.tool_input // {})
    end
  | if $event == "afterShellExecution" then .tool_response = ($in.output // "")
    elif ($in | has("tool_output")) then .tool_response = $in.tool_output
    else . end
  | if $event == "stop" then .stop_hook_active = (($in.loop_count // 0) > 0)
    else .stop_hook_active = ($in.stop_hook_active // false) end
' <<<"$input" 2>/dev/null) || exit 0

# ⚠️ Cursor has no before-file-edit event, so the lint-suppression guard rides
# `preToolUse` — where the tool NAME is undocumented, exactly as on Copilot. The
# shape is forced and the name is not, so infer from the shape. Confined to
# `preToolUse`: every other event above already knows what it is.
if [[ "$event" == "preToolUse" ]]; then
  normalized=$(jq '
    if (.tool_input | has("edits")) then .tool_name = "MultiEdit"
    elif (.tool_input | has("old_string")) or (.tool_input | has("new_string")) then .tool_name = "Edit"
    elif (.tool_input | has("content")) then .tool_name = "Write"
    elif (.tool_input | has("command")) then .tool_name = "Bash"
    else . end
  ' <<<"$normalized" 2>/dev/null) || exit 0
fi

exec "$target" "$@" <<<"$normalized"
