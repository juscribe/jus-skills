#!/usr/bin/env bash
# The oldest `jus` CLI this bundle works with, checked once a session.
# Sourced — not executed directly. The floor itself is jus/JUS_MIN_VERSION.
#
# WHY. The bundle and the CLI ship separately, each by its own release, and
# customers run `brew upgrade jus` on their own schedule. A bundle calling a
# subcommand their CLI predates fails with `Usage: jus <command>`, exit 1,
# which every adapter reads as permission — and nothing said why.
#
# ⚠️ IT CAN ONLY SPEAK WHERE BUNDLE CODE RUNS. Claude Code runs these scripts
# directly, so it always can. Every other adapter runs them as `jus hook
# <name>`, which a CLI older than 0.8.14 (the first with `hook`) or no CLI at
# all refuses before this file is read. For that case the CLI's own
# unknown-command reply names the upgrade, in every CLI cut since this check
# shipped.
#
# ⚠️ IT NEVER STOPS ANYTHING. Its caller is a UserPromptSubmit hook, a
# blockable event, so every outcome — one it cannot read included — is a
# message, never an exit code.
#
# ⚠️ NOTHING HERE MAY `set` A SHELL OPTION. The bundle's release script
# sources this file for juscribe_sop_version_older and juscribe_sop_cli_floor,
# and it owns its own.

# Echo the floor, or fail. JUS_MIN_VERSION_FILE overrides the path for specs.
# A bundle packaged without its floor fails here, and the caller stays silent:
# nobody at the prompt can fix our packaging.
juscribe_sop_cli_floor() {
  local file="${JUS_MIN_VERSION_FILE:-${BASH_SOURCE[0]%/*}/../../../JUS_MIN_VERSION}" floor
  floor=$(tr -d '[:space:]' 2>/dev/null < "$file") || return 1
  juscribe_sop_bare_version "$floor"
}

# Echo the X.Y.Z inside what `jus version` printed, or fail. A leading `v` and a
# pre-release or build suffix are dropped; anything else is unreadable rather
# than guessed at.
juscribe_sop_bare_version() {
  local shape='^v?([0-9]+(\.[0-9]+)*)([-+][0-9A-Za-z.-]*)?$'
  [[ "$1" =~ $shape ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# 0 when dotted version $1 is older than $2. Each component compares as a
# number, so 0.8.9 is older than 0.8.14 — the pair a text comparison gets
# backwards. A missing component counts as 0. `10#` keeps a leading zero from
# reading as octal.
juscribe_sop_version_older() {
  local -a have want
  local i a b
  IFS=. read -ra have <<<"$1"
  IFS=. read -ra want <<<"$2"
  for ((i = 0; i < ${#have[@]} || i < ${#want[@]}; i++)); do
    a=$((10#${have[i]:-0}))
    b=$((10#${want[i]:-0}))
    # ⚠️ NOT A BARE `((a < b))` AS THE LAST WORD: false is exit 1, and a caller
    # under `set -e` outside a condition would end right there.
    if ((a < b)); then return 0; fi
    if ((a > b)); then return 1; fi
  done
  return 1
}

# 0 the first time a session asks, 1 after that. The marker goes in the same
# per-session directory the liveness record uses (lib/state.sh).
#
# ⚠️ NO SESSION ID MEANS ASK EVERY TIME. The shared `_anonymous` directory
# outlives the session, so a marker there would silence the check for good.
# Repeating the notice is the cheaper mistake.
juscribe_sop_cli_floor_due() {
  local session="${1:-}" dir
  [[ -n "$session" ]] || return 0
  dir=$(juscribe_sop_state_dir "$session")
  [[ -e "$dir/cli-floor-checked" ]] && return 1
  { mkdir -p "$dir" && : > "$dir/cli-floor-checked"; } 2>/dev/null || true
  return 0
}

# Echo one plain sentence when the CLI is unreadable or older than the floor,
# and nothing when it is new enough, missing, or the floor cannot be read.
# Always exits 0. The caller decides how the sentence reaches the agent and the
# user.
#
# ⚠️ A MISSING CLI SAYS NOTHING. One plugin serves chat, Cowork and
# Claude Code, and Cowork loads the hooks where nobody installed `jus`, so "it
# is not installed" was noise there every session. A hook cannot tell that
# session from a coder without the CLI; `jus doctor` and the README tell the
# coder.
# Argument: $1 = the jus command
juscribe_sop_cli_floor_check() {
  local jus="$1" floor raw said have
  floor=$(juscribe_sop_cli_floor) || return 0
  command -v "$jus" >/dev/null 2>&1 || return 0

  raw=$("$jus" version </dev/null 2>/dev/null) || raw=""
  raw="${raw%%$'\n'*}"
  if ! have=$(juscribe_sop_bare_version "$raw"); then
    said="nothing"
    [[ -z "$raw" ]] || said="\"${raw:0:60}\""
    echo "Could not read the installed jus version (\`jus version\` printed ${said}). This plugin needs jus ${floor} or newer; if yours is older, run: brew upgrade jus"
    return 0
  fi

  juscribe_sop_version_older "$have" "$floor" || return 0
  echo "jus ${have} is installed, and this plugin needs jus ${floor} or newer. Run: brew upgrade jus — until then, parts of it can fail with \`Usage: jus <command>\` and enforce nothing."
}
