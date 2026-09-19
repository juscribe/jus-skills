#!/usr/bin/env bash
# Gemini CLI → shared-script payload normalizer (#4419).
#
# ⚠️ THE THINNEST SHIM IN THE BUNDLE, AND IT IS NOT CLOSE. Gemini CLI's hook
# contract already uses Claude Code's field names, top to bottom — read out of
# `bundle/docs/hooks/reference.md` and `bundle/docs/tools/` in the published
# 0.60.0 package:
#
#   base input      session_id, transcript_path, cwd, hook_event_name
#   BeforeTool      tool_name, tool_input
#   replace         file_path, old_string, new_string
#   write_file      file_path, content
#   run_shell_command   command
#   AfterAgent      stop_hook_active
#
# Every one of those is the name the thirteen shared scripts already read. So
# nothing is renamed here and no field is moved.
#
# ⚠️ SO THE ONLY THING THAT NEEDS TRANSLATING IS THE TOOL NAME — and it is not
# optional, it is the whole reason this file exists. A matcher written `Bash`
# never fires, and every guard gates on `tool_name == "Bash"`:
#
#   Gemini CLI           shared scripts
#   -------------------  --------------
#   run_shell_command    Bash
#   replace              Edit
#   write_file           Write
#   read_file            Read
#
# ⚠️ THE MAP IS EXPLICIT, NOT SHAPE-INFERRED, like Qwen's and unlike Copilot's.
# Gemini publishes its tool names, so inferring would be choosing to be less
# certain than the vendor. The shape check after it is a fallback for a tool the
# map has not met — an MCP tool arrives as `mcp_<server>_<tool>` — and it never
# overrides a known name.
#
# ⚠️ NO RESPONSE TRANSLATION, DELIBERATELY. Gemini documents exit 2 with stderr
# as the reason as a block on BeforeTool, and a shared script that writes a
# `hookSpecificOutput.additionalContext` object on exit 0 is writing the shape
# Gemini already reads. Wrapping either would be the Antigravity work (#4262)
# done where it is not needed — and `exec` means the child's stdout, stderr and
# exit code reach Gemini untouched.
#
# Usage (from hooks/gemini/settings.json):
#   jus-gemini-adapt.sh <shared-script> [args...]
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

normalized=$(jq '
  . as $in
  | (.tool_name // "") as $raw
  | .tool_name = (
      if $raw == "run_shell_command" then "Bash"
      elif $raw == "replace" then "Edit"
      elif $raw == "write_file" then "Write"
      elif $raw == "read_file" then "Read"
      elif ($in.tool_input | type == "object") and ($in.tool_input | has("command")) then "Bash"
      elif ($in.tool_input | type == "object") and ($in.tool_input | has("edits")) then "MultiEdit"
      elif ($in.tool_input | type == "object")
        and (($in.tool_input | has("old_string")) or ($in.tool_input | has("new_string"))) then "Edit"
      elif ($in.tool_input | type == "object") and ($in.tool_input | has("content")) then "Write"
      else $raw end
    )
' <<<"$input" 2>/dev/null) || exit 0

exec "$target" "$@" <<<"$normalized"
