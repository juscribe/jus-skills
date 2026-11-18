#!/usr/bin/env bash
# SessionStart, PostModelSwitch and PreToolUse on Bash (Claude Code), PreToolUse
# on Bash (Codex), beforeShellExecution (Cursor): remember which model the
# session runs, so `jus api` can report it.
#
# No agent tells the commands it runs which model it is using. Claude Code's
# docs say outright that there is no $CLAUDE_MODEL, but these payloads carry
# the model. This writes it to one file per session id, and
# `jus_session_headers` in the CLI reads it back by the session id in its own
# environment and sends it as X-Jus-Model. So the id must be one the agent
# gives BOTH sides:
#
#   Claude Code   payload session_id        =  CLAUDE_CODE_SESSION_ID
#   Codex         payload session_id        =  CODEX_SESSION_ID
#   Cursor        payload conversation_id   =  CURSOR_CONVERSATION_ID
#                 (its adapter hands it over as session_id)
#
# Antigravity and Gemini are not registered: neither was shown to give its
# shell a session id, so a file written here could never be found.
#
# ⚠️ A CODEX SUBAGENT IS SKIPPED. Its payload carries the ROOT session's id,
# the same value CODEX_SESSION_ID holds, and it may run another model, so
# saving it would relabel the parent's next comment. Codex marks one with
# `agent_id`.
#
# ⚠️ A PAYLOAD WITHOUT A MODEL CHANGES NOTHING. Claude Code omits it after
# `/clear`, which starts a new session id anyway, so no older file is wrong.
#
# ⚠️ CLAUDE CODE NAMES ITS MODEL ONLY ON A SWITCH, so its transcript is read.
# Neither a fresh nor a resumed SessionStart carries one. On a Bash
# PreToolUse, which carries none either, this takes the newest model in the
# tail of the payload's transcript_path. That is the `model` attachment line
# Claude Code writes with the first prompt and after every switch, or a reply
# line, whichever is later. The attachment is what makes the first command
# work: the transcript is written in batches, and the reply issuing a command
# is not on disk when that command's hook runs. The format is no documented
# interface, so a line in any other shape is skipped, as ccusage skips one,
# and a tail with none saves nothing.
#
# Display only, like everything the CLI reports. It never prints and always
# exits 0: a model it cannot save is a Model row left out, never a blocked tool.

set -euo pipefail

# shellcheck source=lib/state.sh
source "$(dirname "$0")/lib/state.sh"
juscribe_sop_require_jq

# The transcript is read back from its end in windows that start here and grow
# fourfold to the cap. A session's first command finds the model line about
# 400 KB back, behind the system prompt and tool listings (387-435 KB over 59
# sessions in the repository that produces this bundle); every later command
# finds a reply in the first window. Overridable so a test can watch it.
tail_bytes=${JUS_TRANSCRIPT_TAIL_BYTES:-65536}
tail_max=${JUS_TRANSCRIPT_TAIL_MAX:-4194304}
[[ "$tail_bytes" =~ ^[1-9][0-9]{0,9}$ ]] || tail_bytes=65536
[[ "$tail_max" =~ ^[1-9][0-9]{0,9}$ ]] || tail_max=4194304

# The newest usable model line in the transcript, as "<model>\x1f<epoch>".
# `fromjson?` drops a line cut in half by the window's edge, and every shape
# check that fails drops its line rather than the run. A [1m] context suffix
# comes off the attachment's id, because no reply line carries one and a
# session should report one name.
newest_line='
  def stamp: .timestamp | strings | sub("\\.[0-9]+Z\\z"; "Z") | try (fromdateiso8601 | floor) catch empty;
  def usable: strings | select(test("\\A[ -~]{1,80}\\z") and . != "<synthetic>");
  [ inputs | fromjson? | objects | select(.isSidechain != true)
    | if .type == "assistant" then [(.message.model? | usable), stamp]
      elif .type == "attachment" and .attachment.type? == "model"
        then [(.attachment.identity.modelId? | strings | sub("\\[[^\\]]*\\]\\z"; "") | usable), stamp]
      else empty end
    | select(length == 2)
  ] | last // empty | "\(.[0])\u001f\(.[1])"'

