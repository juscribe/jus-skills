#!/usr/bin/env bash
# Qwen Code → shared-script payload normalizer (#4263).
#
# The thinnest shim in the bundle, because Qwen's hook contract is modelled
# directly on Claude Code's. `tool_name`, `tool_input`, `session_id`,
# `transcript_path` and `stop_hook_active` already carry those exact names; exit
# 2 is a documented blocking error that passes **stderr to the model as
# feedback**, which is what the thirteen shared scripts already do; and any other
# non-zero exit is non-blocking, which is this bundle's fail-open doctrine.
#
# ⚠️ SO THE ONLY THING THAT NEEDS TRANSLATING IS THE TOOL NAME — and it is not
# optional, it is the whole reason this file exists:
#
#   Qwen                 shared scripts
#   -------------------  --------------
#   run_shell_command    Bash
#   edit                 Edit
#   write_file           Write
#   read_file            Read
#
# ⚠️ AND YOU CANNOT FIX THIS IN THE MATCHER INSTEAD. QwenLM/qwen-code#11823,
# filed 2026-09-14: "A tool hook matcher written with Claude Code's tool names
# never matches in qwen-code when that name differs from qwen's own display
# name." A `"matcher": "Bash"` never fires; `"Write|Edit"` fires for `edit` and
# not for `write_file`. Qwen's permission rules map the Claude names and its hook
# matchers do not. PR #11826 is referenced as the fix, so a current build may
# behave differently — which is exactly why the manifest matches on QWEN's names
# and this shim renames afterwards. That is correct on every version, before the
# fix and after it.
#
# Usage (from hooks/qwen/settings.json):
#   jus-qwen-adapt.sh <shared-script> [args...]
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

# ⚠️ THE NAME MAP IS EXPLICIT, NOT SHAPE-INFERRED, and that is the difference
# between this adapter and the Copilot one. Qwen publishes its thirteen tool
# names, so guessing would be choosing to be less certain than the vendor.
# The shape check after it is a fallback for a tool this map has not met — a new
# Qwen tool, or a plugin's — and it never overrides a known name.
normalized=$(jq '
  . as $in
  | (.tool_name // "") as $raw
  | .tool_name = (
      if $raw == "run_shell_command" then "Bash"
      elif $raw == "edit" then "Edit"
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

# ⚠️ NO RESPONSE TRANSLATION, DELIBERATELY. Exit 2 with stderr is already what
# Qwen reads as a block, and a shared script that writes a
# `hookSpecificOutput.additionalContext` object on exit 0 is writing the shape
# Qwen already expects. Wrapping either would be the Antigravity work (#4262)
# done where it is not needed — and `exec` here means the child's stdout, stderr
# and exit code reach Qwen untouched.
exec "$target" "$@" <<<"$normalized"
