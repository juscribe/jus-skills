#!/usr/bin/env bash
# Antigravity (agy) → shared-script payload normalizer, and back again (#4262).
#
# ⚠️ THIS IS THE ONLY ADAPTER THAT TRANSLATES THE RESPONSE AS WELL AS THE INPUT,
# and the reason is the one thing every other tool here gives us for free.
# Claude Code, Codex, Kimi, Copilot and Cursor all treat **exit 2 with a stderr
# reason** as a block, which is exactly what the twelve shared scripts already
# do. Antigravity does not: it wants a JSON answer on stdout for EVERY
# invocation, including the ones that allow. A shim that only normalised the
# input would let every block through while looking installed.
#
# ⚠️ AND THE ANSWER IS A DIFFERENT SHAPE FOR EVERY EVENT, which is why the event
# name is the FIRST argument rather than something the shim could infer.
# Antigravity parses each hook's stdout with **protojson, DiscardUnknown off**,
# against a per-event message — so a key that belongs to a different event is a
# hard error, not an inert sibling. Measured on agy 1.2.5 in the orb:
#
#   prehooks.go:43] failed to unmarshal result … via protojson:
#     {"decision":"allow","allow_tool":true,…}: proto: (line 1:2):
#     unknown field "decision"
#
# That is `PreInvocation` rejecting `decision` at the FIRST key. On `Stop` the
# same payload failed at 1:21 instead — `decision` passed, `allow_tool` did not.
#
# ⚠️ AND A PreToolUse HOOK THAT ERRORS FAILS THE TOOL CALL. This is the one
# fail-CLOSED path in the bundle, and it is the engine's behaviour rather than
# ours: a malformed answer does not degrade to "allowed", it wedges the agent.
# So every exit path here writes a valid object for the event it was called on.
#
#   Antigravity                           shared scripts
#   ------------------------------------  --------------------------
#   .toolCall.args.CommandLine            tool_input.command
#   .toolCall.args.TargetFile             tool_input.file_path
#   .toolCall.args.CodeContent            tool_input.content
#   .toolCall.args.TargetContent          tool_input.old_string
#   .toolCall.args.ReplacementContent     tool_input.new_string
#   .toolCall.name                        tool_name (mapped, see below)
#   .conversationId                       session_id
#   stdout JSON per event, always         exit 0 / exit 2 + stderr
#
# Usage (from hooks/antigravity/hooks.json):
#   jus-antigravity-adapt.sh <Event> <shared-script> [args...]
set -uo pipefail

event="${1:-PreToolUse}"
target="${2:-}"
shift 2 2>/dev/null || shift $#

# ── the neutral answer, per event ────────────────────────────────────────────
# ⚠️ `{}` IS NOT UNIVERSALLY SAFE. PreToolUse treats a missing `decision` as no
# opinion, which is fine, but it is the only event whose allow we state
# explicitly — silence there has been reported to wedge the loop, and saying
# "allow" costs nothing.
neutral() {
  case "$event" in
    PreToolUse) printf '{"decision":"allow"}\n' ;;
    *) printf '{}\n' ;;
  esac
  exit 0
}

# ── where a cwd comes from when the payload has none ─────────────────────────
# ⚠️ ANTIGRAVITY SENDS NO `cwd`, AND THAT SILENTLY DISARMS EVERY GUARD.
# `workspacePaths` came back `[]` on every captured payload, and the shared
# scripts gate on the cwd being inside a git repo holding `.jus/` (#4404) — so
# an empty one makes all twelve exit 0 without looking at anything.
#
# The hook process's own $PWD is no fallback either: Antigravity sets it to the
# directory containing hooks.json, measured `/home/caleon/.gemini/config` for a
# global install, which is never a Juscribe project.
#
# So the tool events derive one — `run_command` carries `.args.Cwd`, the file
# tools carry an absolute `.args.TargetFile` — and remember it for the events
# that carry neither (`PreInvocation`, `PostInvocation`, `Stop`).
STATE_DIR="${JUS_ANTIGRAVITY_STATE:-${TMPDIR:-/tmp}/jus/antigravity}"

conv_slug() {
  printf '%s' "${1:-anonymous}" | tr -c 'A-Za-z0-9-' '_' | cut -c1-64
}

[[ -z "$target" || ! -x "$target" ]] && neutral
command -v jq >/dev/null 2>&1 || neutral

input=$(cat)
jq . >/dev/null 2>&1 <<<"$input" || neutral

conversation=$(jq -r '.conversationId // ""' <<<"$input" 2>/dev/null) || conversation=""
slug=$(conv_slug "$conversation")
cwd_file="$STATE_DIR/$slug.cwd"
pending_file="$STATE_DIR/$slug.pending"

remembered_cwd=""
[[ -r "$cwd_file" ]] && remembered_cwd=$(cat "$cwd_file" 2>/dev/null)

