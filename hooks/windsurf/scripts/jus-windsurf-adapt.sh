#!/usr/bin/env bash
# Windsurf Cascade → shared-script payload normalizer (#4264).
#
# Cascade names its events after the ACTION rather than the tool, and puts every
# per-event field inside `tool_info`. There is no `tool_name` anywhere in the
# payload, so the event name is what decides which shared script sees what.
#
#   agent_action_name      tool_info carries          normalized to
#   ---------------------  -------------------------  ---------------------
#   pre_run_command        command_line, cwd          tool_name "Bash"
#   post_run_command       command_line, cwd          "Bash" + tool_response
#   pre_write_code         file_path, edits[]         tool_name "MultiEdit"
#   post_write_code        file_path, edits[]         tool_name "MultiEdit"
#   pre_user_prompt        user_prompt                prompt
#   post_cascade_response  response                   cwd only — see below
#
# Usage (from hooks/windsurf/hooks.json):
#   jus-windsurf-adapt.sh <shared-script> [args...]
#
# ⚠️ BLOCKING IS EXIT CODE 2 AND NOTHING ELSE. Cascade reads no JSON response at
# all — the five `pre_*` events block on exit 2 and every other exit proceeds.
# That is exactly what the thirteen shared scripts already do, so this is the
# only one of the five new adapters that needs no response handling whatsoever,
# and `exec` is what carries the code through untouched.
#
# ⚠️ THERE IS NO cwd ON EVERY EVENT, AND $PWD IS THE DOCUMENTED ANSWER. Cascade
# runs each hook with `working_directory`, which "defaults to workspace root", so
# a payload without `tool_info.cwd` still leaves the process in the right place.
# Falling back to `$PWD` is therefore reading the mechanism rather than guessing
# — and without it `jus-stop-uncommitted.sh` would find no repository and stay
# silent, which looks identical to a clean tree.
#
# Fail-open philosophy matches lib/state.sh: missing target, missing jq, or
# malformed input exits 0 rather than wedging the action.
set -uo pipefail

target="${1:-}"
shift || true
if [[ -z "$target" || ! -x "$target" ]]; then
  exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
jq . >/dev/null 2>&1 <<<"$input" || exit 0

normalized=$(jq --arg pwd "$PWD" '
  . as $in
  | (.agent_action_name // "") as $event
  | (.tool_info // {}) as $t
  | {
      session_id: ($in.trajectory_id // ""),
      cwd: ($t.cwd // $t.root_workspace_path // $pwd),
      transcript_path: ($t.transcript_path // ""),
      prompt: ($t.user_prompt // ""),
      stop_hook_active: false,
      tool_name: "",
      tool_input: {}
    }
  | if $event == "pre_run_command" or $event == "post_run_command" then
      .tool_name = "Bash" | .tool_input = { command: ($t.command_line // "") }
    elif $event == "pre_write_code" or $event == "post_write_code" then
      .tool_name = "MultiEdit"
      | .tool_input = { file_path: ($t.file_path // ""), edits: ($t.edits // []) }
    elif $event == "pre_read_code" or $event == "post_read_code" then
      .tool_name = "Read" | .tool_input = { file_path: ($t.file_path // "") }
    else . end
  | if $event == "post_run_command" then .tool_response = ($t.output // "")
    elif $event == "post_cascade_response" then .tool_response = ($t.response // "")
    else . end
' <<<"$input" 2>/dev/null) || exit 0

exec "$target" "$@" <<<"$normalized"