# transcript_model <path> — prints the newest model line from the tail, or nothing.
transcript_model() {
  local path=$1 size bytes=$tail_bytes found=""
  [[ -f "$path" && -r "$path" ]] || return 0
  size=$(wc -c <"$path")
  size=${size//[[:space:]]/}
  while :; do
    # The prefilter keeps jq off the system prompt, which is most of the bytes.
    found=$(tail -c "$bytes" "$path" 2>/dev/null \
      | LC_ALL=C grep -F -e '"type":"assistant"' -e '"attachment":{"type":"model"' \
      | jq -R -n -r "$newest_line" 2>/dev/null) || found=""
    if [[ -n "$found" ]] || (( bytes >= size || bytes >= tail_max )); then
      break
    fi
    bytes=$(( bytes * 4 > tail_max ? tail_max : bytes * 4 ))
  done
  printf '%s' "$found"
}

# file_mtime <file> — seconds since the epoch, from GNU stat or BSD stat.
file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

input=$(cat)
juscribe_sop_require_valid_json "$input"
juscribe_sop_require_jus_project "$(jq -r '.cwd // ""' <<<"$input")"

# ⚠️ THE SHAPES ARE CHECKED IN jq, WITH \A AND \z. jq -r would print a model
# holding a newline as two lines, and `read` would keep the first, which is
# valid. Oniguruma's `$` also matches before a newline, so only \z will do.
# Both shapes are the server's (ClientSession::Report): a value it would drop
# is not worth saving, and the id becomes a file name here.
fields=$(jq -r '
  def shaped($re): if type == "string" and test($re) then . else "" end;
  [ (.session_id // "" | shaped("\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,99}\\z")),
    (.to_model // .model // "" | shaped("\\A[ -~]{1,80}\\z")),
    (if (.agent_id // "") == "" then "" else "subagent" end),
    (.transcript_path // "" | shaped("\\A[^[:cntrl:]]{1,4096}\\z"))
  ] | join("\u001f")' <<<"$input" 2>/dev/null) || exit 0
IFS=$'\x1f' read -r session model subagent transcript <<<"$fields" || true

if [[ -z "$session" ]]; then
  juscribe_sop_outcome no-session
  exit 0
fi
if [[ -n "$subagent" ]]; then
  juscribe_sop_outcome subagent
  exit 0
fi
# Set only from the transcript: when the line holding the model was written.
at=""
if [[ -z "$model" && -n "$transcript" ]]; then
  IFS=$'\x1f' read -r model at <<<"$(transcript_model "$transcript")" || true
fi
if [[ -z "$model" ]]; then
  juscribe_sop_outcome no-model
  exit 0
fi

dir=$(juscribe_sop_model_dir) || exit 0
file="$dir/$session"

# Codex fires this before every shell command, so an unchanged model is the
# common case and costs a read, never a write.
if [[ -f "$file" && "$(cat "$file" 2>/dev/null)" == "$model" ]]; then
  juscribe_sop_outcome unchanged
  exit 0
fi

# ⚠️ A LINE OLDER THAN THE SAVED FILE NEVER REPLACES IT. A `/model` made
# mid-turn saves the new model through PostModelSwitch before the new model's
# first reply reaches the transcript, so at that reply's first command the
# newest line on disk is still the old model's.
if [[ -n "$at" && -f "$file" ]]; then
  # A stat that does not answer with a number cannot date it: the line is taken.
  saved_at=$(file_mtime "$file") || saved_at=""
  if [[ "$saved_at" =~ ^[0-9]+$ ]] && (( at < saved_at )); then
    juscribe_sop_outcome older
    exit 0
  fi
fi

# A session's first file is when older ones are cleared, so this runs once per
# session rather than on every call. One file a session is all that ever lands
# here, so a week covers any session still open.
#
# ⚠️ ONLY IN A DIRECTORY NAMED session-models. JUS_SESSION_MODEL_DIR can point
# anywhere, and a week-old file in $HOME is not ours to delete.
if [[ ! -e "$file" && "${dir##*/}" == "session-models" && -d "$dir" && ! -L "$dir" ]]; then
  find "$dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
fi

# Written beside the target and renamed over it, so the CLI never reads half.
mkdir -p "$dir" 2>/dev/null || { juscribe_sop_outcome unwritable; exit 0; }
# Set before the write and corrected if it fails: the EXIT trap reads it.
juscribe_sop_outcome recorded
# Unbraced on purpose: Claude's plugin directory reads a braced expression
# holding the word session as a lookup of the user's credentials.
staged="$dir/.$session.$$"
if ! { printf '%s' "$model" >"$staged" && mv -f "$staged" "$file"; } 2>/dev/null; then
  rm -f "$staged" 2>/dev/null || true
  juscribe_sop_outcome unwritable
  exit 0
fi
