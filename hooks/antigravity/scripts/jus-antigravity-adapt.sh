#!/usr/bin/env bash
# Antigravity (agy) → shared-script payload normalizer, and back again (#4262).
#
# ⚠️ THIS IS THE ONLY ADAPTER THAT TRANSLATES THE RESPONSE AS WELL AS THE INPUT,
# and the reason is the one thing every other tool here gives us for free.
# Claude Code, Codex, Kimi, Copilot and Cursor all treat **exit 2 with a stderr
# reason** as a block, which is exactly what the thirteen shared scripts already
# do. Antigravity does not: it wants a JSON answer on stdout for EVERY
# invocation, including the ones that allow. A shim that only normalised the
# input would let every block through while looking installed.
#
#   Antigravity                        shared scripts
#   ---------------------------------  --------------------------
#   .toolCall.args.CommandLine         tool_input.command
#   .toolCall.args.ToolName            tool_name (MCP tools)
#   .toolCall.name                     tool_name
#   stdout JSON, always                exit 0 / exit 2 + stderr
#
# Usage (from hooks/antigravity/hooks.json):
#   jus-antigravity-adapt.sh <shared-script> [args...]
#
# ⚠️ THE DENY FIELD IS CONTESTED AND THAT IS WHY BOTH ARE EMITTED. Google does
# not document the hook payload at all. Of the three third-party sources that
# do, the Antigravity developer guide says `{"allow_tool": false,
# "deny_reason": …}` and atuinsh/atuin#4117 — shipped, working code — says
# `{"decision": "allow"}`. They are different keys, so a wrong guess produces an
# adapter that installs cleanly, fires on every tool call and blocks NOTHING.
# Emitting both cannot self-contradict: whichever key the engine reads, it gets
# the same answer, and an unrecognised sibling key is inert (#3256).
#
# ⚠️ WHAT THE HEDGE DOES NOT COVER is a strict schema validator that rejects an
# unknown key outright. Nothing establishes whether Antigravity has one, and it
# is the first thing an install should settle — see the README.
set -uo pipefail

target="${1:-}"
shift || true
allow() {
  printf '{"decision":"allow","allow_tool":true}\n'
  exit 0
}

[[ -z "$target" || ! -x "$target" ]] && allow
command -v jq >/dev/null 2>&1 || allow

input=$(cat)
jq . >/dev/null 2>&1 <<<"$input" || allow

# ⚠️ THE COMMAND IS NESTED TWO LEVELS DEEPER THAN ANYWHERE ELSE, under
# `.toolCall.args.CommandLine` — the one field shipped code attests to. The
# fallbacks after it cost nothing and mean a payload that turns out to be flatter
# than this still reaches the guards, rather than reaching them as an empty
# string that reads as "no command" and passes.
normalized=$(jq '
  . as $in
  | (($in.toolCall.args.CommandLine // $in.toolCall.args.command // $in.command // "") | tostring) as $cmd
  | (($in.toolCall.name // $in.toolCall.args.ToolName // $in.tool_name // "") | tostring) as $raw
  | {
      session_id: ($in.sessionId // $in.session_id // $in.conversationId // ""),
      cwd: ($in.cwd // $in.workspaceRoot // $in.workspace_root // ""),
      transcript_path: ($in.transcriptPath // $in.transcript_path // ""),
      prompt: ($in.prompt // $in.userPrompt // ""),
      stop_hook_active: ($in.stop_hook_active // false),
      tool_input: ($in.toolCall.args // $in.tool_input // {}),
      tool_name: $raw
    }
  | if $cmd != "" then .tool_name = "Bash" | .tool_input.command = $cmd
    elif (.tool_input | has("edits")) then .tool_name = "MultiEdit"
    elif (.tool_input | has("old_string")) or (.tool_input | has("new_string")) then .tool_name = "Edit"
    elif (.tool_input | has("content")) then .tool_name = "Write"
    else . end
  | if ($in | has("toolResult")) then .tool_response = $in.toolResult
    elif ($in.toolCall | type == "object") and ($in.toolCall | has("result")) then .tool_response = $in.toolCall.result
    else . end
' <<<"$input" 2>/dev/null) || allow

# The shared script's stderr is the reason text; its exit code is the verdict.
reason=$("$target" "$@" <<<"$normalized" 2>&1 >/dev/null)
ec=$?

# ⚠️ ONLY 2 IS A BLOCK. Everything else allows, including a crash — the same
# fail-open doctrine as lib/state.sh, and here it matters more than usual,
# because a hook that answers nothing at all on stdout may wedge the agent loop
# rather than merely failing to guard.
if [[ "$ec" -eq 2 ]]; then
  jq -nc --arg r "${reason:-Blocked by the Juscribe hard-rules hooks.}" \
    '{decision:"deny", allow_tool:false, deny_reason:$r, reason:$r}'
  exit 0
fi

# A passive hook's stdout is its own output (a nudge, say) and Antigravity is not
# reading it as a decision — but PreToolUse needs an answer regardless, so the
# allow object is what goes out and the nudge text rides `reason`.
if [[ -n "$reason" ]]; then
  jq -nc --arg r "$reason" '{decision:"allow", allow_tool:true, reason:$r}'
  exit 0
fi
allow