# ⚠️ THE TOOL NAMES ARE ANTIGRAVITY'S OWN AND MATCH NOTHING WE SHIP.
# Measured, not guessed: `run_command`, `write_to_file`, `replace_file_content`,
# `view_file`. An earlier cut of this shim inferred the tool from Claude's
# argument names (`old_string`, `content`, `edits`) — none of which appears in
# an Antigravity payload, so every edit reached the guards unrecognised and
# passed.
normalized=$(jq --arg remembered "$remembered_cwd" '
  . as $in
  | ($in.toolCall.args // {}) as $args
  | (($args.CommandLine // "") | tostring) as $cmd
  | (($args.TargetFile // "") | tostring) as $file
  | (
      ($args.Cwd // "")
      | if . != "" then .
        elif $file != "" then ($file | sub("/[^/]*$"; ""))
        else (($in.workspacePaths // []) | first // $in.cwd // $remembered // "")
        end
    ) as $cwd
  | {
      session_id: ($in.conversationId // ""),
      cwd: ($cwd | tostring),
      transcript_path: ($in.transcriptPath // ""),
      prompt: ($in.prompt // ""),
      stop_hook_active: false,
      tool_input: $args,
      tool_name: ($in.toolCall.name // "")
    }
  | if $cmd != "" then .tool_name = "Bash" | .tool_input.command = $cmd else . end
  | if ($in.toolCall.name // "") == "write_to_file" then
      .tool_name = "Write"
      | .tool_input.file_path = $file
      | .tool_input.content = ($args.CodeContent // "")
    elif ($in.toolCall.name // "") == "replace_file_content" then
      .tool_name = "Edit"
      | .tool_input.file_path = $file
      | .tool_input.old_string = ($args.TargetContent // "")
      | .tool_input.new_string = ($args.ReplacementContent // "")
    elif ($in.toolCall.name // "") == "view_file" then
      .tool_name = "Read" | .tool_input.file_path = $file
    else . end
  | if ($in | has("toolResult")) then .tool_response = $in.toolResult else . end
' <<<"$input" 2>/dev/null) || neutral

# ⚠️ THE DERIVED DIRECTORY NEED NOT EXIST YET. `TargetFile` is where a file is
# ABOUT to be written, so creating `src/new/thing.ts` yields `src/new`, and
# `git -C` on a missing directory fails — which reads as "not a repository" and
# allows the very edit the guard exists to catch. Climb to the nearest ancestor
# that does exist; the repository root is always one of them.
existing_ancestor() {
  local dir="${1:-}"
  while [[ -n "$dir" && "$dir" != "/" && ! -d "$dir" ]]; do
    dir="${dir%/*}"
  done
  [[ -d "$dir" ]] && printf '%s' "$dir"
}

derived=$(jq -r '.cwd // ""' <<<"$normalized" 2>/dev/null)
if [[ -n "$derived" && ! -d "$derived" ]]; then
  derived=$(existing_ancestor "$derived")
  normalized=$(jq --arg c "$derived" '.cwd = $c' <<<"$normalized" 2>/dev/null) || neutral
fi

# Remember the cwd for the events that arrive without one.
case "$event" in
  PreToolUse | PostToolUse)
    if [[ -n "$derived" && -d "$derived" ]]; then
      mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s' "$derived" > "$cwd_file" 2>/dev/null
    fi
    ;;
esac

# The shared script's stderr is the reason text; its exit code is the verdict.
reason=$("$target" "$@" <<<"$normalized" 2>&1 >/dev/null)
ec=$?

# ⚠️ ONLY 2 IS A BLOCK. Everything else allows, including a crash — the same
# fail-open doctrine as lib/state.sh.
blocked=0
[[ "$ec" -eq 2 ]] && blocked=1

# ── drain anything a PostToolUse hook could not say ──────────────────────────
# ⚠️ A PostToolUse HOOK CANNOT TALK TO THE MODEL HERE. Its contract is an empty
# object: there is no field to carry a message. That is the same
# enforcement-becomes-nothing loss Kimi has on its post-tool event, and the same
# remedy — the text is buffered and injected on the next `PreInvocation`, which
# is the one event whose contract has somewhere to put it.
pending=""
case "$event" in
  PreInvocation | PostInvocation)
    if [[ -r "$pending_file" ]]; then
      pending=$(cat "$pending_file" 2>/dev/null)
      rm -f "$pending_file" 2>/dev/null
    fi
    ;;
esac

message="$pending"
if [[ -n "$reason" ]]; then
  message="${message:+$message$'\n\n'}$reason"
fi

case "$event" in
  PreToolUse)
    if [[ "$blocked" -eq 1 ]]; then
      jq -nc --arg r "${reason:-Blocked by the Juscribe hard-rules hooks.}" \
        '{decision: "deny", reason: $r}'
    elif [[ -n "$message" ]]; then
      jq -nc --arg r "$message" '{decision: "allow", reason: $r}'
    else
      printf '{"decision":"allow"}\n'
    fi
    ;;
  Stop)
    # ⚠️ `Stop` REALLY BLOCKS HERE, unlike Cursor and Kimi. `decision:
    # "continue"` refuses the stop and re-enters the loop with `reason` injected
    # as a system message, which is exactly what the dirty-tree gate wants.
    if [[ "$blocked" -eq 1 ]]; then
      jq -nc --arg r "${reason:-Blocked by the Juscribe hard-rules hooks.}" \
        '{decision: "continue", reason: $r}'
    else
      printf '{}\n'
    fi
    ;;
  PreInvocation | PostInvocation)
    if [[ -n "$message" ]]; then
      jq -nc --arg r "$message" '{injectSteps: [{ephemeralMessage: $r}]}'
    else
      printf '{}\n'
    fi
    ;;
  *)
    # PostToolUse and anything unrecognised: the contract is an empty object, so
    # buffer whatever the script said for the next PreInvocation to deliver.
    if [[ -n "$message" ]]; then
      mkdir -p "$STATE_DIR" 2>/dev/null &&
        printf '%s\n' "$message" >> "$pending_file" 2>/dev/null
    fi
    printf '{}\n'
    ;;
esac
exit 0
