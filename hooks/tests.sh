#!/usr/bin/env bash
# Test harness for the jus hooks.
#
# Each test pipes a synthetic Claude Code hook input JSON to the script under
# test and asserts on (a) exit code and (b) stdout/stderr contents. Run via:
#
#   ./jus/hooks/tests.sh
#
# Exits 0 on success, 1 on any failure.

set -uo pipefail

# Belt-and-suspenders (#2290): this harness spawns nested git repos. When run
# from a git hook, the exported GIT_DIR/GIT_INDEX_FILE would make those
# nested commands operate on the REAL repository — a stray `git init` here
# once re-initialized the shared .git as bare, breaking every checkout. The
# lefthook entry strips the env too; this protects every other invocation.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_ALTERNATE_OBJECT_DIRECTORIES

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HOOKS_DIR/scripts"

# The literal string hooks.json uses to reference bundled scripts. The tilde is
# text to be matched, not a path to expand, so it is escaped rather than quoted:
# escaping says "this character is literal", while quoting it reads as a home
# directory someone forgot to expand (#2077).
SKILLS_PREFIX=\~/.jus-skills/

TESTS_RUN=0
TESTS_FAILED=0
FAILURES=()

# ⚠️ THE GUARD IS OFF FOR THE WHOLE SUITE, ON PURPOSE (#4404). Every hook now
# no-ops outside a Juscribe project, and most tests below drive them against a
# `mktemp -d` repo that has no `.jus/` — so without this every one of them
# would pass by doing nothing, which is the worst possible way for a suite to
# be green. The guard gets its own section at the bottom, which unsets this.
JUS_HOOKS_EVERYWHERE=1
export JUS_HOOKS_EVERYWHERE

# Isolated state directory so tests don't pollute real plugin data.
CLAUDE_PLUGIN_DATA=$(mktemp -d)
export CLAUDE_PLUGIN_DATA

# ---- the undefined-helper guard (#4462) ------------------------------------
#
# ⚠️ THIS HARNESS RUNS UNDER `set -uo pipefail` WITH NO `-e`, DELIBERATELY:
# an assertion is expected to fail without aborting the run. The cost is that a
# call to a helper that does not EXIST is just a `command not found` on stderr,
# exit 127, walked straight past — TESTS_RUN never increments, FAILURES never
# grows, the summary stays green. #4431 found fifteen such calls that had
# asserted nothing for eight days, across three sections.
#
# So stderr is captured for the whole run and scanned by `print_summary`. The
# per-assertion ✓/✗ lines are stdout and keep streaming live; the captured
# stderr is replayed by the EXIT trap, so it survives an early abort too.
#
# ⚠️ NOT `command_not_found_handle`, which is the obvious mechanism and the
# wrong one here: it is bash 4.0+, and the Mac whose lefthook entry runs this
# suite is bash 3.2.57 (`.jus/docs/shell-portability.md`). That handler would
# never be called on the one machine carrying a commit gate — a guard silently
# inert on exactly what it guards, which is this ticket's own bug in a new hat.
STDERR_LOG=$(mktemp)
exec 3>&2
exec 2>"$STDERR_LOG"

harness_cleanup() {
  exec 2>&3
  if [[ -s "$STDERR_LOG" ]]; then
    printf '\n\033[2m--- stderr captured during this run ---\033[0m\n' >&2
    cat "$STDERR_LOG" >&2
  fi
  rm -rf "$CLAUDE_PLUGIN_DATA" "$STDERR_LOG"
}
trap harness_cleanup EXIT

# ---- helpers ---------------------------------------------------------------

# ⚠️ THESE THREE LIVED AT LINE ~1250 UNTIL #3507, WHICH IS WHY THEY MOVED.
# bash resolves a function at call time, so a test block placed ABOVE the
# definition died with "assert_no_nudge: command not found" — and, because the
# harness only tallies what an assert_* helper reports, that test simply did not
# exist. Three no-fire assertions read as passing while asserting nothing.
# Helpers belong here, with the others.
# Assert a hook produces NO systemMessage (a quiet/no-op nudge) and exits 0.
assert_no_nudge() { # <script> <input_json>
  TESTS_RUN=$((TESTS_RUN + 1))
  local out ec; out=$(printf '%s' "$2" | "$1" 2>&1); ec=$?
  if [[ $ec -eq 0 && "$out" != *systemMessage* ]]; then
    printf '  \033[32m✓\033[0m %s\n' "${TEST_NAME:-test}"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("${TEST_NAME:-test}")
    printf '  \033[31m✗\033[0m %s (exit=%s, out=%s)\n' "${TEST_NAME:-test}" "$ec" "${out:0:160}"
  fi
}
# Assert a state file equals an expected value.
assert_state_eq() { # <file> <expected>
  TESTS_RUN=$((TESTS_RUN + 1))
  local got; got=$(cat "$1" 2>/dev/null || echo "__missing__")
  if [[ "$got" == "$2" ]]; then printf '  \033[32m✓\033[0m %s\n' "${TEST_NAME:-test}"
  else TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("${TEST_NAME:-test}"); printf '  \033[31m✗\033[0m %s (want=%s got=%s)\n' "${TEST_NAME:-test}" "$2" "$got"; fi
}
# Assert a state file is absent.
assert_state_absent() { # <file>
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ ! -e "$1" ]]; then printf '  \033[32m✓\033[0m %s\n' "${TEST_NAME:-test}"
  else TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("${TEST_NAME:-test}"); printf '  \033[31m✗\033[0m %s (exists)\n' "${TEST_NAME:-test}"; fi
}

# assert_reaches_agent <name> <hook_output>
#
# #3498. A nudge that emits only `systemMessage` is rendered in the terminal and
# NOWHERE ELSE — the attachment map that builds the model's prompt carries
# `hook_additional_context` and has no entry for `hook_system_message`. So a hook
# meant to change what the agent does must emit BOTH, and this asserts both.
#
# ⚠️ Asserts the terminal half too, deliberately. The fix is additive: the user
# keeps seeing the message. A future edit that "simplifies" by dropping
# `systemMessage` would otherwise pass.
# <event> defaults to PostToolUse, which is what every caller wanted until
# #3674 added a UserPromptSubmit hook. `hookEventName` must match the event the
# hook actually fires on — a mismatch is not cosmetic, it is how the harness
# decides whether the output is reachable at all.
assert_reaches_agent() { # <name> <hook_output> [<event>]
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1" out="$2" event="${3:-PostToolUse}" missing=""
  jq -e '.systemMessage | type == "string" and length > 0' >/dev/null 2>&1 <<<"$out" \
    || missing="systemMessage"
  jq -e --arg e "$event" '.hookSpecificOutput.hookEventName == $e' >/dev/null 2>&1 <<<"$out" \
    || missing="${missing:+$missing, }hookSpecificOutput.hookEventName"
  jq -e '.hookSpecificOutput.additionalContext | type == "string" and length > 0' >/dev/null 2>&1 <<<"$out" \
    || missing="${missing:+$missing, }hookSpecificOutput.additionalContext"
  if [[ -z "$missing" ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m✗\033[0m %s (missing: %s)\n' "$name" "$missing"
  fi
}

# assert_exit <expected_code> <script> <input_json> [<must_contain>]
assert_exit() {
  local expected="$1" script="$2" input="$3" must_contain="${4:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  local stdout stderr actual=0
  local out_file err_file
  out_file=$(mktemp)
  err_file=$(mktemp)
  printf '%s' "$input" | "$script" >"$out_file" 2>"$err_file" || actual=$?
  stdout=$(cat "$out_file")
  stderr=$(cat "$err_file")
  rm -f "$out_file" "$err_file"

  local pass=1
  if [[ "$actual" != "$expected" ]]; then
    pass=0
  fi
  if [[ -n "$must_contain" && "$stderr$stdout" != *"$must_contain"* ]]; then
    pass=0
  fi

  if (( pass )); then
    printf '  \033[32m✓\033[0m %s\n' "${TEST_NAME:-test}"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("${TEST_NAME:-test}")
    printf '  \033[31m✗\033[0m %s\n' "${TEST_NAME:-test}"
    printf '      expected exit=%s, got=%s\n' "$expected" "$actual"
    if [[ -n "$must_contain" && "$stderr$stdout" != *"$must_contain"* ]]; then
      printf '      expected output to contain: %s\n' "$must_contain"
    fi
    printf '      stderr: %s\n' "${stderr:0:400}"
    printf '      stdout: %s\n' "${stdout:0:400}"
  fi
}

t() { TEST_NAME="$1"; }

# ⚠️ RESTORED (#4431). These two were deleted along with the dirty-tree nudge in
# a9dc2c27 (#3952) while fifteen of their CALLERS stayed. The harness runs under
# `set -uo pipefail` with no `-e`, so each call was a `command not found` on
# stderr, exit 127, carried straight past: `TESTS_RUN` never incremented, no
# failure recorded, suite green. Fifteen assertions across the docs-nudge, stop
# and worktree-lock sections asserted nothing for eight days, including the two
# this ticket's own criteria rest on.
assert_stdout() { # <name> <wanted, or "" for no output at all> <got>
  local name="$1" want="$2" got="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  local ok=0
  if [[ -z "$want" ]]; then
    [[ -z "$got" ]] && ok=1
  elif [[ "$got" == *"$want"* ]]; then
    ok=1
  fi
  if (( ok )); then
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$name")
    printf '  \033[31m✗\033[0m %s\n' "$name"
    printf '      wanted: %s\n' "${want:-<no output>}"
    printf '      got:    %s\n' "${got:0:300}"
  fi
}

# The mirror of assert_stdout, and #3393 is why it exists: that change is
# defined by what the message leaves OUT. An INDEX hint truncated to its first
# clause still CONTAINS that clause when the truncation silently does nothing,
# so every positive assertion passes over a message running to 457 characters.
assert_stdout_lacks() { # <name> <unwanted> <got>
  local name="$1" unwanted="$2" got="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$got" != *"$unwanted"* ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$name")
    printf '  \033[31m✗\033[0m %s\n' "$name"
    printf '      unwanted: %s\n' "$unwanted"
    printf '      got:      %s\n' "${got:0:300}"
  fi
}


# Assert a per-session state file is present or absent. Lives up here with the
# other helpers because sections from the gate onward use it, and a function
# defined further down is simply not in scope yet — a silent 127, not an error.
assert_state_file() { # <path> <present|absent>
  local file="$1" want="$2" have
  if [[ -f "$file" ]]; then have=present; else have=absent; fi
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$have" == "$want" ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s (%s: %s, wanted %s)\n' "$TEST_NAME" "$(basename "$file")" "$have" "$want"
  fi
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

# undefined_commands <stderr_log>
#
# One line per distinct command bash could not find, as "<count> <name>"; empty
# output means clean. This is what turns #4431's silent 127 into something the
# summary can count and name.
#
# ⚠️ ENUMERATED, NOT ASSUMED — which is why there is no allowlist here.
# Measured: a full run of this suite writes ZERO bytes to its own stderr,
# because every test captures its subject's output with `2>&1` into a variable.
# And every deliberate probe for an absent binary goes through `command -v`
# (jq in the pickup/nojus/index stubs, shellcheck in the sh-lint section, and
# the jq-sandbox loop) — a builtin that reports absence as an exit status and
# prints nothing at all. The guard section at the bottom holds both halves of
# that claim as tests, so a future probe that DOES write there turns this red
# rather than quietly widening what the scanner ignores.
undefined_commands() { # <stderr_log>
  sed -n 's/.*: \([^:]*\): command not found$/\1/p' "$1" | sort | uniq -c
}

# print_summary
#
# The end of the run: fold any undefined commands into the tally, print the
# counts, list the failures, exit. A function rather than the file's tail so the
# hatch below can reach the REAL summary without running every test first.
print_summary() {
  local count name f
  while read -r count name; do
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("undefined command: $name (called $count time(s), defined nowhere)")
    printf '  \033[31m✗\033[0m undefined command: %s (called %s time(s), defined nowhere)\n' \
      "$name" "$count"
  done < <(undefined_commands "$STDERR_LOG")

  printf '\n%d tests run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
  if (( TESTS_FAILED > 0 )); then
    printf '\nFailures:\n'
    for f in "${FAILURES[@]}"; do
      printf '  - %s\n' "$f"
    done
    exit 1
  fi
  exit 0
}

# ⚠️ THE SELF-CHECK HATCH. Set JUS_TESTS_SELFCHECK to the name of a command
# that does not exist and this file calls it, then goes straight to the real
# summary — which is how the suite proves, end to end and through this very
# file, that an undefined helper turns the run red and gets named. Its only
# caller is the "undefined-helper guard" section at the bottom. It exits before
# a single test runs, so that child costs one bash startup rather than a second
# full suite.
if [[ -n "${JUS_TESTS_SELFCHECK:-}" ]]; then
  "$JUS_TESTS_SELFCHECK"
  print_summary
fi

# ---- jus-block-accepted-manifest-edit.sh ---------------------------------------

section "jus-block-accepted-manifest-edit.sh"

# ⚠️ These use a STUB `jus` on PATH rather than the real API: a hook test that
# depends on a live ticket's state would change meaning the day that ticket is
# accepted, and would fail offline. The stub also pins the parsing gotcha —
# `jus api` prints an "HTTP 200" line BEFORE the JSON, and piping that straight
# into jq silently emptied the state, which (because this hook fails open)
# turned the whole guard into a no-op.
STUBDIR=$(mktemp -d)
stub_jus() {
  cat > "$STUBDIR/jus" <<STUB
#!/usr/bin/env bash
echo "HTTP 200"
echo '{"ticket":{"state":"$1","id":"999"}}'
STUB
  chmod +x "$STUBDIR/jus"
}
PATH="$STUBDIR:$PATH"
export PATH

stub_jus accepted
t "blocks a description PATCH on an accepted ticket"
assert_exit 2 "$SCRIPTS/jus-block-accepted-manifest-edit.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"jus api PATCH /workspaces/1/tickets/999 \"{\\\"ticket\\\":{\\\"description\\\":\\\"x\\\"}}\""}}' \
  "accepted"

t "never blocks a comment, which is the sanctioned correction path"
assert_exit 0 "$SCRIPTS/jus-block-accepted-manifest-edit.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"jus api POST /workspaces/1/tickets/999/comments \"{}\""}}'

t "allows a transition on an accepted ticket (sub-resource, not a rewrite)"
assert_exit 0 "$SCRIPTS/jus-block-accepted-manifest-edit.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"jus api PATCH /workspaces/1/tickets/999/transition \"{}\""}}'

t "allows a non-description PATCH on an accepted ticket"
assert_exit 0 "$SCRIPTS/jus-block-accepted-manifest-edit.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"jus api PATCH /workspaces/1/tickets/999 \"{\\\"ticket\\\":{\\\"label_ids\\\":[1]}}\""}}'

stub_jus prioritized
t "allows a description PATCH on an open ticket"
assert_exit 0 "$SCRIPTS/jus-block-accepted-manifest-edit.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"jus api PATCH /workspaces/1/tickets/999 \"{\\\"ticket\\\":{\\\"description\\\":\\\"x\\\"}}\""}}'

t "ignores unrelated bash commands"
assert_exit 0 "$SCRIPTS/jus-block-accepted-manifest-edit.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

# ---- jus-block-force-push.sh ---------------------------------------------------

section "jus-block-force-push.sh"

# #4446 — the shared git matcher anchored `git` at the head of the segment, so a
# runner prefix meant no match at all. This guard never blocked
# `sudo git push --force`; it does now, via the same one-line fix.
t "blocks a runner-prefixed force push (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"sudo git push --force"}}'

t "allows plain git push"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'

t "blocks git push --force"
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' \
  "force-push"

t "blocks git push -f"
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git push -f origin main"}}' \
  "force-push"

t "blocks git push --force-with-lease"
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease origin main"}}' \
  "force-push"

t "ignores non-Bash tool"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/x","old_string":"--force","new_string":""}}'

t "ignores commands that aren't git push"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"echo --force"}}'

t "ignores rebase --force-rebase (different command)"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git rebase main"}}'

# #1985 — referencing the blocker or quoting the rule must not block. The force
# tokens must be argument words of an actual `git push` segment, not substrings
# anywhere in the command string (quoted JSON/prose, other commands' flags).

t "allows referencing the script + quoting the rule in a jus comment (#1985 incident)"
cmd="grep -n force jus/hooks/scripts/jus-block-force-push.sh && jus api POST /workspaces/1/tickets/1976/comments '{\"comment\":{\"body\":\"Port the git push --force blocker\"}}'"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"

t "allows quoted-docs echo about the force-push rule (#1985)"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"echo \"The SOP forbids git push --force; the stakeholder pushes manually\""}}'

t "allows cat of the blocker script (#1985)"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"cat jus/hooks/scripts/jus-block-force-push.sh"}}'

t "allows plain push chained after rm -f (#1985 — flag belongs to another command)"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"rm -f tmp.txt && git push origin main"}}'

t "allows a multiline quoted body that quotes the rule (#1985)"
cmd=$'jus api POST /workspaces/1/tickets/1985/comments \'{"comment":{"body":"Rule:\ngit push --force is forbidden"}}\''
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"

t "still blocks chained git push --force"
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git add . && git push --force"}}' \
  "force-push"

t "still blocks env-prefixed force push"
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"GIT_TRACE=1 git push -f"}}' \
  "force-push"

t "blocks git -C <path> push --force (global options before the subcommand)"
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git -C /tmp/repo push --force"}}' \
  "force-push"

t "still blocks force push on a later line of a multiline command"
cmd=$'echo preparing\ngit push --force'
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')" \
  "force-push"

# ---- jus-block-no-verify.sh ----------------------------------------------------

section "jus-block-no-verify.sh"

t "blocks git commit --no-verify"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo --no-verify"}}' \
  "no-verify"

t "blocks git push --no-verify"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git push --no-verify"}}' \
  "no-verify"

t "allows commit without --no-verify"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'

t "doesn't trip on --no-verify-something else"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"echo --no-verify-tags"}}'

# #1985 — same anchoring as the force-push blocker: `--no-verify` must be an
# argument word of an actual git segment, not a substring anywhere.

t "allows a jus comment body that quotes the --no-verify rule (#1985)"
cmd="jus api POST /workspaces/1/tickets/1985/comments '{\"comment\":{\"body\":\"never use --no-verify when committing\"}}'"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"

t "allows echo quoting the --no-verify rule (#1985)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"echo \"the SOP forbids --no-verify everywhere\""}}'

t "allows grep for --no-verify in the hook source (#1985)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"grep -n -- --no-verify jus/hooks/scripts/jus-block-no-verify.sh"}}'

t "allows a commit message that mentions --no-verify (#1985)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"forbid --no-verify in hooks\""}}'

t "still blocks chained commit --no-verify"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git add . && git commit -m x --no-verify"}}' \
  "no-verify"

# #4446 — the guard knew ONE spelling. Every hook runner the bundle plausibly
# meets has an environment variable that skips the same checks, and git's own
# short form `-n` needs no runner at all.
#
# ⚠️ THE SHORT FORM IS THE SHARPEST ONE. It is git's documented spelling of
# `--no-verify`, and the refusal text named only the long form — so a reader had
# no reason to think they differed.

t "blocks git commit -n (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -n -m foo"}}' \
  'BLOCKED: `-n` skips'

t "blocks git commit -n bundled with other short flags (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -nm foo"}}' \
  'BLOCKED: `-nm` skips'

# ⚠️ `-n` MEANS SOMETHING ELSE ON EVERY OTHER SUBCOMMAND, which is why it is
# matched on `commit` alone: --dry-run on push and clean, --no-stat on merge,
# and a commit count on log. Blocking those would be a guard people disable.

t "allows git push -n, which is --dry-run (#4446)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git push -n origin main"}}'

t "allows git clean -n, which is --dry-run (#4446)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git clean -n -d"}}'

t "allows git log -n 5, which is a count (#4446)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git log -n 5 --oneline"}}'

# The runner variables. Each is the documented skip switch of a hook runner the
# bundle can meet, read from that runner's own docs rather than from a list.

t "blocks HUSKY=0 on a commit (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"HUSKY=0 git commit -m foo"}}' \
  'BLOCKED: `HUSKY=0` skips'

t "blocks LEFTHOOK=0 on a commit (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"LEFTHOOK=0 git commit -m foo"}}' \
  'BLOCKED: `LEFTHOOK=0` skips'

# The shape dispatch 680 actually used, on #4283 — the measurement that filed
# this ticket. It was refused by the pre-commit gate for an unrelated reason;
# this hook said nothing.
t "blocks LEFTHOOK_EXCLUDE on a commit (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"LEFTHOOK_EXCLUDE=rubocop,reek git commit -F /tmp/msg.txt"}}' \
  'BLOCKED: `LEFTHOOK_EXCLUDE=rubocop,reek` skips'

t "blocks SKIP on a commit (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"SKIP=flake8 git commit -m foo"}}' \
  'BLOCKED: `SKIP=flake8` skips'

t "blocks PRE_COMMIT_ALLOW_NO_CONFIG on a commit (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"PRE_COMMIT_ALLOW_NO_CONFIG=1 git commit -m foo"}}' \
  'BLOCKED: `PRE_COMMIT_ALLOW_NO_CONFIG=1` skips'

t "blocks a runner variable on a push (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"LEFTHOOK=0 git push"}}' \
  'BLOCKED: `LEFTHOOK=0` skips'

# ⚠️ THE FALSE POSITIVES ARE THE REASON THE VARIABLES ARE NAMED RATHER THAN
# PATTERN-MATCHED. "Any VAR=value prefix on a git command" would refuse both of
# these, and a guard that refuses ordinary work is one people turn off.

t "allows CI=true on a commit (#4446)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"CI=true git commit -m foo"}}'

t "allows GIT_AUTHOR_DATE on a commit (#4446)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"GIT_AUTHOR_DATE=2026-01-01T00:00:00Z git commit -m foo"}}'

t "allows a non-disabling HUSKY value, which is debug mode (#4446)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"HUSKY=2 git commit -m foo"}}'

# ⚠️ A RUNNER VARIABLE OUTSIDE A GIT SEGMENT IS NOT A BYPASS. Running the hook
# runner itself, or exporting the variable for a non-git command, is ordinary.
t "allows SKIP on something that is not git (#4446)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"SKIP=flake8 pre-commit run --all-files"}}'

# The refusal has to say WHICH bypass it saw, or the reader checks their command
# for a `--no-verify` they never typed.
#
# ⚠️ ASSERTED ON THE HEADLINE, NOT THE TOKEN, and the difference is the whole
# test. The refusal BODY lists every bypass by name so the reader learns the
# class — so `"HUSKY=0"` appears in the output even when the headline says
# `--no-verify`. Mutation-checked: hardcoding the old headline SURVIVED the
# first version of this test, which asserted the bare token.
t "names the bypass it saw rather than always saying --no-verify (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"HUSKY=0 git commit -m foo"}}' \
  'BLOCKED: `HUSKY=0` skips'

# ⚠️ WIDENING THE MATCHER MADE HEREDOC STRIPPING NECESSARY (#4446, #3921 is the
# precedent). The splitter turns every newline into a separator, so a heredoc
# body line beginning `LEFTHOOK_EXCLUDE=… git commit` is a segment anchored at
# column 0 — and the SOP mandates writing board prose through `<<'EOF'`, so a
# comment DESCRIBING a bypass is the normal shape. #4446's own description
# contains that exact line; without stripping, filing this ticket would have
# been refused by the guard it was filing against.
t "allows a heredoc body that quotes a runner bypass (#4446)"
cmd=$'jus api POST /workspaces/1/tickets/4446/comments <<\'EOF\'\nLEFTHOOK_EXCLUDE=rubocop,reek git commit -F /tmp/msg.txt\nEOF'
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"

# ⚠️ MATCHING A BARE `-n` IS ONLY SAFE BECAUSE QUOTED STRINGS ARE REMOVED by the
# splitter before this hook sees the segment. If that ever changes, this is the
# test that says so rather than a commit message being refused in the field.
t "allows a commit message containing -n (#4446)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"fix the -n flag handling\""}}'

# ⚠️ A RUNNER PREFIX WAS A ONE-WORD BYPASS OF EVERY GUARD (#4446). The git
# matcher anchored `git` at the head of the segment, so `env` or `sudo` in front
# meant NO match rather than a weaker one. Measured against the pre-#4446
# scripts: `env git commit --no-verify` and `sudo git push --no-verify` both
# returned exit 0. The fix is in `juscribe_sop_segment_invokes_git`, so the
# force-push guard gains it too — see its own section below.

t "blocks env-prefixed --no-verify (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"env git commit --no-verify"}}' \
  'BLOCKED: `--no-verify` skips'

t "blocks sudo-prefixed --no-verify (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"sudo git push --no-verify"}}' \
  'BLOCKED: `--no-verify` skips'

t "blocks a runner variable behind env (#4446)"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"env HUSKY=0 git commit -m x"}}' \
  'BLOCKED: `HUSKY=0` skips'

# ⚠️ `command -v git` MUST NOT READ AS A GIT INVOCATION. It is how a script asks
# whether git is installed, and counting it would have the guards firing on a
# probe. It is safe because the pattern requires a subcommand after `git`.
t "allows command -v git, which is a probe (#4446)"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"command -v git"}}'

# ---- jus-block-lint-suppression.sh --------------------------------------------

section "jus-block-lint-suppression.sh"

t "blocks new # rubocop:disable line"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/x.rb","old_string":"def foo\n  bar\nend","new_string":"def foo\n  bar # rubocop:disable Lint/Foo\nend"}}' \
  "rubocop:disable"

t "blocks new // eslint-disable-next-line"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/x.ts","old_string":"const x = 1;","new_string":"// eslint-disable-next-line\nconst x = 1;"}}' \
  "eslint-disable"

t "blocks new @ts-ignore"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/x.ts","old_string":"foo()","new_string":"// @ts-ignore\nfoo()"}}' \
  "@ts-ignore"

t "blocks new :reek: comment"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/x.rb","old_string":"def foo\nend","new_string":"# :reek:TooManyMethods\ndef foo\nend"}}' \
  ":reek:"

t "allows edit that REMOVES a suppression"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/x.rb","old_string":"# rubocop:disable Foo\nfoo","new_string":"foo"}}'

t "allows edit that keeps the same suppression count"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/x.rb","old_string":"# rubocop:disable Foo\nfoo","new_string":"# rubocop:disable Foo\nbar"}}'

t "blocks Write that introduces eslint-disable"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":"/x.ts","content":"// eslint-disable-next-line\nfoo()"}}' \
  "eslint-disable"

t "allows Write with no suppression"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":"/x.ts","content":"export const x = 1;"}}'

t "ignores non-Edit tool"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Bash","tool_input":{"command":"echo // eslint-disable"}}'

# #1985 — a suppression token is only a suppression in a file its linter reads.
# Quoting one in docs or a shell test fixture suppresses nothing and must not
# block. (Writing THESE fixtures via the editor was itself blocked by the
# pre-#1985 hook — the bug demonstrated on its own test harness.)

t "allows a docs (.md) edit that quotes a suppression token (#1985)"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/repo/.jus/docs/linting.md","old_string":"## Lint rules","new_string":"## Lint rules\nNever add # rubocop:disable comments."}}'

t "allows a shell test-harness edit that quotes a suppression token (#1985)"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/repo/jus/hooks/tests.sh","old_string":"x","new_string":"x // eslint-disable-next-line"}}'

t "allows a ruby suppression token quoted in a TypeScript string (#1985)"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":"/repo/app/frontend/lib/rules.ts","content":"export const RULE = \"no # rubocop:disable\";"}}'

t "blocks a suppression added to an extensionless ruby file (Gemfile)"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/repo/Gemfile","old_string":"gem \"pg\"","new_string":"gem \"pg\" # rubocop:disable Bundler/OrderedGems"}}' \
  "rubocop:disable"

t "blocks a suppression when file_path is missing (fail closed)"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Write","tool_input":{"content":"// eslint-disable-next-line\nfoo()"}}' \
  "eslint-disable"

t "still blocks @ts-nocheck in a .tsx file"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":"/repo/app/frontend/components/X.tsx","content":"// @ts-nocheck\nexport {}"}}' \
  "@ts-nocheck"

# #4347 — `shellcheck disable` joined the table, and it is the one directive that
# cannot be typed by extension: most shell scripts are extensionless (bin/ci,
# script/dev/gate), so they type as `ci` and `gate`. A shell SHEBANG resolves the
# type to `sh`, and these three pin both halves of that rule.

t "blocks a new shellcheck disable in a .sh file (#4347)"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":"/repo/script/x.sh","content":"#!/usr/bin/env bash\n# shellcheck disable=SC2086\necho $x"}}' \
  "shellcheck disable"

t "blocks one in an EXTENSIONLESS script, typed by its shebang (#4347)"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":"/repo/bin/ci","content":"#!/usr/bin/env bash\n# shellcheck disable=SC2086\necho $x"}}' \
  "shellcheck disable"

t "allows a shellcheck directive that is not a disable (#4347)"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Write","tool_input":{"file_path":"/repo/script/x.sh","content":"#!/usr/bin/env bash\n# shellcheck source=lib/state.sh\nsource lib/state.sh"}}'

t "allows a shellcheck disable quoted in a markdown doc (#1985, #4347)"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/repo/.jus/docs/linting.md","old_string":"## Rules","new_string":"## Rules\nNever add # shellcheck disable=SC2086."}}'

# ---- jus-pre-commit-gate.sh + tracking ----------------------------------------

section "jus-pre-commit-gate.sh + tracking"

# ⚠️ NOTHING HERE PAUSES BETWEEN AN EDIT AND A LINT, and it used to (#2807).
# Five `sleep 1` calls cost 5s of every run — most of the suite's wall clock —
# on the belief that the gate needed `last_linted_at > last_modified_at` and
# that two `date +%s` stamps in the same second would therefore race.
#
# The gate compares `>=` (jus-pre-commit-gate.sh), and so does the nudge
# inverted, so a same-second edit and lint is ALLOWED and there was never a
# race. Measured: deleting the five and changing nothing else gave 172 tests, 0
# failed, 7.4s -> 2.3s. This section is 2.4s now, with six more tests.
#
# What the pauses did hide is that the ordering itself was never asserted. The
# pair of tests further down this section — "blocks when the last lint predates
# the last edit" and "allows when the lint landed in the same second" — pin it
# against stamps written by hand, the idiom the nudge section already uses, so
# `>=` is a stated expectation rather than an accident four end-to-end tests
# silently depend on.

# Use a fresh session id per scenario for isolation
SID_CLEAN="test-clean-$$"
SID_EDITED="test-edited-$$"
SID_LINTED="test-linted-$$"
SID_DOCS="test-docs-$$"

t "allows git commit when no edits tracked"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_CLEAN\"}"

# The comparison itself, with the stamps written directly so no clock is
# involved. `linted_at < modified_at` is the state the gate exists to catch —
# edits made since the last lint — and until #2807 the only coverage of that
# comparison lived in the dirty-tree nudge's tests, removed with the hook in
# #3952. The gate's own side was covered solely by sessions that had never
# linted at all, which is a different branch.
SID_STALE="test-stale-lint-$$"
mkdir -p "$CLAUDE_PLUGIN_DATA/sessions/$SID_STALE"
echo "/repo/foo.rb" > "$CLAUDE_PLUGIN_DATA/sessions/$SID_STALE/edits.log"
echo 300 > "$CLAUDE_PLUGIN_DATA/sessions/$SID_STALE/last_modified_at"
echo 200 > "$CLAUDE_PLUGIN_DATA/sessions/$SID_STALE/last_linted_at"

t "blocks when the last lint predates the last edit (#2807)"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_STALE\"}" \
  "linters have not been run"

# ⚠️ THE BOUNDARY, and the reason this file no longer sleeps. `date +%s` has
# one-second resolution, so an edit and a lint in the same second produce EQUAL
# stamps — the case every end-to-end test below now exercises. `>=` allows it;
# a change to `>` would make those four fail for a reason none of them names,
# so the equality is asserted here on its own.
echo 300 > "$CLAUDE_PLUGIN_DATA/sessions/$SID_STALE/last_linted_at"

t "allows when the lint landed in the same second as the edit (#2807)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_STALE\"}"

# Simulate an Edit on a Ruby file
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/foo.rb","old_string":"a","new_string":"b"},"session_id":"%s"}' "$SID_EDITED" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null

t "blocks git commit after a code edit, no lint"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_EDITED\"}" \
  "linters have not been run"

t "blocks git -C <path> commit — a global option must not bypass the gate (#2363)"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C . commit -m x\"},\"session_id\":\"$SID_EDITED\"}" \
  "linters have not been run"

t "blocks git -c k=v commit (#2363)"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -c core.editor=true commit -m x\"},\"session_id\":\"$SID_EDITED\"}" \
  "linters have not been run"

t "blocks an env-prefixed commit (#2363)"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"GIT_AUTHOR_NAME=x git commit -m y\"},\"session_id\":\"$SID_EDITED\"}" \
  "linters have not been run"

t "still does not treat git commit-tree as a commit (#2363)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit-tree abc123\"},\"session_id\":\"$SID_EDITED\"}"

t "still does not treat git -C . commit-tree as a commit (#2363)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C . commit-tree abc123\"},\"session_id\":\"$SID_EDITED\"}"

t "allows git commit when the command itself runs a linter"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bin/rubocop foo.rb && git commit -m x\"},\"session_id\":\"$SID_EDITED\"}"

# Simulate edit then lint
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/foo.rb","old_string":"a","new_string":"b"},"session_id":"%s"}' "$SID_LINTED" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null
printf '{"tool_name":"Bash","tool_input":{"command":"bin/rubocop foo.rb"},"tool_response":{"interrupted":false},"session_id":"%s"}' "$SID_LINTED" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "allows git commit after lints have run"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_LINTED\"}"

# After successful commit, edit tracking should reset. The tracker verifies
# resolution against git (#2355), so hand it a clean repo as cwd: the tracked
# /repo/foo.rb is not in its dirty set, which reads as resolved.
GATE_CLEAN_REPO=$(mktemp -d)
( cd "$GATE_CLEAN_REPO" && git init -q && git config user.email t@t && git config user.name t \
  && touch seed && git add seed && git commit -q -m init )
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s","cwd":"%s"}' "$SID_LINTED" "$GATE_CLEAN_REPO" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null
rm -rf "$GATE_CLEAN_REPO"

# ⚠️ THE EXIT-0 ASSERTION BELOW DOES NOT COVER THE CLEARING, which is why the
# two state-file assertions are here (#2807). This session has a lint recorded,
# so the gate allows the commit at its "lints ran after the last edit" step
# whether or not the tracker cleared anything at all. Measured: disabling the
# tracker's entire commit branch failed ZERO tests, before this change and
# after it — the sleeps were never what covered this.
#
# Clearing is a property of the tracker, so assert it on the tracker's output
# rather than through a second consumer that has its own reason to say yes.
t "a plain git commit clears last_modified_at (#2807)"
assert_state_file "$CLAUDE_PLUGIN_DATA/sessions/$SID_LINTED/last_modified_at" absent

t "a plain git commit clears edits.log (#2807)"
assert_state_file "$CLAUDE_PLUGIN_DATA/sessions/$SID_LINTED/edits.log" absent

t "allows git commit with no edits after a prior commit cleared state"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_LINTED\"}"

# The tracker's commit branch must fire for the -C/-c forms too (#2363). Both
# callers share juscribe_sop_is_git_commit, but "shared helper" is an inference
# and this is a test.
SID_DASHC="dashc-$$"
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/foo.rb","old_string":"a","new_string":"b"},"session_id":"%s"}' "$SID_DASHC" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null
printf '{"tool_name":"Bash","tool_input":{"command":"bin/rubocop foo.rb"},"tool_response":{"interrupted":false},"session_id":"%s"}' "$SID_DASHC" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null
DASHC_REPO=$(mktemp -d)
( cd "$DASHC_REPO" && git init -q && git config user.email t@t && git config user.name t \
  && touch seed && git add seed && git commit -q -m init )
printf '{"tool_name":"Bash","tool_input":{"command":"git -C . commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s","cwd":"%s"}' "$SID_DASHC" "$DASHC_REPO" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null
rm -rf "$DASHC_REPO"

# Same trap as above: the -C form's clearing needs asserting on the state files,
# not inferred from a gate that would allow this commit regardless (#2807).
t "git -C <path> commit clears last_modified_at, same as a plain one (#2363)"
assert_state_file "$CLAUDE_PLUGIN_DATA/sessions/$SID_DASHC/last_modified_at" absent

t "git -C <path> commit clears edits.log, same as a plain one (#2363)"
assert_state_file "$CLAUDE_PLUGIN_DATA/sessions/$SID_DASHC/edits.log" absent

t "tracker clears state for a git -C <path> commit, same as a plain one (#2363)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_DASHC\"}"

# A commit named inside a HEREDOC BODY is prose, and until #3921 both consumers
# of juscribe_sop_is_git_commit read the RAW command string. The segment
# splitter turns every newline into a separator, so a body line beginning with
# the invocation is a segment anchored at column 0 and matched — anchoring alone
# never saved it, which the stripper's own header has said since #2363 about the
# other checks. Two costs, and the second is the corrosive one: the gate refused
# the prose, and the tracker cleared last_modified_at, which disarms the gate for
# the real commit that follows. The SOP mandates writing prose through quoted
# heredocs, so this is the normal shape here rather than an exotic one.
SID_HEREDOC="heredoc-commit-$$"
HEREDOC_CMD="cat <<'EOF' > note.md\\ngit commit is what finishes a conflicted merge\\nEOF"
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/foo.rb","old_string":"a","new_string":"b"},"session_id":"%s"}' "$SID_HEREDOC" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null

t "does not read a commit named inside a heredoc as one (#3921)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$HEREDOC_CMD\"},\"session_id\":\"$SID_HEREDOC\"}"

printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"interrupted":false},"session_id":"%s"}' "$HEREDOC_CMD" "$SID_HEREDOC" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

# The clearing is what makes the false positive dangerous, so assert it on the
# state file rather than inferring it from the gate below (#2807).
t "leaves last_modified_at alone for a heredoc that merely mentions one (#3921)"
assert_state_file "$CLAUDE_PLUGIN_DATA/sessions/$SID_HEREDOC/last_modified_at" present

t "still blocks the real commit that follows the heredoc (#3921)"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_HEREDOC\"}" \
  "linters have not been run"

# Doc-only edits → no lint required
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/README.md","old_string":"a","new_string":"b"},"session_id":"%s"}' "$SID_DOCS" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null

t "allows git commit when only doc files were edited"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_DOCS\"}"

t "ignores non-commit Bash commands"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"session_id\":\"$SID_EDITED\"}"

# An interrupted command must NOT count as a lint run. `interrupted` is the only
# completion signal the Bash tool_response exposes (there is no exit_code), so a
# cancelled lint must leave last_linted_at unset and the gate must still block.
SID_INTR="test-interrupted-lint-$$"
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/foo.rb","old_string":"a","new_string":"b"},"session_id":"%s"}' "$SID_INTR" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null
printf '{"tool_name":"Bash","tool_input":{"command":"bin/rubocop foo.rb"},"tool_response":{"interrupted":true},"session_id":"%s"}' "$SID_INTR" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "still blocks commit when the lint command was interrupted"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_INTR\"}" \
  "linters have not been run"

# Real Claude Code Bash tool_response has NO exit_code field (only stdout/
# stderr/interrupted/isImage). The tracker must still record last_linted_at from
# the real payload shape — regression for #1873, where reading the absent
# exit_code defaulted to "failed" so the lint never registered and the gate's
# state-tracked rule was permanently dead.
SID_REAL="test-real-shape-$$"
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/foo.rb","old_string":"a","new_string":"b"},"session_id":"%s"}' "$SID_REAL" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null
printf '{"tool_name":"Bash","tool_input":{"command":"bin/rubocop foo.rb"},"tool_response":{"stdout":"","stderr":"","interrupted":false,"isImage":false},"session_id":"%s"}' "$SID_REAL" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "records lint from real harness payload (no exit_code) → allows commit"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_REAL\"}"

# ---- #2387: shell was invisible to the gate in BOTH directions ---------------
#
# `.sh` was not a code file and extensionless scripts matched nothing, so a
# commit touching only shell took the "only doc/config files edited" exit and
# was never gated. Measured in this repo: 18 files end in `.sh`, but 76 are
# shell scripts by shebang — the bin/* majority is extensionless, so extension
# alone would still leave most of the surface ungated.
#
# Conversely neither `shellcheck` nor a project wrapper counted as a lint, so
# running the CORRECT linter never advanced last_linted_at. Combined, a
# shell-only commit could be blocked with no way to clear it.
SH_FIX=$(cd "$(mktemp -d)" && pwd -P)
( cd "$SH_FIX" && git init -q && git config user.email t@t && git config user.name t \
  && touch seed && git add seed && git commit -q -m init )
mkdir -p "$SH_FIX/bin" "$SH_FIX/sub"
printf '#!/usr/bin/env bash\necho hi\n' > "$SH_FIX/deploy.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$SH_FIX/bin/scan-fleet"
printf '#!/usr/bin/env fish\necho hi\n' > "$SH_FIX/bin/fishy"
printf 'key = value\n' > "$SH_FIX/plainconf"
printf 'puts 1\n' > "$SH_FIX/app.rb"
SH_SCRATCH=$(cd "$(mktemp -d)" && pwd -P)
printf '#!/usr/bin/env bash\necho hi\n' > "$SH_SCRATCH/probe.sh"

# Arm the gate for a session whose only tracked edits are the given paths.
sh_gate_session() { # <sid> <path...>
  local sid="$1"; shift
  local dir="$CLAUDE_PLUGIN_DATA/sessions/$sid"
  rm -rf "$dir"; mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/edits.log"
  date +%s > "$dir/last_modified_at"
}

sh_gate_session "sh-dotsh-2387" "$SH_FIX/deploy.sh"
t "blocks a commit that touched only a .sh file (#2387)"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-dotsh-2387\",\"cwd\":\"$SH_FIX\"}" \
  "linters have not been run"

sh_gate_session "sh-extless-2387" "$SH_FIX/bin/scan-fleet"
t "blocks a commit that touched only an extensionless shell script (#2387)"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-extless-2387\",\"cwd\":\"$SH_FIX\"}" \
  "linters have not been run"

# Codex records paths REPO-RELATIVE (#2352). The base must come from the git
# toplevel, not the raw cwd, or a tool call made in a subdirectory resolves the
# entry against the wrong directory and the script is silently not classified.
sh_gate_session "sh-relative-2387" "bin/scan-fleet"
t "classifies a repo-relative shell path against the git toplevel from a subdirectory cwd (#2352, #2387)"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-relative-2387\",\"cwd\":\"$SH_FIX/sub\"}" \
  "linters have not been run"

# GUARD: with no cwd there is no base, and a bare relative path must NOT be
# probed — `[[ -f ]]` would consult the HOOK PROCESS's own cwd, letting an
# unrelated checkout answer a question that can BLOCK a commit.
t "does not probe a repo-relative path when the payload carries no cwd (#2387)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-relative-2387\"}"

# #2388 keeps out-of-repo entries in the log for the whole session by design.
# They are not part of THIS commit, so they must not raise a gate that no lint
# in this repo can lower.
sh_gate_session "sh-foreign-2387" "$SH_SCRATCH/probe.sh"
t "a shell script edited outside the commit's repo does not arm the gate (#2387, #2388)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-foreign-2387\",\"cwd\":\"$SH_FIX\"}"

sh_gate_session "sh-mixed-2387" "$SH_SCRATCH/probe.sh" "$SH_FIX/app.rb"
t "an in-repo code file still arms the gate alongside an out-of-repo script (#2387)"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-mixed-2387\",\"cwd\":\"$SH_FIX\"}" \
  "linters have not been run"

# GUARDS on the shebang probe. These are why the decision was "by shebang", not
# "anything under bin/" — a path heuristic would classify all of these as code.
sh_gate_session "sh-noshebang-2387" "$SH_FIX/plainconf"
t "an extensionless file with no shebang is not code (#2387)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-noshebang-2387\",\"cwd\":\"$SH_FIX\"}"

sh_gate_session "sh-fish-2387" "$SH_FIX/bin/fishy"
t "a non-shell shebang does not make a file code (#2387)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-fish-2387\",\"cwd\":\"$SH_FIX\"}"

# Documents the accepted degradation so a later "fix" does not silently make it
# fail closed: a deleted file cannot be classified, and blocking on it would
# raise a gate nothing can lower.
sh_gate_session "sh-gone-2387" "$SH_FIX/gone-forever"
t "a tracked path that no longer exists fails open (#2387)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-gone-2387\",\"cwd\":\"$SH_FIX\"}"

# The matcher half. Each feeds the tracker a command and asserts last_linted_at.
# Arguments must be $SH_FIX paths — never bin/ci or bin/rspec, which already
# match the existing patterns and would pass without the new branch.
sh_lint_records() { # <sid> <command> <present|absent>
  local sid="$1" cmd="$2" want="$3"
  local dir="$CLAUDE_PLUGIN_DATA/sessions/$sid"
  rm -rf "$dir"
  jq -nc --arg c "$cmd" --arg s "$sid" \
    '{tool_name:"Bash",tool_input:{command:$c},tool_response:{interrupted:false},session_id:$s}' \
    | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null
  assert_state_file "$dir/last_linted_at" "$want"
}

t "bare shellcheck records last_linted_at (#2387)"
sh_lint_records "shl-bare-2387" "shellcheck -x $SH_FIX/deploy.sh" present
t "a project shell-lint wrapper records last_linted_at (#2387)"
sh_lint_records "shl-wrap-2387" "bin/lint-shell $SH_FIX/deploy.sh" present
t "a directory-prefixed wrapper records last_linted_at (#2387)"
sh_lint_records "shl-dir-2387" "./bin/lint-shell $SH_FIX/deploy.sh" present
t "xargs shellcheck records last_linted_at (#2387)"
sh_lint_records "shl-xargs-2387" "git ls-files '*.sh' | xargs shellcheck" present
t "find -exec shellcheck records last_linted_at (#2387)"
sh_lint_records "shl-exec-2387" "find . -name '*.sh' -exec shellcheck {} +" present
t "shfmt records last_linted_at (#2387)"
sh_lint_records "shl-shfmt-2387" "shfmt -d $SH_FIX" present
t "zsh -n records last_linted_at (#2387)"
sh_lint_records "shl-zshn-2387" "zsh -n $SH_FIX/deploy.sh" present

# GUARDS. Each is a command an agent plausibly runs in the very session it is
# editing shell, and counting any of them silently disarms the gate.
t "installing shellcheck is not a lint run (#2387)"
sh_lint_records "shl-install-2387" "brew install shellcheck" absent
t "probing for shellcheck is not a lint run (#2387)"
sh_lint_records "shl-probe-2387" "command -v shellcheck" absent
t "running a script with bash is not a lint run (#2387)"
sh_lint_records "shl-run-2387" "bash jus/hooks/tests.sh" absent

# ⚠️ THE ONE THAT MATTERS. juscribe_sop_command_segments turns every newline
# into a separator, so each line of a heredoc body becomes a segment anchored at
# column 0 — anchoring alone does NOT stop prose from matching. The SOP mandates
# writing commit bodies through quoted heredocs, so a message describing this
# very change would otherwise register as a lint run and disarm the gate for the
# commit shipping it. Measured before juscribe_sop_strip_heredocs existed.
t "prose in a heredoc that mentions shellcheck is not a lint run (#2387)"
sh_lint_records "shl-heredoc-2387" \
  "$(printf 'git commit -F - <<EOF\n[#2387] Teach the gate about shell\nshellcheck and the wrapper now record last_linted_at.\nEOF\n')" absent

# End to end: the linter that was previously unrecognised now clears the gate
# for the commit it applies to.
sh_gate_session "sh-e2e-2387" "$SH_FIX/deploy.sh"
printf '{"tool_name":"Bash","tool_input":{"command":"shellcheck -x %s"},"tool_response":{"interrupted":false},"session_id":"sh-e2e-2387"}' "$SH_FIX/deploy.sh" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null
t "running the shell linter clears the gate for a .sh-only commit (#2387)"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"sh-e2e-2387\",\"cwd\":\"$SH_FIX\"}"

rm -rf "$SH_FIX" "$SH_SCRATCH"

# ---- jus-docs-nudge.sh --------------------------------------------------------

section "jus-docs-nudge.sh"

DOCS_PROJECT=$(mktemp -d)
mkdir -p "$DOCS_PROJECT/.jus"
printf 'app/styles/\tdocs/css.md\tthe styling rules live there\n' > "$DOCS_PROJECT/.jus/docs-nudges.tsv"
SID_DOCS="test-docs-$$"
docs_state="$CLAUDE_PLUGIN_DATA/sessions/$SID_DOCS"
mkdir -p "$docs_state"

t "nudges with doc + hint on first mapped edit"
out=$(printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"%s/app/styles/a.css"}}' \
        "$SID_DOCS" "$DOCS_PROJECT" \
      | CLAUDE_PROJECT_DIR="$DOCS_PROJECT" "$SCRIPTS/jus-docs-nudge.sh")
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="docs-nudge emits systemMessage naming the doc"
if [[ "$out" == *"systemMessage"* && "$out" == *"docs/css.md"* && "$out" == *"styling rules"* ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (got: %s)\n' "$TEST_NAME" "$out"
fi
assert_reaches_agent "docs-nudge (edit) reaches the agent, not just the terminal" "$out"

t "stays quiet on the second edit for the same doc and ticket scope"
out2=$(printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"%s/app/styles/b.css"}}' \
        "$SID_DOCS" "$DOCS_PROJECT" \
      | CLAUDE_PROJECT_DIR="$DOCS_PROJECT" "$SCRIPTS/jus-docs-nudge.sh")
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="docs-nudge dedups within one scope"
if [[ -z "$out2" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (got: %s)\n' "$TEST_NAME" "$out2"
fi

t "re-fires when a new ticket becomes active"
echo "77" > "$docs_state/active_ticket"
out3=$(printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"%s/app/styles/c.css"}}' \
        "$SID_DOCS" "$DOCS_PROJECT" \
      | CLAUDE_PROJECT_DIR="$DOCS_PROJECT" "$SCRIPTS/jus-docs-nudge.sh")
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="docs-nudge re-fires per new active ticket"
if [[ "$out3" == *"docs/css.md"* ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (got: %s)\n' "$TEST_NAME" "$out3"
fi

t "silent no-op with no map file"
NOMAP_PROJECT=$(mktemp -d)
export CLAUDE_PROJECT_DIR="$NOMAP_PROJECT"
assert_exit 0 "$SCRIPTS/jus-docs-nudge.sh" \
  "{\"tool_name\":\"Edit\",\"session_id\":\"$SID_DOCS\",\"tool_input\":{\"file_path\":\"$NOMAP_PROJECT/app/styles/a.css\"}}"
rm -rf "$NOMAP_PROJECT"

t "silent for unmapped paths"
export CLAUDE_PROJECT_DIR="$DOCS_PROJECT"
assert_exit 0 "$SCRIPTS/jus-docs-nudge.sh" \
  "{\"tool_name\":\"Edit\",\"session_id\":\"$SID_DOCS\",\"tool_input\":{\"file_path\":\"$DOCS_PROJECT/lib/other.rb\"}}"
unset CLAUDE_PROJECT_DIR

# #2487: the pickup trigger. A `started` transition (PostToolUse Bash) matches
# `label:`/`kw:` rows against the ticket's labels and title, fetched through a
# stubbed `jus` on a restricted PATH (a real jq symlinked in, the real jus
# unreachable). By the first edit the approach is already chosen — the pickup
# is the moment a doc can still change the plan.
PICKUP_STUB=$(mktemp -d)
ln -s "$(command -v jq)" "$PICKUP_STUB/jq"
cat > "$PICKUP_STUB/jus" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$PICKUP_STUB/log"
printf '%s' '{"ticket":{"title":"Container hardening pass","labels":["docker"]}}'
STUB
chmod +x "$PICKUP_STUB/jus"
printf 'label:docker\tdocs/threat.md\twhat a compromised container can reach\n' \
  >> "$DOCS_PROJECT/.jus/docs-nudges.tsv"
STARTED_CMD='jus api PATCH /workspaces/1/tickets/501/transition {"state":"started"}'
SID_PICKUP="test-docs-pickup-$$"

t "pickup nudge fires when a ticket label matches a label: row"
out_pickup=$(jq -n --arg sid "$SID_PICKUP" --arg cmd "$STARTED_CMD" \
        '{tool_name:"Bash", session_id:$sid, tool_input:{command:$cmd}}' \
      | CLAUDE_PROJECT_DIR="$DOCS_PROJECT" PATH="$PICKUP_STUB:/usr/bin:/bin" \
        "$SCRIPTS/jus-docs-nudge.sh")
assert_reaches_agent "docs-nudge (pickup) reaches the agent, not just the terminal" "$out_pickup"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$out_pickup" == *"systemMessage"* && "$out_pickup" == *"docs/threat.md"* \
      && "$out_pickup" == *"#501"* ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (got: %s)\n' "$TEST_NAME" "$out_pickup"
fi

t "pickup-nudged doc stays quiet at the first edit under its mapped path"
printf 'app/threat/\tdocs/threat.md\twhat a compromised container can reach\n' \
  >> "$DOCS_PROJECT/.jus/docs-nudges.tsv"
mkdir -p "$CLAUDE_PLUGIN_DATA/sessions/$SID_PICKUP"
echo "501" > "$CLAUDE_PLUGIN_DATA/sessions/$SID_PICKUP/active_ticket"
out_dedup=$(printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"%s/app/threat/model.rb"}}' \
        "$SID_PICKUP" "$DOCS_PROJECT" \
      | CLAUDE_PROJECT_DIR="$DOCS_PROJECT" "$SCRIPTS/jus-docs-nudge.sh")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$out_dedup" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (got: %s)\n' "$TEST_NAME" "$out_dedup"
fi

t "pickup is silent for a non-transition command and calls no jus"
rm -f "$PICKUP_STUB/log"
out_nontrans=$(jq -n --arg sid "$SID_PICKUP" \
        '{tool_name:"Bash", session_id:$sid, tool_input:{command:"jus api GET /workspaces/1/tickets/501"}}' \
      | CLAUDE_PROJECT_DIR="$DOCS_PROJECT" PATH="$PICKUP_STUB:/usr/bin:/bin" \
        "$SCRIPTS/jus-docs-nudge.sh")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$out_nontrans" && ! -f "$PICKUP_STUB/log" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (got: %s)\n' "$TEST_NAME" "$out_nontrans"
fi

t "pickup makes no jus call when the map has only path rows"
PATHONLY_PROJECT=$(mktemp -d)
mkdir -p "$PATHONLY_PROJECT/.jus"
printf 'app/styles/\tdocs/css.md\tthe styling rules live there\n' \
  > "$PATHONLY_PROJECT/.jus/docs-nudges.tsv"
rm -f "$PICKUP_STUB/log"
out_pathonly=$(jq -n --arg sid "$SID_PICKUP" --arg cmd "$STARTED_CMD" \
        '{tool_name:"Bash", session_id:$sid, tool_input:{command:$cmd}}' \
      | CLAUDE_PROJECT_DIR="$PATHONLY_PROJECT" PATH="$PICKUP_STUB:/usr/bin:/bin" \
        "$SCRIPTS/jus-docs-nudge.sh")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$out_pathonly" && ! -f "$PICKUP_STUB/log" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (got: %s)\n' "$TEST_NAME" "$out_pathonly"
fi
rm -rf "$PATHONLY_PROJECT"

t "pickup fails open when jus is not on PATH"
NOJUS_STUB=$(mktemp -d)
ln -s "$(command -v jq)" "$NOJUS_STUB/jq"
out_nojus=$(jq -n --arg sid "$SID_PICKUP" --arg cmd "$STARTED_CMD" \
        '{tool_name:"Bash", session_id:$sid, tool_input:{command:$cmd}}' \
      | CLAUDE_PROJECT_DIR="$DOCS_PROJECT" PATH="$NOJUS_STUB:/usr/bin:/bin" \
        "$SCRIPTS/jus-docs-nudge.sh")
rc_nojus=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$out_nojus" && "$rc_nojus" -eq 0 ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (exit=%s, got: %s)\n' "$TEST_NAME" "$rc_nojus" "$out_nojus"
fi
rm -rf "$NOJUS_STUB" "$PICKUP_STUB"

# #3393: a row may omit its hint and take it from the doc's own INDEX.md.
#
# A nudge row is two kinds of work and only one is expensive. The TRIGGER is a
# judgement nothing can derive; the HINT is a clause on why the doc matters
# now, and the docs index already carries one per doc. Duplicating it by hand
# is what left 50 of this project's 81 deep-dives with no row at all.
#
# The index is resolved relative to the DOC, not the project: `docs/css.md`
# looks in `docs/INDEX.md`. A bundled hook cannot assume `.jus/docs/`.
INDEX_PROJECT=$(mktemp -d)
mkdir -p "$INDEX_PROJECT/.jus" "$INDEX_PROJECT/docs"
cat > "$INDEX_PROJECT/docs/INDEX.md" <<'IDX'
# Documentation Index

- [css.md](css.md) — When to read: adding or modifying any styles — and before touching the build pipeline, a much longer story that nobody needs at this moment
- [threat.md](threat.md) — When to read: what a compromised container can reach. The networks, the accessory options and the blast-radius rules all live in there.
- [silent.md](silent.md) — this entry has no When to read line at all
- [aside.md](aside.md) — When to read: touching the retry policy (it is almost never the retries — measured) and nothing else
IDX

nudge_edit() { # <session id> <project> <relative file> [extra PATH entry]
  printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"%s/%s"}}' \
    "$1" "$2" "$3" | CLAUDE_PROJECT_DIR="$2" "$SCRIPTS/jus-docs-nudge.sh"
}

printf 'app/styles/\tdocs/css.md\n' > "$INDEX_PROJECT/.jus/docs-nudges.tsv"
t "two-column row takes its hint from INDEX.md"
out_idx=$(nudge_edit "test-idx-a-$$" "$INDEX_PROJECT" "app/styles/a.css")
assert_stdout "two-column row reads the INDEX hint" "adding or modifying any styles" "$out_idx"
t "the hint stops at the first clause"
assert_stdout_lacks "INDEX hint is cut at the em-dash" "longer story" "$out_idx"

printf 'app/threat/\tdocs/threat.md\n' > "$INDEX_PROJECT/.jus/docs-nudges.tsv"
t "a sentence-terminated INDEX entry is cut at the sentence"
out_sent=$(nudge_edit "test-idx-b-$$" "$INDEX_PROJECT" "app/threat/model.rb")
assert_stdout "sentence clause survives" "what a compromised container can reach" "$out_sent"
assert_stdout_lacks "sentence clause is cut at the period" "blast-radius" "$out_sent"

# 4 of this project's 81 entries end their first clause inside a parenthetical,
# and `(#2870` left hanging off a one-line reminder reads as the truncation
# being a bug rather than the point.
printf 'app/aside/\tdocs/aside.md\n' > "$INDEX_PROJECT/.jus/docs-nudges.tsv"
t "a clause cut inside a parenthetical drops the unclosed aside"
out_aside=$(nudge_edit "test-idx-h-$$" "$INDEX_PROJECT" "app/aside/x.rb")
assert_stdout "the aside is dropped whole" "touching the retry policy" "$out_aside"
assert_stdout_lacks "no bracket is left open" "almost never" "$out_aside"

printf 'app/styles/\tdocs/css.md\tthe hand-written hint wins\n' > "$INDEX_PROJECT/.jus/docs-nudges.tsv"
t "a three-column row still overrides the INDEX"
out_override=$(nudge_edit "test-idx-c-$$" "$INDEX_PROJECT" "app/styles/a.css")
assert_stdout "third column overrides INDEX" "the hand-written hint wins" "$out_override"
assert_stdout_lacks "INDEX hint is not appended to an override" "adding or modifying" "$out_override"

# The property that makes this safe to ship to every project: a two-column row
# in a project with no index, or an index this parser does not understand, is
# a silent no-op — exactly like a missing map file. Never an error, and never
# a half-written message with an empty hint dangling off it.
printf 'app/styles/\tdocs/css.md\n' > "$INDEX_PROJECT/.jus/docs-nudges.tsv"
t "a two-column row whose doc has no INDEX entry is silent"
printf 'app/other/\tdocs/unlisted.md\n' >> "$INDEX_PROJECT/.jus/docs-nudges.tsv"
assert_stdout "no INDEX entry means no nudge" "" \
  "$(nudge_edit "test-idx-d-$$" "$INDEX_PROJECT" "app/other/x.rb")"

t "a two-column row whose INDEX entry has no When to read line is silent"
printf 'app/silent/\tdocs/silent.md\n' >> "$INDEX_PROJECT/.jus/docs-nudges.tsv"
assert_stdout "an unparseable INDEX entry means no nudge" "" \
  "$(nudge_edit "test-idx-e-$$" "$INDEX_PROJECT" "app/silent/x.rb")"

NOINDEX_PROJECT=$(mktemp -d)
mkdir -p "$NOINDEX_PROJECT/.jus"
printf 'app/styles/\tdocs/css.md\n' > "$NOINDEX_PROJECT/.jus/docs-nudges.tsv"
t "a two-column row in a project with no INDEX.md is silent and exits 0"
assert_stdout "no INDEX.md means no nudge" "" \
  "$(nudge_edit "test-idx-f-$$" "$NOINDEX_PROJECT" "app/styles/a.css")"
export CLAUDE_PROJECT_DIR="$NOINDEX_PROJECT"
assert_exit 0 "$SCRIPTS/jus-docs-nudge.sh" \
  "{\"tool_name\":\"Edit\",\"session_id\":\"test-idx-g-$$\",\"tool_input\":{\"file_path\":\"$NOINDEX_PROJECT/app/styles/a.css\"}}"
unset CLAUDE_PROJECT_DIR
rm -rf "$NOINDEX_PROJECT"

# The pickup path builds its message from the same column, so it resolves the
# same way. This matters more than the edit path here: most of the rows this
# change made writable are `kw:` rows, which only ever fire at pickup.
IDX_STUB=$(mktemp -d)
ln -s "$(command -v jq)" "$IDX_STUB/jq"
cat > "$IDX_STUB/jus" <<STUB
#!/bin/bash
printf '%s' '{"ticket":{"title":"Container hardening pass","labels":["docker"]}}'
STUB
chmod +x "$IDX_STUB/jus"
printf 'label:docker\tdocs/threat.md\n' > "$INDEX_PROJECT/.jus/docs-nudges.tsv"
t "a pickup row resolves its hint from INDEX.md too"
out_pickup_idx=$(jq -n --arg sid "test-idx-pickup-$$" --arg cmd "$STARTED_CMD" \
        '{tool_name:"Bash", session_id:$sid, tool_input:{command:$cmd}}' \
      | CLAUDE_PROJECT_DIR="$INDEX_PROJECT" PATH="$IDX_STUB:/usr/bin:/bin" \
        "$SCRIPTS/jus-docs-nudge.sh")
assert_stdout "pickup reads the INDEX hint" "what a compromised container can reach" "$out_pickup_idx"
rm -rf "$IDX_STUB" "$INDEX_PROJECT"

rm -rf "$DOCS_PROJECT"

# ---- jus-stop-uncommitted.sh --------------------------------------------------

section "jus-stop-uncommitted.sh"

# Build a dirty repo. `pwd -P` because `git rev-parse --show-toplevel` answers
# with the REALPATH, and on a Mac `mktemp -d` hands back /var/… for
# /private/var/… — so an assertion on the literal path would never match the
# command the message now carries (#4431).
DIRTY_REPO=$(cd "$(mktemp -d)" && pwd -P)
( cd "$DIRTY_REPO" && git init -q && git config user.email t@t && git config user.name t \
  && touch a && git add a && git commit -q -m init && echo dirty > b )

t "blocks stop when working tree is dirty"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\"}" \
  "STOP BLOCKED"

# #4431 — the message names the command instead of the files, so `-C` is what
# makes it runnable from wherever the reader is standing. Asserted on the
# ORDINARY case, because the point is that it is not a worktree special case:
# there is one message form and it always carries the path.
t "the message carries a -C command naming the tree it checked"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\"}" \
  "git -C $DIRTY_REPO status --porcelain"

# The file list is what the command replaces. A tree with 40 dirty files used to
# print 20 lines and an overflow count on every firing.
t "and does not list the dirty files"
assert_stdout_lacks "no file list in the stop message" " b" \
  "$(printf '%s' "{\"cwd\":\"$DIRTY_REPO\"}" \
     | "$SCRIPTS/jus-stop-uncommitted.sh" 2>&1 || true)"

t "allows stop when stop_hook_active=true (avoid loop)"
assert_exit 0 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"stop_hook_active\":true}"

# Clean repo
CLEAN_REPO=$(mktemp -d)
( cd "$CLEAN_REPO" && git init -q && git config user.email t@t && git config user.name t \
  && touch a && git add a && git commit -q -m init )

t "allows stop when working tree is clean"
assert_exit 0 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$CLEAN_REPO\"}"

t "allows stop in non-git directory"
assert_exit 0 "$SCRIPTS/jus-stop-uncommitted.sh" \
  '{"cwd":"/tmp"}'

# The scoping tests that lived here (#2216 / #2352 / #2355 / #2362 / #2366 /
# #2388) were removed with the machinery they covered (#2392). The hook now
# blocks on the whole tree, which is what it did before any of it, and what
# worktree isolation makes correct.

# ---- the session's own worktree, not the main checkout (#3667) --------------
#
# A session following .jus/docs/worktree-provisioning.md keeps its cwd at the
# MAIN checkout and cd's into its worktree per command, so `cwd` on stdin names
# a tree the session never edits. The lock reason is the link back: the recipe
# locks with `jus session <session_id> (pid N)`, which is the same id the hook
# receives. Measured 5 Sep — a session with everything committed on its branch
# was blocked three times running by another session's mobile/** edits.

WT_BASE=$(cd "$(mktemp -d)" && pwd -P)
WT_MAIN="$WT_BASE/main"
mkdir -p "$WT_MAIN"
( cd "$WT_MAIN" && git init -q && git config user.email t@t && git config user.name t \
  && touch a && git add a && git commit -q -m init \
  && git worktree add --lock --reason "jus session test-sid (pid 1)" \
       "$WT_BASE/wt" -b wt-branch ) >/dev/null 2>&1
echo dirty > "$WT_MAIN/main-only"

t "a worktree locked in this session's name is checked instead of the main checkout"
assert_exit 0 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$WT_MAIN\",\"session_id\":\"test-sid\"}"

echo dirty > "$WT_BASE/wt/mine"

# The command's PATH is what says which tree, now that the files are not listed
# (#4431) — so this is the same claim the filename assertion used to make, and
# it is stronger: a wrong path is wrong even when both trees hold a file of the
# same name.
t "a dirty session worktree still blocks the stop"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$WT_MAIN\",\"session_id\":\"test-sid\"}" \
  "git -C $WT_BASE/wt status --porcelain"

# The positive assertion above passes on a hook that names BOTH trees, which is
# the failure #3667 was about — so the load-bearing half is the absence.
t "and the command names that tree, not the cwd's"
assert_stdout_lacks "the main checkout is not named to a worktree session" "$WT_MAIN" \
  "$(printf '%s' "{\"cwd\":\"$WT_MAIN\",\"session_id\":\"test-sid\"}" \
     | "$SCRIPTS/jus-stop-uncommitted.sh" 2>&1 || true)"

# #3667 added a paragraph saying which tree had been checked, because the file
# list was relative to it and a reader standing elsewhere saw a different set.
# The path inside the command retires that paragraph: it says the same thing,
# and it is runnable.
t "and says so without a paragraph explaining it"
assert_stdout_lacks "the redirect paragraph is gone" "worktree this session locked" \
  "$(printf '%s' "{\"cwd\":\"$WT_MAIN\",\"session_id\":\"test-sid\"}" \
     | "$SCRIPTS/jus-stop-uncommitted.sh" 2>&1 || true)"

t "no lock naming this session leaves the main checkout blocking"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$WT_MAIN\",\"session_id\":\"other-sid\"}" \
  "git -C $WT_MAIN status --porcelain"

# An empty session_id must match NOTHING. A substring test against "" matches
# every reason, which would silently redirect the check to an arbitrary
# worktree belonging to somebody else.
t "an absent session_id leaves the main checkout blocking"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$WT_MAIN\"}" \
  "git -C $WT_MAIN status --porcelain"

( cd "$WT_MAIN" && git worktree add --lock --reason "jus session test-sid (pid 1)" \
    "$WT_BASE/wt2" -b wt-branch-2 ) >/dev/null 2>&1

t "a session already running inside one of its own worktrees stays in it"
assert_exit 0 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$WT_BASE/wt2\",\"session_id\":\"test-sid\"}"

echo dirty > "$WT_BASE/wt2/theirs"

# It keeps the tree it is standing in rather than being redirected to whichever
# it locked first, and the command is what proves which one that was.
t "and its block names the tree it is standing in, not the one it locked first"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$WT_BASE/wt2\",\"session_id\":\"test-sid\"}" \
  "git -C $WT_BASE/wt2 status --porcelain"
rm -f "$WT_BASE/wt2/theirs"

( cd "$WT_MAIN" && git worktree remove --force "$WT_BASE/wt" \
  && git worktree remove --force "$WT_BASE/wt2" ) >/dev/null 2>&1
rm -rf "$WT_BASE"

rm -rf "$DIRTY_REPO" "$CLEAN_REPO"

# ---- README.md's worktree lock recipe actually works (#3676) -----------------
#
# Both commit guards resolve WHICH tree to read by looking for a worktree
# locked in the session's own name (#3667, #3669). Nothing in the bundle told
# anyone to lock one that way: the recipe lived in the producing project's local
# docs, which `bin/publish-skills` does not ship, so for every installing
# project both guards silently fell back to the cwd's checkout.
#
# ⚠️ THE TEST RUNS THE RECIPE, IT DOES NOT GREP FOR IT. A README documenting a
# matcher drifts the moment the matcher changes, and a string assertion drifts
# with it — it would keep passing on a reason string that no longer resolves.
# So: pull the reason out of README.md, lock a real worktree with it, and ask
# juscribe_sop_session_worktree whether it finds it.

README="$HOOKS_DIR/../README.md"

t "README.md documents the lock reason the commit guards match on"
TESTS_RUN=$((TESTS_RUN + 1))
readme_reason=$(grep -o 'git worktree add --lock --reason "[^"]*"' "$README" | head -1 | sed 's/.*--reason "//; s/"$//')
if [[ -n "$readme_reason" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
  printf '      no `git worktree add --lock --reason "…"` line in %s\n' "$README"
fi

# The README writes the reason with shell variables in it. Expand them the way a
# reader's shell would, against a known session id, and the expansion is what
# gets locked — so a recipe that drops the id fails here rather than downstream.
RM_BASE=$(cd "$(mktemp -d)" && pwd -P)
RM_MAIN="$RM_BASE/main"
RM_SID="readme-recipe-sid-$$"
mkdir -p "$RM_MAIN"
( cd "$RM_MAIN" && git init -q && git config user.email t@t && git config user.name t \
  && touch seed && git add seed && git commit -q -m init ) >/dev/null 2>&1
rm_expanded=$(CLAUDE_CODE_SESSION_ID="$RM_SID" CLAUDE_PID=1 \
  bash -c "printf '%s' \"${readme_reason//\"/\\\"}\"" 2>/dev/null || printf '')
( cd "$RM_MAIN" && git worktree add --lock --reason "$rm_expanded" "$RM_BASE/wt" -b readme-recipe ) >/dev/null 2>&1

t "the recipe as written resolves to the session's own worktree"
rm_found=$( source "$SCRIPTS/lib/state.sh"; juscribe_sop_session_worktree "$RM_MAIN" "$RM_SID" )
assert_stdout "README's --reason makes the guards find this worktree" "$RM_BASE/wt" "$rm_found"

# ⚠️ A reason beginning `claude session ` matches Claude Code's OWN ownership
# regex, so it releases the lock once the recorded pid is gone (#2889) — the
# lock silently disappears and another session can remove the tree. The README
# must not print that spelling, however well it would satisfy the matcher.
t "and the documented reason is not Claude Code's own lock spelling"
TESTS_RUN=$((TESTS_RUN + 1))
# ⚠️ -n first: an ABSENT recipe expands to nothing, which is not "claude
# session …" either — so without it this assertion passes hardest exactly when
# the README says nothing at all.
if [[ -n "$rm_expanded" && "$rm_expanded" != "claude session "* && "$rm_expanded" != "claude agent "* ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
  printf '      reason expands to: %s\n' "$rm_expanded"
fi

# The substring rule is the actual contract, and the README has to state it
# rather than leaving readers to infer a required prefix from the example.
t "README states that the reason must carry the session id"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -qi 'session id' "$README" && grep -q 'CLAUDE_CODE_SESSION_ID' "$README"; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

# Silence is the failure mode this whole ticket is about, so the README owes the
# no-lock behaviour too: the guards fall back to the cwd's checkout, correctly
# and without warning.
t "README says what happens with no matching lock"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -qiE 'falls? back' "$README"; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

( cd "$RM_MAIN" && git worktree remove --force "$RM_BASE/wt" ) >/dev/null 2>&1
rm -rf "$RM_BASE"

# ---- start-comment-nudge.sh + lifecycle tracking --------------------------

section "jus-start-comment-nudge.sh + start-comment tracking"

TRACK="$SCRIPTS/jus-post-bash-tracker.sh"
NUDGE="$SCRIPTS/jus-start-comment-nudge.sh"

# JSON builders (jq handles escaping of the nested quotes).
mk_bash() { jq -nc --arg cmd "$1" --arg sid "$2" '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{interrupted:false},session_id:$sid}'; }
mk_edit() { jq -nc --arg fp "$1" --arg sid "$2" '{tool_name:"Edit",tool_input:{file_path:$fp},session_id:$sid}'; }


# Scenario A — started, no comment yet → tracker arms, nudge fires on a source edit, then fires once.
SID_A="sc-a-$$"; DIR_A="$CLAUDE_PLUGIN_DATA/sessions/$SID_A"
mk_bash "jus api PATCH /workspaces/1/tickets/1852/transition '{\"state\":\"started\"}'" "$SID_A" | "$TRACK" >/dev/null

t "tracker records active_ticket on a started transition"
assert_state_eq "$DIR_A/active_ticket" "1852"

t "nudge fires on the first source-file edit when no start comment exists"
assert_exit 0 "$NUDGE" "$(mk_edit /repo/app/models/foo.rb "$SID_A")" "start comment"
# Its own session: this nudge is fire-once per ticket, so re-invoking it for
# SID_A would correctly return nothing and the assertion would fail on the
# dedup rather than on the fields.
SID_FIELDS="sc-fields-$$"
mk_bash "jus api PATCH /workspaces/1/tickets/1852/transition '{\"state\":\"started\"}'" "$SID_FIELDS" | "$TRACK" >/dev/null
assert_reaches_agent "start-comment nudge reaches the agent, not just the terminal" \
  "$(mk_edit /repo/app/models/foo.rb "$SID_FIELDS" | "$NUDGE")"

t "nudge fire-once: a second source edit stays silent"
assert_no_nudge "$NUDGE" "$(mk_edit /repo/app/models/bar.rb "$SID_A")"

# Scenario B — a start comment to the active ticket silences the nudge.
SID_B="sc-b-$$"; DIR_B="$CLAUDE_PLUGIN_DATA/sessions/$SID_B"
mk_bash "jus api PATCH /workspaces/1/tickets/1900/transition '{\"state\":\"started\"}'" "$SID_B" | "$TRACK" >/dev/null
mk_bash "jus api POST /workspaces/1/tickets/1900/comments '{\"comment\":{\"body\":\"Starting.\"}}'" "$SID_B" | "$TRACK" >/dev/null

t "tracker records start_comment_posted on a comment POST to the active ticket"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -e "$DIR_B/start_comment_posted" ]]; then printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"; else TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME"); printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"; fi

t "nudge stays quiet once a start comment has been posted"
assert_no_nudge "$NUDGE" "$(mk_edit /repo/app/models/baz.rb "$SID_B")"

# Scenario C — a comment-reaction toggle is NOT a start comment.
SID_C="sc-c-$$"; DIR_C="$CLAUDE_PLUGIN_DATA/sessions/$SID_C"
mk_bash "jus api PATCH /workspaces/1/tickets/1901/transition '{\"state\":\"started\"}'" "$SID_C" | "$TRACK" >/dev/null
mk_bash "jus api POST /workspaces/1/tickets/1901/comments/55/reactions/toggle '{\"emoji\":\"👍\"}'" "$SID_C" | "$TRACK" >/dev/null

t "comment-reaction toggle does NOT set start_comment_posted"
assert_state_absent "$DIR_C/start_comment_posted"

t "nudge still fires after only a reaction toggle"
assert_exit 0 "$NUDGE" "$(mk_edit /repo/app/models/qux.rb "$SID_C")" "start comment"

# Scenario D — non-source edit does not nudge.
SID_D="sc-d-$$"
mk_bash "jus api PATCH /workspaces/1/tickets/1902/transition '{\"state\":\"started\"}'" "$SID_D" | "$TRACK" >/dev/null
t "no nudge on a non-source (doc) edit"
assert_no_nudge "$NUDGE" "$(mk_edit /repo/README.md "$SID_D")"

# Scenario E — non-ticket work (no started transition) does not nudge.
SID_E="sc-e-$$"
t "no nudge for non-ticket work (no started transition seen)"
assert_no_nudge "$NUDGE" "$(mk_edit /repo/app/models/none.rb "$SID_E")"

# ---- fail-open on malformed JSON (every hook) -----------------------------

section "fail-open on malformed JSON input (all hooks)"

# A hook must never break a tool call because the harness handed it unexpected
# stdin: malformed JSON → silent no-op (exit 0), via juscribe_sop_require_valid_json.
#
# ⚠️ THE LIST IS DERIVED FROM hooks.json, NOT TYPED (#3507). It was a literal
# list of nine names, and two registered hooks — jus-docs-nudge and
# jus-block-accepted-manifest-edit — had silently never been in it. A hand-kept
# list of "every hook" drifts the moment a hook is added, and the drift is
# invisible: the sweep still passes, on the hooks it happens to name. Both were
# already failing open when this was derived, so nothing was broken — but
# nothing was checking either.
HOOK_SCRIPTS=$(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$HOOKS_DIR/hooks.json" \
                 | sed 's|.*/||; s|\.sh$||' | sort -u)
if [[ -z "$HOOK_SCRIPTS" ]]; then
  printf '  \033[31m✗\033[0m could not read hook names from hooks.json — the sweep would be vacuous\n'
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("hooks.json hook-name extraction")
fi
for hook in $HOOK_SCRIPTS; do
  TEST_NAME="$hook fails open (exit 0, silent) on malformed JSON"
  TESTS_RUN=$((TESTS_RUN + 1))
  out=$(printf '%s' 'this is not valid json {' | "$SCRIPTS/$hook.sh" 2>&1); ec=$?
  if [[ $ec -eq 0 && -z "$out" ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s (exit=%s out=%s)\n' "$TEST_NAME" "$ec" "${out:0:120}"
  fi
done

# ---- fail-open when jq is missing -----------------------------------------

section "fail-open when jq is missing"

# Build a sandbox PATH dir that contains only the binaries we need (NOT jq),
# so `command -v jq` returns empty in the script.
SANDBOX_BIN=$(mktemp -d)
for bin in bash cat grep wc tr sed git mkdir rm head tail dirname date env; do
  if real=$(command -v "$bin" 2>/dev/null); then
    ln -s "$real" "$SANDBOX_BIN/$bin"
  fi
done
# Verify jq isn't reachable via this PATH
if env -i PATH="$SANDBOX_BIN" bash -c 'command -v jq' >/dev/null 2>&1; then
  printf '  \033[33m!\033[0m skipping fail-open test — jq still reachable in sandbox PATH\n'
else
  t "fails open (exit 0) when jq is missing"
  TESTS_RUN=$((TESTS_RUN + 1))
  out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' \
         | env -i PATH="$SANDBOX_BIN" bash "$SCRIPTS/jus-block-force-push.sh" 2>&1)
  ec=$?
  TEST_NAME="block-force-push fails open when jq absent"
  if [[ $ec -eq 0 ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s (exit=%d, out=%s)\n' "$TEST_NAME" "$ec" "${out:0:200}"
  fi
fi
rm -rf "$SANDBOX_BIN"

# ---- plugin & marketplace manifests -------------------------------------------

section "plugin & marketplace manifests"

# These validate the distributable manifests in .claude-plugin/ — the files that
# make `/plugin marketplace add juscribe/jus-skills` → `/plugin install jus@jus-skills`
# resolve. Published-repo root == contents of jus/, so plugin.json and
# marketplace.json both live at the root's .claude-plugin/ and the plugin source
# is "./" (the plugin manifest IS the marketplace root).
PLUGIN_ROOT="$(cd "$HOOKS_DIR/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
MARKET_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"

# assert_jq <name> <file> <jq_boolean_filter>
assert_jq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1" file="$2" filter="$3"
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

assert_jq "plugin.json is valid JSON named \"jus\"" "$PLUGIN_JSON" '.name == "jus"'
# The version is asserted by shape, not value: plugin.json is the single source
# of truth (bin/publish-skills reads it), so pinning a literal here just breaks
# the harness on every release bump (that exact drift shipped once: 1.0.1→1.1.0).
assert_jq "plugin.json version is strict semver" "$PLUGIN_JSON" '.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")'
assert_jq "plugin.json has a non-empty description" "$PLUGIN_JSON" '.description | type == "string" and length > 0'
assert_jq "plugin.json has an author name" "$PLUGIN_JSON" '.author.name | type == "string" and length > 0'

assert_jq "marketplace.json is valid JSON named \"jus-skills\"" "$MARKET_JSON" '.name == "jus-skills"'
assert_jq "marketplace.json has an owner name" "$MARKET_JSON" '.owner.name | type == "string" and length > 0'
assert_jq "marketplace.json lists the jus plugin" "$MARKET_JSON" '[.plugins[].name] | index("jus") != null'
assert_jq "jus plugin source is \"./\" (manifest at marketplace root)" "$MARKET_JSON" '.plugins[] | select(.name == "jus") | .source == "./"'
# Avoid the dual-version staleness gotcha: marketplace entry must NOT pin a
# version — plugin.json is the single source of truth and silently wins.
assert_jq "marketplace entry omits version (plugin.json is authority)" "$MARKET_JSON" '.plugins[] | select(.name == "jus") | has("version") | not'

# Cross-manifest consistency: the marketplace's plugin name must match plugin.json's.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="marketplace plugin name matches plugin.json name"
if [[ "$(jq -r '.name' "$PLUGIN_JSON")" == "$(jq -r '.plugins[0].name' "$MARKET_JSON")" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

# A distributable public repo needs a LICENSE; plugin.json should declare it.
assert_jq "plugin.json declares the MIT license" "$PLUGIN_JSON" '.license == "MIT"'

LICENSE_FILE="$PLUGIN_ROOT/LICENSE"
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="LICENSE file exists and is the MIT license held by Juscribe"
if [[ -f "$LICENSE_FILE" ]] && grep -q "MIT License" "$LICENSE_FILE" && grep -q "Juscribe" "$LICENSE_FILE"; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

# gemini-extension.json ships at the bundle root for Gemini/Antigravity installs.
# Between releases this may legitimately differ from plugin.json, so the mismatch
# is a warning here rather than a failure — a hard assert would re-create the
# "version bump breaks the harness" drift this section guards against.
#
# ⚠️ This comment used to claim the versions were "synced at release time by a
# bin/publish-skills step (#1885)". THAT STEP DID NOT EXIST, so the leniency was
# traded for a guarantee nobody had built and the manifests drifted unchecked
# (#2137). Enforcement now lives where it belongs — bin/publish-skills refuses to
# publish when they disagree — and bin/jus-set-version sets them all at once.
GEMINI_JSON="$PLUGIN_ROOT/gemini-extension.json"
assert_jq "gemini-extension.json is valid JSON named \"jus\"" "$GEMINI_JSON" '.name == "jus"'
assert_jq "gemini-extension.json version is strict semver" "$GEMINI_JSON" '.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")'
PLUGIN_VERSION="$(jq -r '.version' "$PLUGIN_JSON")"
GEMINI_VERSION="$(jq -r '.version' "$GEMINI_JSON")"
if [[ "$GEMINI_VERSION" != "$PLUGIN_VERSION" ]]; then
  printf '  \033[33m⚠\033[0m gemini-extension.json version (%s) differs from plugin.json (%s) — synced at release time (#1885)\n' "$GEMINI_VERSION" "$PLUGIN_VERSION"
fi

# ---- codex adapter (#1976) -------------------------------------------------

section "codex adapter"

# The Codex payloads for Bash and Stop match the shared scripts' contract
# byte-for-byte (tool_name "Bash" + tool_input.command string; Stop carries
# stop_hook_active + cwd). The one divergence is file edits: Codex sends
# tool_name "apply_patch" with tool_input.command holding raw patch text —
# jus-codex-adapt.sh normalizes that to the Edit shape before delegating.
CODEX_DIR="$PLUGIN_ROOT/hooks/codex"
CODEX_ADAPT="$CODEX_DIR/scripts/jus-codex-adapt.sh"
SCRIPTS_DIR="$HOOKS_DIR/scripts"
# Built by concatenation so the suppression blocker (rightly) doesn't see a
# contiguous pattern literal in this file's own text.
SUPP_MARK="eslint""-disable"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codex hooks.json is valid JSON with the Codex nesting"
if jq -e '.hooks.PreToolUse[0].matcher and .hooks.Stop[0].hooks[0].command' "$CODEX_DIR/hooks.json" >/dev/null 2>&1; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codex hooks.json references only scripts that exist in the bundle"
missing=0
[[ -f "$CODEX_DIR/hooks.json" ]] || missing=1
while IFS= read -r cmd; do
  for word in $cmd; do
    case "$word" in
      "$SKILLS_PREFIX"*)
        resolved="$PLUGIN_ROOT/${word#"$SKILLS_PREFIX"}"
        [[ -x "$resolved" ]] || missing=$((missing + 1))
        ;;
    esac
  done
done < <(jq -r '.hooks[][].hooks[].command' "$CODEX_DIR/hooks.json" 2>/dev/null)
if [[ "$missing" -eq 0 ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (%d missing)\n' "$TEST_NAME" "$missing"
fi

# codex_hook <expected_exit> <name> <payload> <script...>
codex_hook() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local expected="$1" name="$2" payload="$3"; shift 3
  local ec=0
  "$@" <<<"$payload" >/dev/null 2>&1 || ec=$?
  if [[ "$ec" -eq "$expected" ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m✗\033[0m %s (exit=%d, want %d)\n' "$name" "$ec" "$expected"
  fi
}

CODEX_ENV_EXTRA='"transcript_path":"/tmp/t.jsonl","model":"gpt-5.2-codex","permission_mode":"default","turn_id":"turn_1","tool_use_id":"tooluse_1"'

codex_hook 2 "codex: apply_patch adding a lint suppression is blocked through the shim" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"cx1\",\"cwd\":\"/tmp\",${CODEX_ENV_EXTRA},\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: app/a.ts\\n@@\\n-const x = 1\\n+// ${SUPP_MARK}-next-line\\n+const x: any = 1\\n*** End Patch\"}}" \
  "$CODEX_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

codex_hook 0 "codex: apply_patch REMOVING a suppression passes through the shim" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"cx1\",\"cwd\":\"/tmp\",${CODEX_ENV_EXTRA},\"tool_name\":\"apply_patch\",\"tool_input\":{\"command\":\"*** Begin Patch\\n*** Update File: app/a.ts\\n@@\\n-// ${SUPP_MARK}-next-line\\n-const x: any = 1\\n+const x = 1\\n*** End Patch\"}}" \
  "$CODEX_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

codex_hook 2 "codex: Bash blocker payload blocks via the shim passthrough" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"cx1\",\"cwd\":\"/tmp\",${CODEX_ENV_EXTRA},\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push ${FORCE_FLAG:---force} origin main\"}}" \
  "$CODEX_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

# ⚠️ CODEX SENDS tool_response AS A STRING, AND #1873 CAME BACK THROUGH IT (#4207).
#
# The tracker reads `.tool_response.interrupted`. jq cannot index a string, so
# it errors with "Cannot index string" and EXITS 5 — and `set -euo pipefail`
# carries that straight out of the hook. Codex logs "PostToolUse Failed" and
# carries on, so nothing looks broken.
#
# What actually breaks is the lint gate: the tracker dies before
# `last_linted_at` is written, so jus-pre-commit-gate's state-tracked rule
# never sees a lint on Codex — which is exactly the dead-rule failure #1873
# fixed for Claude Code, re-entering through a different payload shape. The
# git-commit branch that clears edits.log never runs either.
#
# The fix is in the SHARED script rather than the adapter, because a hook that
# dies on an unexpected field type violates the fail-open doctrine the sweep
# above enforces for malformed JSON. A string tool_response is well-formed
# JSON of an unexpected shape; it must degrade, not throw.
codex_hook 0 "codex: PostToolUse Bash survives a STRING tool_response (does not exit 5)" \
  "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"cx-str\",\"cwd\":\"/tmp\",${CODEX_ENV_EXTRA},\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"},\"tool_response\":\"hi\"}" \
  "$SCRIPTS_DIR/jus-post-bash-tracker.sh"

# The consequence, asserted rather than inferred: a lint command with Codex's
# payload shape must still record last_linted_at.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="codex: a lint command with a STRING tool_response still records last_linted_at"
CODEX_STATE_DIR="$(mktemp -d)"
(
  export CLAUDE_PLUGIN_DATA="$CODEX_STATE_DIR"
  printf '%s' "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"cx-lint\",\"cwd\":\"/tmp\",${CODEX_ENV_EXTRA},\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pnpm exec eslint app.ts\"},\"tool_response\":\"done\"}" \
    | "$SCRIPTS_DIR/jus-post-bash-tracker.sh" >/dev/null 2>&1
)
if find "$CODEX_STATE_DIR" -name last_linted_at 2>/dev/null | grep -q .; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi
rm -rf "$CODEX_STATE_DIR"

CODEX_STOP_REPO="$(mktemp -d)"
git -C "$CODEX_STOP_REPO" init -q
echo dirty > "$CODEX_STOP_REPO/file.txt"
codex_hook 2 "codex: Stop payload with a dirty tree blocks (field-compatible)" \
  "{\"hook_event_name\":\"Stop\",\"session_id\":\"cx1\",\"cwd\":\"$CODEX_STOP_REPO\",\"stop_hook_active\":false,\"last_assistant_message\":null,${CODEX_ENV_EXTRA}}" \
  "$SCRIPTS_DIR/jus-stop-uncommitted.sh"
codex_hook 0 "codex: Stop payload with stop_hook_active=true passes (loop guard)" \
  "{\"hook_event_name\":\"Stop\",\"session_id\":\"cx1\",\"cwd\":\"$CODEX_STOP_REPO\",\"stop_hook_active\":true,\"last_assistant_message\":null,${CODEX_ENV_EXTRA}}" \
  "$SCRIPTS_DIR/jus-stop-uncommitted.sh"
rm -rf "$CODEX_STOP_REPO"

# ---- copilot adapter (#4260) -----------------------------------------------

section "copilot adapter"

# ⚠️ THESE PAYLOADS ARE MEASURED, NOT GUESSED, AND THE DISTINCTION IS THE WHOLE
# LESSON OF #4260. The first cut of this section built its edit payloads from
# Claude's field names — `file_path`, `old_string`, `new_string` — because the
# copilot CLI was not installed and nobody could look. Every test passed against
# a payload Copilot never sends, while a live `# rubocop:disable` edit went
# straight into the file. The names below (`edit`, `create`, `view`, and
# `path`/`old_str`/`new_str`/`file_text`) are read off the `tools` array copilot
# 1.0.85 sends its model. The live run is in the README; keep these in step with
# it, and never re-derive a payload from another vendor's shape.
COPILOT_DIR="$PLUGIN_ROOT/hooks/copilot"
COPILOT_ADAPT="$COPILOT_DIR/scripts/jus-copilot-adapt.sh"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="copilot hooks.json is valid JSON in Copilot's own shape"
if jq -e '.version == 1 and (.hooks.preToolUse | length > 0) and .hooks.agentStop[0].bash' \
  "$COPILOT_DIR/hooks.json" >/dev/null 2>&1; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="copilot hooks.json references only scripts that exist in the bundle"
missing=0
while IFS= read -r cmd; do
  for word in $cmd; do
    case "$word" in
      "$SKILLS_PREFIX"*)
        resolved="$PLUGIN_ROOT/${word#"$SKILLS_PREFIX"}"
        [[ -x "$resolved" ]] || missing=$((missing + 1))
        ;;
    esac
  done
done < <(jq -r '.hooks[][].bash' "$COPILOT_DIR/hooks.json" 2>/dev/null)
if [[ "$missing" -eq 0 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (%d missing)\n' "$TEST_NAME" "$missing"
fi

# ⚠️ THIRTEEN, AND THE COUNT IS THE POINT. An adapter that registers twelve is
# not obviously wrong from reading it — the missing one just never fires. Claude
# registers jus-docs-nudge.sh twice (one matcher each); this manifest sets no
# matcher, so it appears once and the total is 12 lines for 13 registrations.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="copilot registers every shared hook exactly once"
copilot_scripts=$(jq -r '.hooks[][].bash' "$COPILOT_DIR/hooks.json" \
  | grep -oE 'jus-[a-z-]+\.sh' | grep -v 'jus-copilot-adapt.sh' | sort)
shared_scripts=$(find "$HOOKS_DIR/scripts" -maxdepth 1 -name 'jus-*.sh' -exec basename {} \; | sort)
if [[ "$copilot_scripts" == "$shared_scripts" ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
  comm -13 <(printf '%s\n' "$copilot_scripts") <(printf '%s\n' "$shared_scripts") | sed 's/^/      unregistered: /'
  comm -23 <(printf '%s\n' "$copilot_scripts") <(printf '%s\n' "$shared_scripts") | sed 's/^/      registered twice or unknown: /'
fi

# copilot_hook <expected_exit> <name> <payload> <script...>
copilot_hook() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local expected="$1" name="$2" payload="$3"; shift 3
  local ec=0
  "$@" <<<"$payload" >/dev/null 2>&1 || ec=$?
  if [[ "$ec" -eq "$expected" ]]; then
    printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want %d)\n' "$name" "$ec" "$expected"
  fi
}

# ⚠️ toolArgs IS A STRING HERE, exactly as GitHub's worked example shows. If the
# shim ever reads it as an object, `.command` comes back null and this test goes
# GREEN-to-RED in the useful direction: the force-push stops being blocked.
COPILOT_PUSH_ARGS='"{\"command\":\"git push --force origin main\"}"'
copilot_hook 2 "copilot: a force-push blocks through the shim (toolArgs re-parsed from a string)" \
  "{\"sessionId\":\"cp1\",\"timestamp\":1700000000000,\"cwd\":\"/tmp\",\"toolName\":\"bash\",\"toolArgs\":${COPILOT_PUSH_ARGS}}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

copilot_hook 0 "copilot: an ordinary push passes" \
  "{\"sessionId\":\"cp1\",\"timestamp\":1700000000000,\"cwd\":\"/tmp\",\"toolName\":\"bash\",\"toolArgs\":\"{\\\"command\\\":\\\"git push origin main\\\"}\"}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

copilot_hook 2 "copilot: --no-verify blocks through the shim" \
  "{\"sessionId\":\"cp1\",\"timestamp\":1700000000000,\"cwd\":\"/tmp\",\"toolName\":\"bash\",\"toolArgs\":\"{\\\"command\\\":\\\"git commit --no-verify -m x\\\"}\"}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-no-verify.sh"

# ⚠️ `edit` WITH `path`/`old_str`/`new_str` — Copilot's real shape, and the one
# that shipped unblocked. Reverting either the name map or the field map in the
# shim turns this test red, which is the only reason it exists.
copilot_hook 2 "copilot: a lint suppression is blocked on Copilot's real edit tool (path/old_str/new_str)" \
  "{\"sessionId\":\"cp1\",\"timestamp\":1700000000000,\"cwd\":\"/tmp\",\"toolName\":\"edit\",\"toolArgs\":\"{\\\"path\\\":\\\"app/a.ts\\\",\\\"old_str\\\":\\\"const x = 1\\\",\\\"new_str\\\":\\\"// ${SUPP_MARK}-next-line\\\\nconst x: any = 1\\\"}\"}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

copilot_hook 0 "copilot: an edit REMOVING a suppression passes" \
  "{\"sessionId\":\"cp1\",\"timestamp\":1700000000000,\"cwd\":\"/tmp\",\"toolName\":\"edit\",\"toolArgs\":\"{\\\"path\\\":\\\"app/a.ts\\\",\\\"old_str\\\":\\\"// ${SUPP_MARK}-next-line\\\\nconst x: any = 1\\\",\\\"new_str\\\":\\\"const x = 1\\\"}\"}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# `create` is Copilot's write tool and carries `file_text`, not `content`.
copilot_hook 2 "copilot: a suppression written by the create tool is blocked (file_text -> content)" \
  "{\"sessionId\":\"cp1\",\"timestamp\":1700000000000,\"cwd\":\"/tmp\",\"toolName\":\"create\",\"toolArgs\":\"{\\\"path\\\":\\\"app/a.ts\\\",\\\"file_text\\\":\\\"// ${SUPP_MARK}-next-line\\\\nconst x: any = 1\\\"}\"}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# The shape fallback still has to cover a tool NOT on the measured name list —
# a plugin tool, or a rename in a later release.
copilot_hook 2 "copilot: an UNKNOWN edit-shaped tool still blocks, by argument shape" \
  "{\"sessionId\":\"cp1\",\"timestamp\":1700000000000,\"cwd\":\"/tmp\",\"toolName\":\"str_replace_editor\",\"toolArgs\":\"{\\\"path\\\":\\\"app/a.ts\\\",\\\"old_str\\\":\\\"const x = 1\\\",\\\"new_str\\\":\\\"// ${SUPP_MARK}-next-line\\\\nconst x: any = 1\\\"}\"}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# ⚠️ ITS OWN dirty repo, not the shared $DIRTY_REPO. Sections above commit and
# clean that one, so reusing it makes this assertion depend on test ORDER — and
# a Stop guard that silently stops blocking is the failure least likely to be
# noticed from a green run.
COPILOT_DIRTY=$(mktemp -d)
git -C "$COPILOT_DIRTY" init -q
echo "uncommitted" > "$COPILOT_DIRTY/scratch.txt"

copilot_hook 2 "copilot: agentStop with a dirty tree blocks" \
  "{\"sessionId\":\"cp1\",\"timestamp\":1700000000000,\"cwd\":\"$COPILOT_DIRTY\",\"transcriptPath\":\"/tmp/t.jsonl\",\"stopReason\":\"end_turn\",\"stop_hook_active\":false}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-stop-uncommitted.sh"

copilot_hook 0 "copilot: agentStop with stop_hook_active=true passes (loop guard)" \
  "{\"sessionId\":\"cp1\",\"timestamp\":1700000000000,\"cwd\":\"$COPILOT_DIRTY\",\"transcriptPath\":\"/tmp/t.jsonl\",\"stopReason\":\"end_turn\",\"stop_hook_active\":true}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-stop-uncommitted.sh"

rm -rf "$COPILOT_DIRTY"

# ⚠️ THE ASYMMETRY TEST. Copilot denies on ANY non-zero exit; our scripts fail
# open and a crash exits 1. Without this collapse a broken hook would block a
# tool call it never meant to judge. `false` stands in for the crash.
copilot_hook 0 "copilot: a non-2 failure is collapsed to 0, so a broken hook cannot deny" \
  '{"sessionId":"cp1","cwd":"/tmp","toolName":"bash","toolArgs":"{}"}' \
  "$COPILOT_ADAPT" /usr/bin/false

# Already-Claude-shaped input is passed straight through. GitHub's reference
# describes PascalCase events as carrying snake_case fields; that is unverified,
# and this branch is what makes the shim correct either way.
copilot_hook 2 "copilot: an already-Claude-shaped payload passes through untouched" \
  "{\"session_id\":\"cp1\",\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --force origin main\"}}" \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

copilot_hook 0 "copilot: malformed JSON fails open" \
  'not json at all' \
  "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

# ⚠️ A BARE exit 2 REACHES THE MODEL AS "hook exited with code 2" AND NOTHING
# ELSE — measured against copilot 1.0.85. The blocker's stderr says what to do
# instead, and that is the half worth delivering, so the shim also emits
# Copilot's JSON deny form on stdout. If this goes red the block still happens
# and the agent is simply never told why.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="copilot: a block emits the JSON deny form carrying the blocker's reason"
copilot_deny_out=$(printf '%s' \
  '{"sessionId":"cp1","cwd":"/tmp","toolName":"bash","toolArgs":"{\"command\":\"git push --force origin main\"}"}' \
  | "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh" 2>/dev/null)
if jq -e '.permissionDecision == "deny" and (.permissionDecisionReason | test("NEVER force-push"))' \
  >/dev/null 2>&1 <<<"$copilot_deny_out"; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
fi

# ⚠️ The decision object belongs to TOOL events only. `hookSpecificOutput`, the
# shape Claude Code uses, was measured to fail OPEN on copilot — so an object on
# an event that has no permission to decide is a guess, and the shim does not
# make it. agentStop keeps the plain exit-2-plus-stderr form, which copilot
# renders to the terminal.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="copilot: an agentStop block emits NO decision object (not a tool event)"
COPILOT_STOP_DIRTY=$(mktemp -d)
git -C "$COPILOT_STOP_DIRTY" init -q
echo "uncommitted" > "$COPILOT_STOP_DIRTY/scratch.txt"
copilot_stop_out=$(printf '%s' \
  "{\"sessionId\":\"cp1\",\"cwd\":\"$COPILOT_STOP_DIRTY\",\"transcriptPath\":\"/tmp/t.jsonl\",\"stop_hook_active\":false}" \
  | "$COPILOT_ADAPT" "$SCRIPTS_DIR/jus-stop-uncommitted.sh" 2>/dev/null)
rm -rf "$COPILOT_STOP_DIRTY"
if [[ -z "$copilot_stop_out" ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (got: %s)\n' "$TEST_NAME" "$copilot_stop_out"
fi

# ---- cursor adapter (#4261) ------------------------------------------------

section "cursor adapter"

# ⚠️ THESE ARE UNIT TESTS; THE LIVE VERIFICATION IS IN hooks/cursor/README.md.
# Since #4261 the payload shapes below are the ones cursor-agent 2026.09.15-d2fe57e
# was measured to send, not the ones its documentation implies — the two differ on
# `cwd`, on `preToolUse`'s tool names, and on which events a headless `-p` run fires
# at all. Correct a shape here only against a captured payload.
CURSOR_DIR="$PLUGIN_ROOT/hooks/cursor"
CURSOR_ADAPT="$CURSOR_DIR/scripts/jus-cursor-adapt.sh"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="cursor hooks.json is valid JSON in Cursor's own shape"
if jq -e '.version == 1 and (.hooks.beforeShellExecution | length > 0) and .hooks.stop[0].command' \
  "$CURSOR_DIR/hooks.json" >/dev/null 2>&1; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="cursor hooks.json references only scripts that exist in the bundle"
missing=0
while IFS= read -r cmd; do
  for word in $cmd; do
    case "$word" in
      "$SKILLS_PREFIX"*)
        resolved="$PLUGIN_ROOT/${word#"$SKILLS_PREFIX"}"
        [[ -x "$resolved" ]] || missing=$((missing + 1))
        ;;
    esac
  done
done < <(jq -r '.hooks[][].command' "$CURSOR_DIR/hooks.json" 2>/dev/null)
if [[ "$missing" -eq 0 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (%d missing)\n' "$TEST_NAME" "$missing"
fi

# ⚠️ jus-docs-nudge.sh IS registered twice here, unlike on Copilot — Cursor has
# two distinct post events, so the two registrations fire on different things.
# That is why this compares the UNIQUE set rather than the line count.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="cursor registers every shared hook"
cursor_scripts=$(jq -r '.hooks[][].command' "$CURSOR_DIR/hooks.json" \
  | grep -oE 'jus-[a-z-]+\.sh' | grep -v 'jus-cursor-adapt.sh' | sort -u)
if [[ "$cursor_scripts" == "$shared_scripts" ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
  comm -13 <(printf '%s\n' "$cursor_scripts") <(printf '%s\n' "$shared_scripts") | sed 's/^/      unregistered: /'
fi

# cursor_hook <expected_exit> <name> <payload> <script...>
cursor_hook() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local expected="$1" name="$2" payload="$3"; shift 3
  local ec=0
  "$@" <<<"$payload" >/dev/null 2>&1 || ec=$?
  if [[ "$ec" -eq "$expected" ]]; then
    printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want %d)\n' "$name" "$ec" "$expected"
  fi
}

CURSOR_ENV='"conversation_id":"cv1","generation_id":"gen1","model":"composer-1","hook_event_name":"","cursor_version":"2.4.0","workspace_roots":["/tmp"],"transcript_path":"/tmp/t.jsonl"'

# beforeShellExecution carries `command` at the TOP level and no tool_name at
# all — the shim is what makes the five command blockers reachable.
cursor_hook 2 "cursor: beforeShellExecution force-push blocks (no tool_name in the payload)" \
  "{${CURSOR_ENV/\"hook_event_name\":\"\"/\"hook_event_name\":\"beforeShellExecution\"},\"command\":\"git push --force origin main\",\"cwd\":\"/tmp\",\"sandbox\":\"danger-full-access\"}" \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

cursor_hook 0 "cursor: an ordinary push passes" \
  "{${CURSOR_ENV/\"hook_event_name\":\"\"/\"hook_event_name\":\"beforeShellExecution\"},\"command\":\"git push origin main\",\"cwd\":\"/tmp\"}" \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

cursor_hook 2 "cursor: beforeShellExecution --no-verify blocks" \
  "{${CURSOR_ENV/\"hook_event_name\":\"\"/\"hook_event_name\":\"beforeShellExecution\"},\"command\":\"git commit --no-verify -m x\",\"cwd\":\"/tmp\"}" \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-no-verify.sh"

# preToolUse is the only pre-hook that sees an edit, and the tool NAME there is
# undocumented — so the shim infers Edit from old_string/new_string.
cursor_hook 2 "cursor: a lint suppression is blocked on preToolUse by argument shape" \
  "{${CURSOR_ENV/\"hook_event_name\":\"\"/\"hook_event_name\":\"preToolUse\"},\"tool_name\":\"write\",\"tool_use_id\":\"t1\",\"cwd\":\"/tmp\",\"tool_input\":{\"file_path\":\"app/a.ts\",\"old_string\":\"const x = 1\",\"new_string\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\"}}" \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

cursor_hook 0 "cursor: an edit REMOVING a suppression passes" \
  "{${CURSOR_ENV/\"hook_event_name\":\"\"/\"hook_event_name\":\"preToolUse\"},\"tool_name\":\"write\",\"cwd\":\"/tmp\",\"tool_input\":{\"file_path\":\"app/a.ts\",\"old_string\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\",\"new_string\":\"const x = 1\"}}" \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# ⚠️ THE TWO stop MAPPINGS, AND BOTH FAIL SILENTLY IN OPPOSITE DIRECTIONS.
# No cwd -> the hook never finds a repository and never fires. No loop guard ->
# it fires forever. Cursor's stop event carries neither field under our names.
CURSOR_DIRTY=$(mktemp -d)
git -C "$CURSOR_DIRTY" init -q
echo "uncommitted" > "$CURSOR_DIRTY/scratch.txt"

cursor_hook 2 "cursor: stop derives cwd from workspace_roots and sees the dirty tree" \
  "{\"conversation_id\":\"cv1\",\"hook_event_name\":\"stop\",\"workspace_roots\":[\"$CURSOR_DIRTY\"],\"status\":\"completed\",\"loop_count\":0}" \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-stop-uncommitted.sh"

cursor_hook 0 "cursor: stop with loop_count > 0 is the loop guard (maps to stop_hook_active)" \
  "{\"conversation_id\":\"cv1\",\"hook_event_name\":\"stop\",\"workspace_roots\":[\"$CURSOR_DIRTY\"],\"status\":\"completed\",\"loop_count\":1}" \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-stop-uncommitted.sh"

rm -rf "$CURSOR_DIRTY"

cursor_hook 0 "cursor: malformed JSON fails open" \
  'not json at all' \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

# ⚠️ `cwd` IS `""`, NOT NULL, ON EVERY EVENT THAT CARRIES IT (#4261).
# Measured against cursor-agent 2026.09.15-d2fe57e: `beforeShellExecution`,
# `preToolUse` and `postToolUse` all send an empty string. jq's `//` falls back
# on null and false only, so the shim used to hand the shared scripts `cwd: ""`
# — and `juscribe_sop_require_jus_project` then exits 0 and the guard allows
# what it exists to block.
#
# It has to run from a directory that is NOT a Juscribe project, because the
# shared scripts fall back to `$PWD` and that fallback is what hid this live:
# Cursor happens to spawn hooks with the workspace root as their cwd.
#
# ⚠️ AND IT HAS TO DROP `JUS_HOOKS_EVERYWHERE`, WHICH THIS HARNESS EXPORTS
# GLOBALLY (line 38). That flag is the first thing
# `juscribe_sop_require_jus_project` checks, so with it set the project lookup
# never runs at all and both of these pass — the empty-cwd one vacuously, over a
# shim that still has the bug.
CURSOR_WS=$(mktemp -d)
git -C "$CURSOR_WS" init -q
mkdir -p "$CURSOR_WS/.jus"
CURSOR_OUTSIDE=$(mktemp -d)

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME='cursor: an empty-string cwd falls back to workspace_roots'
cursor_empty_cwd_ec=0
( cd "$CURSOR_OUTSIDE" && env -u JUS_HOOKS_EVERYWHERE "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh" ) \
  >/dev/null 2>&1 \
  <<<"{\"conversation_id\":\"cv1\",\"hook_event_name\":\"beforeShellExecution\",\"workspace_roots\":[\"$CURSOR_WS\"],\"command\":\"git push --force origin main\",\"cwd\":\"\"}" \
  || cursor_empty_cwd_ec=$?
if [[ "$cursor_empty_cwd_ec" -eq 2 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want 2)\n' "$TEST_NAME" "$cursor_empty_cwd_ec"
fi

# The other direction: a non-empty cwd still wins over workspace_roots, because
# a shell can run outside the first root.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME='cursor: a non-empty cwd still wins over workspace_roots'
cursor_explicit_cwd_ec=0
( cd "$CURSOR_WS" && env -u JUS_HOOKS_EVERYWHERE "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh" ) \
  >/dev/null 2>&1 \
  <<<"{\"conversation_id\":\"cv1\",\"hook_event_name\":\"beforeShellExecution\",\"workspace_roots\":[\"$CURSOR_WS\"],\"command\":\"git push --force origin main\",\"cwd\":\"$CURSOR_OUTSIDE\"}" \
  || cursor_explicit_cwd_ec=$?
if [[ "$cursor_explicit_cwd_ec" -eq 0 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want 0)\n' "$TEST_NAME" "$cursor_explicit_cwd_ec"
fi

rm -rf "$CURSOR_WS" "$CURSOR_OUTSIDE"

# The preToolUse shapes Cursor was MEASURED to send, rather than the ones its
# docs imply: a shell call arrives as `Shell` with `{command, cwd, timeout}`,
# and a whole-file write as `Write` with `{file_path, content}` (#4261). The
# shim re-infers both from the shape, so these assert the inference agrees with
# the real vocabulary.
cursor_hook 2 "cursor: a preToolUse Shell call reaches the command blockers" \
  "{${CURSOR_ENV/\"hook_event_name\":\"\"/\"hook_event_name\":\"preToolUse\"},\"tool_name\":\"Shell\",\"cwd\":\"\",\"tool_input\":{\"command\":\"git commit --no-verify -m x\",\"cwd\":\"\",\"timeout\":30000}}" \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-no-verify.sh"

cursor_hook 2 "cursor: a preToolUse Write carries content, not old_string/new_string" \
  "{${CURSOR_ENV/\"hook_event_name\":\"\"/\"hook_event_name\":\"preToolUse\"},\"tool_name\":\"Write\",\"cwd\":\"/tmp\",\"tool_input\":{\"file_path\":\"app/a.ts\",\"content\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\"}}" \
  "$CURSOR_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# afterShellExecution carries `output` rather than tool_response, and the tracker
# reads the latter. A mismatch here is the #4207 failure shape again.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="cursor: afterShellExecution maps output -> tool_response for the bash tracker"
cursor_after=$(printf '%s' "{\"conversation_id\":\"cv1\",\"hook_event_name\":\"afterShellExecution\",\"workspace_roots\":[\"/tmp\"],\"command\":\"bin/rubocop app/a.rb\",\"output\":\"no offenses\",\"duration\":12}" \
  | "$CURSOR_ADAPT" /bin/cat 2>/dev/null)
if jq -e '.tool_name == "Bash" and .tool_input.command == "bin/rubocop app/a.rb" and .tool_response == "no offenses" and .cwd == "/tmp"' \
  >/dev/null 2>&1 <<<"$cursor_after"; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (got %s)\n' "$TEST_NAME" "${cursor_after:0:160}"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="cursor: afterFileEdit becomes the MultiEdit shape the edit hooks read"
cursor_edit=$(printf '%s' "{\"conversation_id\":\"cv1\",\"hook_event_name\":\"afterFileEdit\",\"workspace_roots\":[\"/tmp\"],\"file_path\":\"app/a.ts\",\"edits\":[{\"old_string\":\"a\",\"new_string\":\"b\"}]}" \
  | "$CURSOR_ADAPT" /bin/cat 2>/dev/null)
if jq -e '.tool_name == "MultiEdit" and .tool_input.file_path == "app/a.ts" and (.tool_input.edits | length == 1)' \
  >/dev/null 2>&1 <<<"$cursor_edit"; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (got %s)\n' "$TEST_NAME" "${cursor_edit:0:160}"
fi

# ⚠️ A TAB COMPLETION IS A SECOND EDIT EVENT, AND ONLY THE EDITOR HAS IT (#4429).
# Measured in Cursor 3.21.16 on 2026-09-20: an agent edit fires `afterFileEdit`
# and an accepted Tab completion fires `afterTabFileEdit` — never both, never
# the other one. So a manifest registering only the first is blind to every
# edit a Tab user makes, with nothing failing. The payload below is the one
# captured that day: the same `{file_path, edits[]}` shape, `model: "tab"`, a
# null `transcript_path`, and NO `cwd` FIELD AT ALL — not even the empty string
# the shell events send, so `workspace_roots` is the only workspace there is.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="cursor: afterTabFileEdit becomes MultiEdit and takes its cwd from workspace_roots"
cursor_tab=$(printf '%s' "{\"conversation_id\":\"cv1\",\"hook_event_name\":\"afterTabFileEdit\",\"model\":\"tab\",\"workspace_roots\":[\"/tmp\"],\"transcript_path\":null,\"file_path\":\"app/a.ts\",\"edits\":[{\"old_string\":\"\",\"new_string\":\"return x + 4\",\"range\":{\"start_line_number\":14}}]}" \
  | "$CURSOR_ADAPT" /bin/cat 2>/dev/null)
if jq -e '.tool_name == "MultiEdit" and .tool_input.file_path == "app/a.ts" and (.tool_input.edits | length == 1) and .cwd == "/tmp"' \
  >/dev/null 2>&1 <<<"$cursor_tab"; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (got %s)\n' "$TEST_NAME" "${cursor_tab:0:160}"
fi

# Normalising the shape is half of it: the event also has to be REGISTERED, and
# for the same scripts, or a Tab edit normalises perfectly and reaches nobody.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="cursor: afterTabFileEdit registers the same scripts as afterFileEdit"
cursor_edit_scripts=$(jq -r '.hooks.afterFileEdit[].command' "$CURSOR_DIR/hooks.json" | grep -oE 'jus-[a-z-]+\.sh' | grep -v 'jus-cursor-adapt.sh' | sort)
cursor_tab_scripts=$(jq -r '.hooks.afterTabFileEdit[].command' "$CURSOR_DIR/hooks.json" | grep -oE 'jus-[a-z-]+\.sh' | grep -v 'jus-cursor-adapt.sh' | sort)
if [[ -n "$cursor_tab_scripts" && "$cursor_tab_scripts" == "$cursor_edit_scripts" ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
  comm -13 <(printf '%s\n' "$cursor_tab_scripts") <(printf '%s\n' "$cursor_edit_scripts") | sed 's/^/      missing on afterTabFileEdit: /'
fi

# ⚠️ CURSOR'S OWN TRANSPORT, WHICH IS WHAT SETTLES THE `~` QUESTION (#4261).
# The tests above pipe a payload straight into the shim, so they prove the
# NORMALISATION and nothing about whether Cursor can reach these scripts at all.
# Cursor does not spawn the command directly: `executeCommandScript` builds
#
#     <command> <<'CURSOR_HOOK_EOF'
#     <payload JSON>
#     CURSOR_HOOK_EOF
#
# and hands that whole string to a shell — a heredoc is meaningful to nothing
# else. So the `~` in every manifest command is expanded by the SHELL, at word
# start, and these two run the real manifest line through that exact transport
# against a staged bundle. Read from cursor-agent 2026.09.15-d2fe57e's own
# bundle; if a future version spawns the command without a shell, these fail.
CURSOR_STAGE=$(mktemp -d)
mkdir -p "$CURSOR_STAGE/.jus-skills"
cp -R "$PLUGIN_ROOT/hooks" "$CURSOR_STAGE/.jus-skills/hooks"

# cursor_transport <expected_exit> <name> <payload>
# Reproduces Cursor's heredoc transport verbatim for the FIRST beforeShellExecution
# command in the manifest — the force-push guard.
cursor_transport() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local expected="$1" name="$2" payload="$3" ec=0
  local cmd
  cmd=$(jq -r '.hooks.beforeShellExecution[0].command' "$CURSOR_DIR/hooks.json")
  HOME="$CURSOR_STAGE" /bin/sh -c "$cmd <<'CURSOR_HOOK_EOF'
$payload
CURSOR_HOOK_EOF" >/dev/null 2>&1 || ec=$?
  if [[ "$ec" -eq "$expected" ]]; then
    printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want %d)\n' "$name" "$ec" "$expected"
  fi
}

cursor_transport 2 "cursor: the manifest's own command line blocks a force-push through Cursor's heredoc transport" \
  "{\"conversation_id\":\"cv1\",\"hook_event_name\":\"beforeShellExecution\",\"workspace_roots\":[\"/tmp\"],\"command\":\"git push --force origin main\",\"cwd\":\"/tmp\"}"

cursor_transport 0 "cursor: the same transport lets an ordinary push through" \
  "{\"conversation_id\":\"cv1\",\"hook_event_name\":\"beforeShellExecution\",\"workspace_roots\":[\"/tmp\"],\"command\":\"git push origin main\",\"cwd\":\"/tmp\"}"

rm -rf "$CURSOR_STAGE"

# ---- antigravity adapter (#4262) -------------------------------------------

section "antigravity adapter"

# ⚠️ THE ONLY ADAPTER THAT TRANSLATES THE RESPONSE, so these assert on STDOUT as
# well as on exit codes. Every other tool here takes exit 2 + stderr as a block;
# Antigravity wants a JSON answer on stdout for every invocation.
#
# ⚠️ AND THE ANSWER IS A DIFFERENT SHAPE PER EVENT, which is what makes the
# negative assertions below the load-bearing ones. Antigravity parses each
# hook's stdout with protojson, DiscardUnknown OFF, against a per-event message
# — so an extra key is a hard error and a PreToolUse hook that errors makes the
# tool call FAIL. Measured on agy 1.2.5 (#4262): the first cut of this adapter
# emitted `allow_tool`/`deny_reason` alongside `decision`/`reason` as a hedge
# against a contested contract, and that hedge would have broken every tool call
# rather than half of one.
AGY_DIR="$PLUGIN_ROOT/hooks/antigravity"
AGY_ADAPT="$AGY_DIR/scripts/jus-antigravity-adapt.sh"

# ⚠️ PreToolUse/PostToolUse ARE GROUPED (`matcher` + `hooks`); PreInvocation and
# Stop ARE FLAT — a list of handler objects with `command` directly on them.
# Wrapping the flat two is not a tolerated variation: the engine answers
# `invalid hook "…": command hook must specify 'command'` and rejects the WHOLE
# FILE, so one wrapped entry disables all twelve hooks (#4262, measured).
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="antigravity hooks.json groups the tool events and leaves PreInvocation/Stop flat"
if jq -e '
  ."jus-hard-rules".enabled == true
  and (."jus-hard-rules".PreToolUse[0].hooks | length > 0)
  and (."jus-hard-rules".PostToolUse[0].hooks | length > 0)
  and (."jus-hard-rules".PreInvocation | length > 0)
  and (."jus-hard-rules".PreInvocation | all(has("command") and (has("hooks") | not)))
  and (."jus-hard-rules".Stop | all(has("command") and (has("hooks") | not)))
' "$AGY_DIR/hooks.json" >/dev/null 2>&1; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
fi

# Every command in the manifest, whichever shape its event uses.
agy_commands() {
  jq -r '."jus-hard-rules" | to_entries[] | select(.value | type == "array") | .key as $event
    | .value[] | (if has("hooks") then .hooks[] else . end) | "\($event) \(.command)"' \
    "$AGY_DIR/hooks.json" 2>/dev/null
}

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="antigravity hooks.json references only scripts that exist in the bundle"
missing=0
while IFS= read -r line; do
  for word in $line; do
    case "$word" in
      "$SKILLS_PREFIX"*)
        resolved="$PLUGIN_ROOT/${word#"$SKILLS_PREFIX"}"
        [[ -x "$resolved" ]] || missing=$((missing + 1))
        ;;
    esac
  done
done < <(agy_commands)
if [[ "$missing" -eq 0 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (%d missing)\n' "$TEST_NAME" "$missing"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="antigravity registers every shared hook"
agy_scripts=$(agy_commands | grep -oE 'jus-[a-z-]+\.sh' | grep -v 'jus-antigravity-adapt.sh' | sort -u)
if [[ "$agy_scripts" == "$shared_scripts" ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
  comm -13 <(printf '%s\n' "$agy_scripts") <(printf '%s\n' "$shared_scripts") | sed 's/^/      unregistered: /'
fi

# ⚠️ THE EVENT NAME IS AN ARGUMENT, so it can disagree with the key it is
# registered under — and nothing at runtime would say so. A `Stop` handler
# invoked as `PreToolUse` answers `{"decision":"allow"}`, which protojson
# rejects for Stop, which fails the hook silently.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="antigravity: every command passes the event it is registered under"
agy_event_mismatch=0
while IFS= read -r line; do
  registered="${line%% *}"
  passed=$(printf '%s' "$line" | grep -oE 'jus-antigravity-adapt\.sh [A-Za-z]+' | awk '{print $2}')
  [[ "$registered" == "$passed" ]] || agy_event_mismatch=$((agy_event_mismatch + 1))
done < <(agy_commands)
if [[ "$agy_event_mismatch" -eq 0 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (%d mismatched)\n' "$TEST_NAME" "$agy_event_mismatch"
fi

# agy_says <jq-filter> <name> <payload> <adapt-args...> — asserts on the STDOUT
# object, because on Antigravity that is the verdict.
agy_says() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local filter="$1" name="$2" payload="$3"; shift 3
  local out ec=0
  out=$("$@" <<<"$payload" 2>/dev/null) || ec=$?
  if [[ "$ec" -eq 0 ]] && jq -e "$filter" >/dev/null 2>&1 <<<"$out"; then
    printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, out=%s)\n' "$name" "$ec" "${out:0:160}"
  fi
}

AGY_STATE=$(mktemp -d)
export JUS_ANTIGRAVITY_STATE="$AGY_STATE"

# ⚠️ THE COMMAND IS NESTED TWO LEVELS DEEPER THAN ANYWHERE ELSE, and the cwd
# arrives as a SIBLING of it rather than at the top level. This payload is a
# captured one, not an invented one (#4262).
AGY_PUSH='{"conversationId":"agy1","toolCall":{"name":"run_command","args":{"CommandLine":"git push --force origin main","Cwd":"/tmp"}},"stepIdx":2,"workspacePaths":[]}'

# ⚠️ THE NEGATIVE HALF IS THE POINT. `allow_tool` and `deny_reason` are the
# Antigravity developer guide's spelling and protojson rejects both — emitting
# them alongside the real keys does not hedge, it fails the tool call.
agy_says '.decision == "deny" and (.reason | length > 0) and (has("allow_tool") | not) and (has("deny_reason") | not)' \
  "antigravity: a force-push under .toolCall.args.CommandLine denies, with no rejected keys" \
  "$AGY_PUSH" "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-force-push.sh"

# ⚠️ AN ALLOW STILL HAS TO ANSWER. Antigravity requires stdout on every
# invocation, so silence is not "no opinion" — it may wedge the agent loop.
agy_says '.decision == "allow" and (has("allow_tool") | not)' \
  "antigravity: an ordinary push answers allow rather than nothing" \
  '{"conversationId":"agy1","toolCall":{"name":"run_command","args":{"CommandLine":"git push origin main","Cwd":"/tmp"}}}' \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-force-push.sh"

agy_says '.decision == "deny"' \
  "antigravity: --no-verify denies" \
  '{"conversationId":"agy1","toolCall":{"name":"run_command","args":{"CommandLine":"git commit --no-verify -m x","Cwd":"/tmp"}}}' \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-no-verify.sh"

# ⚠️ THE FILE TOOLS ARE `write_to_file` AND `replace_file_content`, AND THEIR
# ARGUMENTS ARE `TargetFile`/`CodeContent`/`TargetContent`/`ReplacementContent`.
# None of Claude's names (`file_path`, `old_string`, `content`, `edits`) appears
# anywhere in an Antigravity payload, so the first cut's argument-shape
# inference matched nothing and every edit reached the guards unrecognised.
agy_says '.decision == "deny"' \
  "antigravity: a lint suppression in replace_file_content denies" \
  "{\"conversationId\":\"agy1\",\"toolCall\":{\"name\":\"replace_file_content\",\"args\":{\"TargetFile\":\"/tmp/app/a.ts\",\"TargetContent\":\"const x = 1\",\"ReplacementContent\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\"}}}" \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

agy_says '.decision == "allow"' \
  "antigravity: an edit REMOVING a suppression allows" \
  "{\"conversationId\":\"agy1\",\"toolCall\":{\"name\":\"replace_file_content\",\"args\":{\"TargetFile\":\"/tmp/app/a.ts\",\"TargetContent\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\",\"ReplacementContent\":\"const x = 1\"}}}" \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

agy_says '.decision == "deny"' \
  "antigravity: a lint suppression in write_to_file denies" \
  "{\"conversationId\":\"agy1\",\"toolCall\":{\"name\":\"write_to_file\",\"args\":{\"TargetFile\":\"/tmp/app/a.ts\",\"CodeContent\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\"}}}" \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# ── the cwd, which the payload never carries ─────────────────────────────────
# ⚠️ ANTIGRAVITY SENDS NO `cwd` AND `workspacePaths` CAME BACK `[]` ON EVERY
# CAPTURED PAYLOAD. The shared scripts gate on the cwd being inside a repo
# holding `.jus/` (#4404), so a shim that derives nothing disarms all twelve —
# and the $PWD fallback cannot save it either, because Antigravity runs a hook
# in the directory containing hooks.json, which for the documented global
# install is `~/.gemini/config`.
#
# ⚠️ THESE DROP `JUS_HOOKS_EVERYWHERE`, WHICH THIS HARNESS EXPORTS GLOBALLY
# (line 38). That flag is the first thing `juscribe_sop_require_jus_project`
# checks, so with it set the project lookup never runs and these pass vacuously
# over a shim that derives nothing.
AGY_WS=$(mktemp -d)
git -C "$AGY_WS" init -q
mkdir -p "$AGY_WS/.jus"
AGY_OUTSIDE=$(mktemp -d)

agy_derives() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local filter="$1" name="$2" payload="$3"; shift 3
  local out ec=0
  out=$( cd "$AGY_OUTSIDE" && env -u JUS_HOOKS_EVERYWHERE "$@" <<<"$payload" 2>/dev/null ) || ec=$?
  if [[ "$ec" -eq 0 ]] && jq -e "$filter" >/dev/null 2>&1 <<<"$out"; then
    printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, out=%s)\n' "$name" "$ec" "${out:0:160}"
  fi
}

agy_derives '.decision == "deny"' \
  "antigravity: run_command takes its cwd from .toolCall.args.Cwd" \
  "{\"conversationId\":\"agycwd\",\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"git push --force origin main\",\"Cwd\":\"$AGY_WS\"}}}" \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-force-push.sh"

# ⚠️ A FILE TOOL CARRIES NO `Cwd` AT ALL — measured null on both of them — so the
# only thing naming a directory is the absolute `TargetFile`.
agy_derives '.decision == "deny"' \
  "antigravity: a file tool takes its cwd from the TargetFile directory" \
  "{\"conversationId\":\"agyfile\",\"toolCall\":{\"name\":\"write_to_file\",\"args\":{\"TargetFile\":\"$AGY_WS/app/nested/a.ts\",\"CodeContent\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\"}}}" \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

agy_derives '.decision == "allow"' \
  "antigravity: a tool call outside a Juscribe project is left alone" \
  "{\"conversationId\":\"agyout\",\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"git push --force origin main\",\"Cwd\":\"$AGY_OUTSIDE\"}}}" \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-force-push.sh"

# ⚠️ AN EMPTY STRING IN THE CWD CHAIN BEATS THE REMEMBERED DIRECTORY (#4428).
# jq's `//` falls back on `null` and `false` only, so `workspacePaths[0]` of
# `""` — or a `cwd` key present and empty — used to win over `$remembered`, the
# one thing #4262 built the state file for. Same symptom as every other case in
# this class: the guard allows, silently, and nothing anywhere says why.
#
# Primed with a real tool event so the conversation HAS a remembered cwd; the
# second call is the one under test, and it names only empty sources.
AGY_EMPTY=$(mktemp -d)
git -C "$AGY_EMPTY" init -q
mkdir -p "$AGY_EMPTY/.jus"

printf '{"conversationId":"agyempty","toolCall":{"name":"run_command","args":{"CommandLine":"ls","Cwd":"%s"}}}' "$AGY_EMPTY" \
  | ( cd "$AGY_OUTSIDE" && env -u JUS_HOOKS_EVERYWHERE "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-force-push.sh" ) >/dev/null 2>&1

agy_derives '.decision == "deny"' \
  "antigravity: an empty workspacePaths entry does not beat the remembered cwd" \
  "{\"conversationId\":\"agyempty\",\"workspacePaths\":[\"\"],\"cwd\":\"\",\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"git push --force origin main\"}}}" \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-force-push.sh"

# The other direction: a real Cwd still wins over everything remembered, because
# a command can run outside the directory the last one did.
agy_derives '.decision == "allow"' \
  "antigravity: a real Cwd still wins over the remembered one" \
  "{\"conversationId\":\"agyempty\",\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"git push --force origin main\",\"Cwd\":\"$AGY_OUTSIDE\"}}}" \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-force-push.sh"

rm -rf "$AGY_EMPTY"

# ── Stop, which really does block here ───────────────────────────────────────
# ⚠️ NOT ADVISORY, unlike Cursor and Kimi. `decision: "continue"` refuses the
# stop and re-enters the loop with `reason` injected as a system message.
AGY_DIRTY=$(mktemp -d)
git -C "$AGY_DIRTY" init -q
mkdir -p "$AGY_DIRTY/.jus"
echo "uncommitted" > "$AGY_DIRTY/scratch.txt"

# Stop carries no cwd of its own, so the shim replays the one the tool events
# recorded for this conversation — which is the whole reason it records it.
printf '{"conversationId":"agystop","toolCall":{"name":"run_command","args":{"CommandLine":"ls","Cwd":"%s"}}}' "$AGY_DIRTY" \
  | env -u JUS_HOOKS_EVERYWHERE "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-force-push.sh" >/dev/null 2>&1

agy_says '.decision == "continue" and (.reason | test("STOP BLOCKED")) and (has("allow_tool") | not)' \
  "antigravity: Stop with a dirty tree answers continue, replaying the remembered cwd" \
  '{"conversationId":"agystop","executionNum":0,"terminationReason":"NO_TOOL_CALL","fullyIdle":true}' \
  env -u JUS_HOOKS_EVERYWHERE "$AGY_ADAPT" Stop "$SCRIPTS_DIR/jus-stop-uncommitted.sh"

AGY_CLEAN=$(mktemp -d)
git -C "$AGY_CLEAN" init -q
mkdir -p "$AGY_CLEAN/.jus"
agy_says '. == {}' \
  "antigravity: Stop with nothing to say answers an empty object" \
  "{\"conversationId\":\"agyclean\",\"cwd\":\"$AGY_CLEAN\",\"executionNum\":0}" \
  "$AGY_ADAPT" Stop "$SCRIPTS_DIR/jus-stop-uncommitted.sh"

rm -rf "$AGY_DIRTY" "$AGY_CLEAN"

# ── PreInvocation, and the PostToolUse text it delivers ──────────────────────
# ⚠️ `PreInvocation` REJECTS `decision` OUTRIGHT — protojson failed at line 1:2,
# the first key. Its only channel to the model is `injectSteps`.
AGY_STUBS=$(mktemp -d)
AGY_NUDGE="$AGY_STUBS/nudge.sh"
cat > "$AGY_NUDGE" <<'NUDGESH'
#!/usr/bin/env bash
echo "a nudge for the model" >&2
exit 0
NUDGESH
chmod +x "$AGY_NUDGE"

# ⚠️ NOT `/bin/true` — it does not exist on macOS, only `/usr/bin/true`, and the
# shim treats a non-executable target as "nothing to ask" and answers neutrally.
# A quiet hook that really runs is the only way to tell the two apart.
AGY_QUIET="$AGY_STUBS/quiet.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$AGY_QUIET"
chmod +x "$AGY_QUIET"

agy_says '.injectSteps[0].ephemeralMessage == "a nudge for the model" and (has("decision") | not)' \
  "antigravity: PreInvocation carries a nudge as injectSteps, never as decision" \
  '{"conversationId":"agynudge","invocationNum":0}' \
  "$AGY_ADAPT" PreInvocation "$AGY_NUDGE"

agy_says '. == {}' \
  "antigravity: PreInvocation with nothing to say answers an empty object" \
  '{"conversationId":"agyquiet","invocationNum":0}' \
  "$AGY_ADAPT" PreInvocation "$AGY_QUIET"

# ⚠️ A PostToolUse HOOK HAS NO CHANNEL TO THE MODEL — its contract is `{}` and
# there is no field to carry a message. So the shim buffers the text and the
# next PreInvocation delivers it, which is the same route Kimi's adapter takes
# for the same reason. Without this, two of the twelve are inert.
agy_says '. == {}' \
  "antigravity: PostToolUse answers an empty object even when the hook spoke" \
  '{"conversationId":"agybuf","stepIdx":1,"toolCall":{"name":"run_command","args":{"CommandLine":"ls","Cwd":"/tmp"}}}' \
  "$AGY_ADAPT" PostToolUse "$AGY_NUDGE"

agy_says '.injectSteps[0].ephemeralMessage | test("a nudge for the model")' \
  "antigravity: the next PreInvocation delivers what PostToolUse could not say" \
  '{"conversationId":"agybuf","invocationNum":1}' \
  "$AGY_ADAPT" PreInvocation "$AGY_QUIET"

agy_says '. == {}' \
  "antigravity: the buffer is drained, not replayed forever" \
  '{"conversationId":"agybuf","invocationNum":2}' \
  "$AGY_ADAPT" PreInvocation "$AGY_QUIET"

# ── fail-open, per event ─────────────────────────────────────────────────────
# ⚠️ A CRASHING HOOK MUST STILL SPEAK, AND IN THE RIGHT SHAPE. Antigravity fails
# the tool call when a PreToolUse hook's answer does not parse, so the fallback
# is the one path that absolutely cannot emit a foreign key.
agy_says '.decision == "allow"' \
  "antigravity: a crashing PreToolUse hook answers allow rather than staying silent" \
  '{"conversationId":"agy1","toolCall":{"name":"run_command","args":{"CommandLine":"ls","Cwd":"/tmp"}}}' \
  "$AGY_ADAPT" PreToolUse /usr/bin/false

agy_says '. == {}' \
  "antigravity: a crashing Stop hook answers an empty object, not an allow" \
  '{"conversationId":"agy1","executionNum":0}' \
  "$AGY_ADAPT" Stop /usr/bin/false

agy_says '.decision == "allow"' \
  "antigravity: malformed JSON answers allow" \
  'not json at all' \
  "$AGY_ADAPT" PreToolUse "$SCRIPTS_DIR/jus-block-force-push.sh"

agy_says '. == {}' \
  "antigravity: malformed JSON on PreInvocation answers an empty object" \
  'not json at all' \
  "$AGY_ADAPT" PreInvocation "$SCRIPTS_DIR/jus-ticket-claim-nudge.sh"

rm -rf "$AGY_WS" "$AGY_OUTSIDE" "$AGY_STATE" "$AGY_STUBS"
unset JUS_ANTIGRAVITY_STATE

# ---- gemini adapter (#4419) ------------------------------------------------

section "gemini adapter"

# ⚠️ GEMINI CLI IS NOT SUNSET, WHATEVER TWO OF OUR DOCS SAID. The Antigravity
# adapter was built on the premise that it had been replaced on 2026-06-18.
# Measured 2026-09-19 against the npm registry: `latest` 0.60.0, `nightly`
# 0.62.0-nightly.20260919 cut that morning, Apache-2.0.
#
# ⚠️ AND IT IS THE THINNEST SHIM IN THE BUNDLE. Every field the shared scripts
# read already carries Claude Code's name — session_id, transcript_path, cwd,
# hook_event_name, tool_name, tool_input, file_path, old_string, new_string,
# content, command, stop_hook_active — read out of the published 0.60.0
# package's own `bundle/docs/hooks/reference.md` and `bundle/docs/tools/`. So
# only the TOOL NAME is translated.
#
# ⚠️ NOT LIVE-VERIFIED. Gemini CLI is not installed on the authoring machine, and
# the README says so in its first box. These tests are what machine-checkable
# evidence there is.
GEM_DIR="$PLUGIN_ROOT/hooks/gemini"
GEM_ADAPT="$GEM_DIR/scripts/jus-gemini-adapt.sh"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="gemini settings.json is valid JSON in Gemini's hooks shape"
if jq -e '(.hooks.BeforeTool | length > 0) and (.hooks.AfterTool | length > 0)
          and .hooks.BeforeAgent[0].hooks[0].command
          and .hooks.AfterAgent[0].hooks[0].command' \
  "$GEM_DIR/settings.json" >/dev/null 2>&1; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="gemini settings.json references only scripts that exist in the bundle"
missing=0
while IFS= read -r cmd; do
  for word in $cmd; do
    case "$word" in
      "$SKILLS_PREFIX"*)
        resolved="$PLUGIN_ROOT/${word#"$SKILLS_PREFIX"}"
        [[ -x "$resolved" ]] || missing=$((missing + 1))
        ;;
    esac
  done
done < <(jq -r '.hooks[][].hooks[].command' "$GEM_DIR/settings.json" 2>/dev/null)
if [[ "$missing" -eq 0 ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (%d missing)\n' "$TEST_NAME" "$missing"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="gemini registers every shared hook"
gem_scripts=$(jq -r '.hooks[][].hooks[].command' "$GEM_DIR/settings.json" \
  | grep -oE 'jus-[a-z-]+\.sh' | grep -v 'jus-gemini-adapt.sh' | sort -u)
if [[ "$gem_scripts" == "$shared_scripts" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
  comm -23 <(printf '%s\n' "$shared_scripts") <(printf '%s\n' "$gem_scripts") | sed 's/^/      missing: /'
fi

# ⚠️ THE MATCHER IS THE WHOLE POINT. Every guard gates on `tool_name == "Bash"`,
# and Gemini's shell tool is `run_shell_command` — so a matcher written `Bash`
# would fire on nothing while the configured list looked complete.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="gemini matches Gemini's own tool names, not Claude's"
if jq -e '[.hooks.BeforeTool[].matcher] | (index("^run_shell_command$") != null)
          and (index("^(replace|write_file)$") != null)' \
  "$GEM_DIR/settings.json" >/dev/null 2>&1; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

# The four names, each mapped to what the shared scripts gate on.
# ⚠️ `/bin/cat` AS THE TARGET, so the assertion reads the NORMALISED payload
# rather than a guard's exit code. The shim `exec`s its target with the rewritten
# JSON on stdin, so cat hands it straight back.
gem_maps() { # <gemini tool> <expected>
  TESTS_RUN=$((TESTS_RUN + 1))
  local raw="$1" want="$2" got
  got=$(printf '{"tool_name":"%s","tool_input":{"command":"ls"}}' "$raw" \
    | "$GEM_ADAPT" /bin/cat 2>/dev/null | jq -r '.tool_name' 2>/dev/null) || got=""
  if [[ "$got" == "$want" ]]; then
    printf '  \033[32m✓\033[0m gemini: %s maps to %s\n' "$raw" "$want"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("gemini: $raw maps to $want")
    printf '  \033[31m✗\033[0m gemini: %s maps to %s (got %s)\n' "$raw" "$want" "${got:-<nothing>}"
  fi
}

gem_maps run_shell_command Bash
gem_maps replace Edit
gem_maps write_file Write
gem_maps read_file Read

# ⚠️ AN UNKNOWN NAME MUST NOT BE DROPPED. MCP tools arrive as
# `mcp_<server>_<tool>`, and a map that answered "" for them would hand every
# guard an empty tool_name — which reads as "not a tool this guard cares about"
# and passes silently. The shape fallback catches it.
gem_maps mcp_srv_thing Bash

# ---- qwen adapter (#4263) --------------------------------------------------

section "qwen adapter"

# Qwen's hook contract is modelled on Claude Code's — exit 2 blocks and passes
# stderr to the model, and the payload already uses our field names — so the shim
# translates only the TOOL NAME. ⚠️ **The names and the field shapes below are
# MEASURED against qwen 0.24.0, not read off the docs** (#4263): `run_shell_command`
# carries `command`, `edit` carries `file_path`/`old_string`/`new_string`, and
# `write_file` carries `file_path`/`content` — all read off the `tools` array qwen
# sends its model. That check is here because #4260 shipped a Copilot shim built
# from Claude Code's field names, which Copilot never sends, and its tests were
# green because they shared the assumption. The live run is in the README.
QWEN_DIR="$PLUGIN_ROOT/hooks/qwen"
QWEN_ADAPT="$QWEN_DIR/scripts/jus-qwen-adapt.sh"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="qwen settings.json is valid JSON carrying a hooks key"
if jq -e '.hooks.PreToolUse[0].matcher and .hooks.Stop[0].hooks[0].command and .hooks.UserPromptSubmit' \
  "$QWEN_DIR/settings.json" >/dev/null 2>&1; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="qwen settings.json references only scripts that exist in the bundle"
missing=0
while IFS= read -r cmd; do
  for word in $cmd; do
    case "$word" in
      "$SKILLS_PREFIX"*)
        resolved="$PLUGIN_ROOT/${word#"$SKILLS_PREFIX"}"
        [[ -x "$resolved" ]] || missing=$((missing + 1))
        ;;
    esac
  done
done < <(jq -r '.hooks[][].hooks[].command' "$QWEN_DIR/settings.json" 2>/dev/null)
if [[ "$missing" -eq 0 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (%d missing)\n' "$TEST_NAME" "$missing"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="qwen registers every shared hook"
qwen_scripts=$(jq -r '.hooks[][].hooks[].command' "$QWEN_DIR/settings.json" \
  | grep -oE 'jus-[a-z-]+\.sh' | grep -v 'jus-qwen-adapt.sh' | sort -u)
if [[ "$qwen_scripts" == "$shared_scripts" ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
  comm -13 <(printf '%s\n' "$qwen_scripts") <(printf '%s\n' "$shared_scripts") | sed 's/^/      unregistered: /'
fi

# ⚠️ QwenLM/qwen-code#11823 ASSERTED RATHER THAN REMEMBERED. A matcher written
# with a Claude Code tool name never fires in qwen-code — "Bash" matches nothing,
# "Write|Edit" matches `edit` and not `write_file`. A hook that does not fire
# produces no error at all, so this is the shape that would ship silently inert.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="qwen matchers use Qwen's tool names, never Claude Code's (#11823)"
qwen_matchers=$(jq -r '.hooks[][] | select(has("matcher")) | .matcher' "$QWEN_DIR/settings.json")
if grep -qE '\b(Bash|Edit|Write|MultiEdit|Read)\b' <<<"$qwen_matchers"; then
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
  printf '      offending matcher(s): %s\n' "$(grep -E '\b(Bash|Edit|Write|MultiEdit|Read)\b' <<<"$qwen_matchers" | tr '\n' ' ')"
else
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
fi

# qwen_hook <expected_exit> <name> <payload> <script...>
qwen_hook() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local expected="$1" name="$2" payload="$3"; shift 3
  local ec=0
  "$@" <<<"$payload" >/dev/null 2>&1 || ec=$?
  if [[ "$ec" -eq "$expected" ]]; then
    printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want %d)\n' "$name" "$ec" "$expected"
  fi
}

QWEN_ENV='"session_id":"qw1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","permission_mode":"default","tool_use_id":"tu1"'

qwen_hook 2 "qwen: run_shell_command force-push blocks after the rename to Bash" \
  "{${QWEN_ENV},\"tool_name\":\"run_shell_command\",\"tool_input\":{\"command\":\"git push --force origin main\"}}" \
  "$QWEN_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

# ⚠️ WITHOUT the rename this passes — the guard reads tool_name != "Bash" and
# exits 0. That is the whole failure this shim exists to prevent, so it is worth
# knowing the test above is the one that catches it.
qwen_hook 0 "qwen: an ordinary push passes" \
  "{${QWEN_ENV},\"tool_name\":\"run_shell_command\",\"tool_input\":{\"command\":\"git push origin main\"}}" \
  "$QWEN_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

qwen_hook 2 "qwen: run_shell_command --no-verify blocks" \
  "{${QWEN_ENV},\"tool_name\":\"run_shell_command\",\"tool_input\":{\"command\":\"git commit --no-verify -m x\"}}" \
  "$QWEN_ADAPT" "$SCRIPTS_DIR/jus-block-no-verify.sh"

# `edit` and `write_file` are the exact pair #11823 reports a Claude-named
# matcher splitting — "Write|Edit" fires for one and not the other.
qwen_hook 2 "qwen: a lint suppression via 'edit' blocks" \
  "{${QWEN_ENV},\"tool_name\":\"edit\",\"tool_input\":{\"file_path\":\"app/a.ts\",\"old_string\":\"const x = 1\",\"new_string\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\"}}" \
  "$QWEN_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

qwen_hook 2 "qwen: a lint suppression via 'write_file' blocks too (the #11823 pair)" \
  "{${QWEN_ENV},\"tool_name\":\"write_file\",\"tool_input\":{\"file_path\":\"app/a.ts\",\"content\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\"}}" \
  "$QWEN_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

qwen_hook 0 "qwen: an edit REMOVING a suppression passes" \
  "{${QWEN_ENV},\"tool_name\":\"edit\",\"tool_input\":{\"file_path\":\"app/a.ts\",\"old_string\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\",\"new_string\":\"const x = 1\"}}" \
  "$QWEN_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# ✅ Stop is a REAL gate on Qwen, unlike Cursor (#4261) and Antigravity (#4262).
QWEN_DIRTY=$(mktemp -d)
git -C "$QWEN_DIRTY" init -q
echo "uncommitted" > "$QWEN_DIRTY/scratch.txt"

qwen_hook 2 "qwen: Stop with a dirty tree BLOCKS — no degradation on this tool" \
  "{\"session_id\":\"qw1\",\"cwd\":\"$QWEN_DIRTY\",\"stop_hook_active\":false,\"last_assistant_message\":\"done\"}" \
  "$QWEN_ADAPT" "$SCRIPTS_DIR/jus-stop-uncommitted.sh"

qwen_hook 0 "qwen: Stop with stop_hook_active=true passes (loop guard)" \
  "{\"session_id\":\"qw1\",\"cwd\":\"$QWEN_DIRTY\",\"stop_hook_active\":true,\"last_assistant_message\":\"done\"}" \
  "$QWEN_ADAPT" "$SCRIPTS_DIR/jus-stop-uncommitted.sh"

rm -rf "$QWEN_DIRTY"

qwen_hook 0 "qwen: malformed JSON fails open" \
  'not json at all' \
  "$QWEN_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

# ⚠️ THE NUDGES SPEAK TO THE MODEL THROUGH A JSON OBJECT, NOT THROUGH PLAIN TEXT,
# and only one of those two channels exists. Measured on qwen 0.24.0: a PostToolUse
# hook printing bare text injects NOTHING, while
# `hookSpecificOutput.additionalContext` is added to the model's context — which is
# exactly the shape jus-start-comment-nudge.sh and jus-docs-nudge.sh emit. So the
# shim must leave stdout alone. A shim that "tidied" it would silence every nudge
# while every blocker kept working, and no test that only checks exit codes
# would notice.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="qwen: a nudge's additionalContext JSON survives the shim unaltered"
qwen_nudge_out=$(printf '%s' '{"session_id":"q1","cwd":"/tmp","tool_name":"edit","tool_input":{"file_path":"/tmp/a.rb"}}' \
  | "$QWEN_ADAPT" /bin/echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"nudge text"}}' 2>/dev/null)
if jq -e '.hookSpecificOutput.additionalContext == "nudge text"' >/dev/null 2>&1 <<<"$qwen_nudge_out"; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
fi

# ---- windsurf adapter (#4264) ----------------------------------------------

section "windsurf adapter"

# ⚠️ THE ONLY ADAPTER WITH NO AUTOMATABLE VERIFICATION AT ALL. Cascade hooks run
# inside the IDE — no CLI, no headless mode — so these tests are the whole of the
# machine-checkable evidence and the README carries a manual recipe for the rest.
# What they DO establish is that the shim maps Cascade's action-named events onto
# the shapes the shared scripts read.
WS_DIR="$PLUGIN_ROOT/hooks/windsurf"
WS_ADAPT="$WS_DIR/scripts/jus-windsurf-adapt.sh"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="windsurf hooks.json is valid JSON in Cascade's shape"
if jq -e '(.hooks.pre_run_command | length > 0) and .hooks.pre_write_code[0].command and .hooks.post_cascade_response[0].command' \
  "$WS_DIR/hooks.json" >/dev/null 2>&1; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="windsurf hooks.json references only scripts that exist in the bundle"
missing=0
while IFS= read -r cmd; do
  for word in $cmd; do
    case "$word" in
      "$SKILLS_PREFIX"*)
        resolved="$PLUGIN_ROOT/${word#"$SKILLS_PREFIX"}"
        [[ -x "$resolved" ]] || missing=$((missing + 1))
        ;;
    esac
  done
done < <(jq -r '.hooks[][].command' "$WS_DIR/hooks.json" 2>/dev/null)
if [[ "$missing" -eq 0 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (%d missing)\n' "$TEST_NAME" "$missing"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="windsurf registers every shared hook"
ws_scripts=$(jq -r '.hooks[][].command' "$WS_DIR/hooks.json" \
  | grep -oE 'jus-[a-z-]+\.sh' | grep -v 'jus-windsurf-adapt.sh' | sort -u)
if [[ "$ws_scripts" == "$shared_scripts" ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
  comm -13 <(printf '%s\n' "$ws_scripts") <(printf '%s\n' "$shared_scripts") | sed 's/^/      unregistered: /'
fi

# ⚠️ ONLY THE FIVE pre_* EVENTS CAN BLOCK. A blocker registered on a post_* event
# would run, print, and never refuse — the enforcement-becomes-advice failure,
# arrived at by a typo rather than by a vendor limit.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="windsurf registers every BLOCKING hook on a pre_* event"
ws_blockers_wrong=$(jq -r '
  .hooks | to_entries[]
  | select(.key | startswith("pre_") | not)
  | .value[].command
' "$WS_DIR/hooks.json" | grep -oE 'jus-block-[a-z-]+\.sh|jus-pre-commit-gate\.sh' | sort -u)
if [[ -z "$ws_blockers_wrong" ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s\n' "$TEST_NAME"
  printf '      on a non-blocking event: %s\n' "$(tr '\n' ' ' <<<"$ws_blockers_wrong")"
fi

# ws_hook <expected_exit> <name> <payload> <script...>
ws_hook() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local expected="$1" name="$2" payload="$3"; shift 3
  local ec=0
  "$@" <<<"$payload" >/dev/null 2>&1 || ec=$?
  if [[ "$ec" -eq "$expected" ]]; then
    printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want %d)\n' "$name" "$ec" "$expected"
  fi
}

WS_ENV='"trajectory_id":"tr1","execution_id":"ex1","timestamp":"2026-09-16T00:00:00Z","model_name":"swe-1.5"'

ws_hook 2 "windsurf: pre_run_command force-push blocks (command_line nested in tool_info)" \
  "{\"agent_action_name\":\"pre_run_command\",${WS_ENV},\"tool_info\":{\"command_line\":\"git push --force origin main\",\"cwd\":\"/tmp\"}}" \
  "$WS_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

ws_hook 0 "windsurf: an ordinary push passes" \
  "{\"agent_action_name\":\"pre_run_command\",${WS_ENV},\"tool_info\":{\"command_line\":\"git push origin main\",\"cwd\":\"/tmp\"}}" \
  "$WS_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

ws_hook 2 "windsurf: pre_run_command --no-verify blocks" \
  "{\"agent_action_name\":\"pre_run_command\",${WS_ENV},\"tool_info\":{\"command_line\":\"git commit --no-verify -m x\",\"cwd\":\"/tmp\"}}" \
  "$WS_ADAPT" "$SCRIPTS_DIR/jus-block-no-verify.sh"

ws_hook 2 "windsurf: pre_write_code blocks a lint suppression" \
  "{\"agent_action_name\":\"pre_write_code\",${WS_ENV},\"tool_info\":{\"file_path\":\"app/a.ts\",\"edits\":[{\"old_string\":\"const x = 1\",\"new_string\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\"}]}}" \
  "$WS_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

ws_hook 0 "windsurf: an edit REMOVING a suppression passes" \
  "{\"agent_action_name\":\"pre_write_code\",${WS_ENV},\"tool_info\":{\"file_path\":\"app/a.ts\",\"edits\":[{\"old_string\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\",\"new_string\":\"const x = 1\"}]}}" \
  "$WS_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# ⚠️ post_cascade_response CARRIES NO cwd AT ALL. Cascade runs the hook with
# working_directory defaulting to the workspace root, so $PWD is the answer —
# and without that fallback the dirty-tree hook finds no repository and stays
# silent, which looks exactly like a clean tree. This runs the shim from INSIDE
# a dirty repo with no cwd in the payload, which is the only way to catch it.
WS_DIRTY=$(mktemp -d)
git -C "$WS_DIRTY" init -q
echo "uncommitted" > "$WS_DIRTY/scratch.txt"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="windsurf: post_cascade_response finds the repo via \$PWD when the payload has no cwd"
ws_ec=0
(cd "$WS_DIRTY" && printf '%s' "{\"agent_action_name\":\"post_cascade_response\",${WS_ENV},\"tool_info\":{\"response\":\"done\"}}" \
  | "$WS_ADAPT" "$SCRIPTS_DIR/jus-stop-uncommitted.sh" >/dev/null 2>&1) || ws_ec=$?
if [[ "$ws_ec" -eq 2 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want 2)\n' "$TEST_NAME" "$ws_ec"
fi

rm -rf "$WS_DIRTY"

# ⚠️ AN EMPTY `tool_info.cwd` BEATS BOTH FALLBACKS, `$PWD` INCLUDED (#4428).
# jq's `//` falls back on `null` and `false` only, so the three-deep chain
# collapses to the empty string and every guard loses its repository — which
# `juscribe_sop_require_jus_project` answers by exiting 0.
#
# ⚠️ IT HAS TO RUN FROM OUTSIDE A JUSCRIBE PROJECT, because `$PWD` is the third
# candidate and the shared scripts fall back to it as well: from inside a wired
# repository the broken chain is rescued twice over and the test passes on a
# shim that still has the bug.
#
# ⚠️ AND IT HAS TO DROP `JUS_HOOKS_EVERYWHERE`, WHICH THIS HARNESS EXPORTS
# GLOBALLY (line 38) — that flag is the first thing the project check reads, so
# with it set the lookup never runs and this passes vacuously.
#
# ⚠️ UNVERIFIED AGAINST CASCADE ITSELF. Windsurf is not installed on the machine
# this was written on and has no headless mode, so whether it ever sends an
# empty string is unmeasured. This pins the shim's contract, not a captured
# payload.
WS_WIRED=$(mktemp -d)
git -C "$WS_WIRED" init -q
mkdir -p "$WS_WIRED/.jus"
WS_OUTSIDE=$(mktemp -d)

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME='windsurf: an empty tool_info.cwd falls back to root_workspace_path'
ws_empty_ec=0
( cd "$WS_OUTSIDE" && env -u JUS_HOOKS_EVERYWHERE "$WS_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh" ) \
  >/dev/null 2>&1 \
  <<<"{\"agent_action_name\":\"pre_run_command\",${WS_ENV},\"tool_info\":{\"command_line\":\"git push --force origin main\",\"cwd\":\"\",\"root_workspace_path\":\"$WS_WIRED\"}}" \
  || ws_empty_ec=$?
if [[ "$ws_empty_ec" -eq 2 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want 2)\n' "$TEST_NAME" "$ws_empty_ec"
fi

# The other direction: a non-empty cwd still wins over root_workspace_path,
# because a command can run outside the workspace root.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME='windsurf: a non-empty tool_info.cwd still wins over root_workspace_path'
ws_explicit_ec=0
( cd "$WS_WIRED" && env -u JUS_HOOKS_EVERYWHERE "$WS_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh" ) \
  >/dev/null 2>&1 \
  <<<"{\"agent_action_name\":\"pre_run_command\",${WS_ENV},\"tool_info\":{\"command_line\":\"git push --force origin main\",\"cwd\":\"$WS_OUTSIDE\",\"root_workspace_path\":\"$WS_WIRED\"}}" \
  || ws_explicit_ec=$?
if [[ "$ws_explicit_ec" -eq 0 ]]; then
  printf '  \033[32m\xe2\x9c\x93\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m\xe2\x9c\x97\033[0m %s (exit=%d, want 0)\n' "$TEST_NAME" "$ws_explicit_ec"
fi

rm -rf "$WS_WIRED" "$WS_OUTSIDE"

ws_hook 0 "windsurf: malformed JSON fails open" \
  'not json at all' \
  "$WS_ADAPT" "$SCRIPTS_DIR/jus-block-force-push.sh"

# ---- kimi manifest agreement + config load (#4208) --------------------------

section "kimi manifest agreement"

# ⚠️ THE TWO KIMI MANIFESTS MUST CARRY THE SAME HOOKS, and until #4208 nothing
# said so. config-hooks.toml is appended to ~/.kimi-code/config.toml;
# kimi.plugin.json is the /plugins install. A user gets ONE of them, so a hook
# in one and not the other means an enforcement rule that exists or not
# depending on how they installed — with nothing to tell them which they got.
#
# They had in fact been disagreeing: the plugin registered
# jus-ticket-claim-nudge and the TOML did not. Checking each against the CLAUDE
# manifest (the parity section below) does not catch this on its own, because
# an exception entry covering both surfaces excuses the pair together.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="the two kimi manifests register the same shared hooks"
km_toml=$(grep -oE 'jus-[a-z-]+\.sh' "$PLUGIN_ROOT/hooks/kimi-code/config-hooks.toml" | sort -u)
km_json=$(grep -oE 'jus-[a-z-]+\.sh' "$PLUGIN_ROOT/kimi.plugin.json" | sort -u)
if [[ "$km_toml" == "$km_json" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
  comm -23 <(printf '%s\n' "$km_toml") <(printf '%s\n' "$km_json") | sed 's/^/      only in config-hooks.toml: /'
  comm -13 <(printf '%s\n' "$km_toml") <(printf '%s\n' "$km_json") | sed 's/^/      only in kimi.plugin.json: /'
fi

# The two blockers #4208 added, against the PreToolUse/Bash payload captured
# from a live kimi-code 0.29.2 session (same shape the section below uses).
KIMI_PRE='"hook_event_name":"PreToolUse","session_id":"km-4208","cwd":"/tmp","tool_call_id":"call_9"'

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="kimi: blocker-date nudge runs on the captured PreToolUse/Bash shape"
if printf '%s' "{${KIMI_PRE},\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"}}" \
     | "$SCRIPTS/jus-blocker-date-nudge.sh" >/dev/null 2>&1; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="kimi: accepted-manifest blocker runs on the captured PreToolUse/Bash shape"
if printf '%s' "{${KIMI_PRE},\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"}}" \
     | "$SCRIPTS/jus-block-accepted-manifest-edit.sh" >/dev/null 2>&1; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

# ⚠️ THE SCHEMA REJECTS UNKNOWN FIELDS AND AN EXTRA KEY FAILS THE WHOLE CONFIG
# LOAD, so "the TOML parses" is not the check — "kimi accepts it" is. `kimi
# doctor` is that check, and KIMI_CODE_HOME redirects the config root so it
# runs against a copy rather than the user's own 0600 ~/.kimi-code/config.toml.
#
# Skipped, not failed, where kimi is absent: this suite ships to machines that
# will never have it, and a hard requirement would make the bundle's own tests
# depend on an install nobody promised.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="kimi doctor accepts the shipped hook config (skipped if kimi absent)"
KIMI_BIN="${KIMI_BIN:-$HOME/.kimi-code/bin/kimi}"
if [[ ! -x "$KIMI_BIN" ]]; then
  printf '  \033[33m-\033[0m %s — kimi not installed\n' "$TEST_NAME"
  TESTS_RUN=$((TESTS_RUN - 1))
else
  KIMI_TEST_HOME="$(mktemp -d)"
  cp "$PLUGIN_ROOT/hooks/kimi-code/config-hooks.toml" "$KIMI_TEST_HOME/config.toml"
  if KIMI_CODE_HOME="$KIMI_TEST_HOME" "$KIMI_BIN" doctor 2>&1 | grep -q "All checked config files are valid"; then
    printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
    KIMI_CODE_HOME="$KIMI_TEST_HOME" "$KIMI_BIN" doctor 2>&1 | sed 's/^/      /' | head -8
  fi
  rm -rf "$KIMI_TEST_HOME"
fi

# ---- adapter hook parity (#4207) --------------------------------------------

section "adapter hook parity"

# Every shared hook the CLAUDE manifest registers must also be registered by
# each adapter, or be named in ADAPTER_EXCEPTIONS with the reason it cannot be.
#
# ⚠️ THIS IS THE CHECK THAT WAS MISSING, AND ITS ABSENCE IS WHY THREE HOOKS
# DRIFTED. jus/hooks/hooks.json and jus/hooks/codex/hooks.json were last
# touched in the SAME commit, so git history reads as if the adapters were
# kept in step — while jus-block-accepted-manifest-edit (added 2026-08-10),
# jus-blocker-date-nudge (2026-09-07) and jus-ticket-claim-nudge had never
# been registered on Codex at all. The fail-open sweep above already derives
# its list from hooks.json rather than typing one (#3507); nothing compared
# the manifests to each other.
#
# An exception is a LINE SOMEONE WROTE, which is the whole point: an adapter
# that genuinely cannot carry a hook says so here, and an adapter that merely
# forgot one fails. Format: "<adapter>:<script>=<reason>".
ADAPTER_EXCEPTIONS=(
  # ⚠️ jus-ticket-claim-nudge IS registered on Kimi and must not be excepted
  # (#4208). #4207 excepted it here as "superseded by jus-kimi-prompt-nudge on
  # the same event" — an inference, not something the README says, and
  # kimi.plugin.json already contradicted it by registering both. They do
  # different jobs: the Kimi nudge is a dirty-tree commit reminder, the claim
  # nudge fetches the ticket a prompt names and feeds it back as context. The
  # TOML was the surface missing it, and the two Kimi manifests had been
  # disagreeing about it since before either was checked against the other.
  #
  # Kimi: PostToolUse is observe-only — the trackers run and write session
  # state, but nothing they PRINT reaches the model, so a nudge there is
  # inert by construction (hooks/kimi-code/README.md).
  "kimi-code:jus-docs-nudge.sh=PostToolUse is observe-only on Kimi; printed output never reaches the model"
  "kimi-code:jus-start-comment-nudge.sh=PostToolUse is observe-only on Kimi; no channel reaches the model"
  # ⚠️ NOT deliberate — the same drift #4207 fixed on Codex, left here because
  # kimi-code is not installed on the machine that found it and this project
  # does not register hooks it cannot fire. See #4208.
  # The same three apply to the plugin manifest: they are properties of Kimi,
  # not of which install path carries the rules.
  "kimi-plugin:jus-docs-nudge.sh=PostToolUse is observe-only on Kimi; printed output never reaches the model"
  "kimi-plugin:jus-start-comment-nudge.sh=PostToolUse is observe-only on Kimi; no channel reaches the model"
)

# The shared hooks are the ones in hooks/scripts/ — an adapter's own shim
# (jus-codex-adapt.sh, jus-kimi-adapt.sh) is not a shared hook and must not
# count toward parity in either direction.
SHARED_HOOKS=$(cd "$HOOKS_DIR/scripts" && ls jus-*.sh 2>/dev/null | sort)

adapter_registered() {   # <manifest-path>
  grep -oE 'jus-[a-z-]+\.sh' "$1" 2>/dev/null | sort -u
}

CLAUDE_REGISTERED=$(adapter_registered "$HOOKS_DIR/hooks.json")

# ⚠️ kimi-code has TWO manifests and #4207's guard read only one (#4208).
# config-hooks.toml is the append-to-~/.kimi-code/config.toml path;
# kimi.plugin.json is the `/plugins` install path, carrying the same rules with
# plugin-relative paths. Either can drift from the other, and a hook present in
# one and absent from the other is invisible to a guard that reads one of them.
for adapter_spec in "codex:$PLUGIN_ROOT/hooks/codex/hooks.json" \
                    "gemini:$PLUGIN_ROOT/hooks/gemini/settings.json" \
                    "kimi-code:$PLUGIN_ROOT/hooks/kimi-code/config-hooks.toml" \
                    "kimi-plugin:$PLUGIN_ROOT/kimi.plugin.json"; do
  adapter_name="${adapter_spec%%:*}"
  adapter_file="${adapter_spec#*:}"

  TESTS_RUN=$((TESTS_RUN + 1))
  TEST_NAME="$adapter_name registers every shared hook the Claude manifest does (or excepts it)"

  if [[ ! -f "$adapter_file" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s (manifest not found: %s)\n' "$TEST_NAME" "$adapter_file"
    continue
  fi

  adapter_has=$(adapter_registered "$adapter_file")
  unexplained=()
  for hook in $SHARED_HOOKS; do
    # Only hooks the Claude manifest itself registers are in scope — a script
    # sitting in scripts/ that nothing registers anywhere is a different bug.
    grep -qx "$hook" <<<"$CLAUDE_REGISTERED" || continue
    grep -qx "$hook" <<<"$adapter_has" && continue
    excepted=0
    for exc in "${ADAPTER_EXCEPTIONS[@]}"; do
      [[ "${exc%%=*}" == "$adapter_name:$hook" ]] && { excepted=1; break; }
    done
    [[ "$excepted" -eq 1 ]] || unexplained+=("$hook")
  done

  if [[ "${#unexplained[@]}" -eq 0 ]]; then
    printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
    for u in "${unexplained[@]}"; do
      printf '      unregistered and unexplained: %s\n' "$u"
    done
  fi
done

# An exception naming a hook that IS registered is stale — it would go on
# excusing an absence that has been fixed, which is how this list rots into
# the thing it replaced.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="no ADAPTER_EXCEPTIONS entry excuses a hook that is actually registered"
stale=()
for exc in "${ADAPTER_EXCEPTIONS[@]}"; do
  key="${exc%%=*}"; a="${key%%:*}"; h="${key#*:}"
  case "$a" in
    codex)       f="$PLUGIN_ROOT/hooks/codex/hooks.json" ;;
    kimi-code)   f="$PLUGIN_ROOT/hooks/kimi-code/config-hooks.toml" ;;
    kimi-plugin) f="$PLUGIN_ROOT/kimi.plugin.json" ;;
    *)         f="" ;;
  esac
  [[ -n "$f" && -f "$f" ]] || continue
  adapter_registered "$f" | grep -qx "$h" && stale+=("$key")
done
if [[ "${#stale[@]}" -eq 0 ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (stale: %s)\n' "$TEST_NAME" "${stale[*]}"
fi

# ---- kimi-code adapter (#1977) ----------------------------------------------

section "kimi-code adapter"

# Kimi Code payloads use Claude's tool names with one renamed key — the
# empirically captured shapes (kimi-code 0.29.2) are Bash {command},
# Edit {new_string, old_string, path}, Write {content, path}. The suppression
# blocker's keys all match; jus-kimi-adapt.sh maps path → file_path for the
# trackers. Stop carries stop_hook_active + cwd, same as Claude/Codex.
KIMI_DIR="$PLUGIN_ROOT/hooks/kimi-code"
KIMI_ADAPT="$KIMI_DIR/scripts/jus-kimi-adapt.sh"
KIMI_NUDGE="$KIMI_DIR/scripts/jus-kimi-prompt-nudge.sh"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="kimi config snippet exists, uses only blockable/observe events, bare-matcher Stop"
kimi_cfg_ok=1
if [[ ! -f "$KIMI_DIR/config-hooks.toml" ]]; then
  kimi_cfg_ok=0
else
  grep -qE '^event = "(PreToolUse|PostToolUse|UserPromptSubmit|Stop)"$' "$KIMI_DIR/config-hooks.toml" || kimi_cfg_ok=0
  # The Stop rule must not carry a matcher (Stop matches against an empty string).
  if awk '/^event = "Stop"/{f=1;next} f&&/^matcher/{print "BAD"} /^\[\[hooks\]\]/{f=0}' "$KIMI_DIR/config-hooks.toml" | grep -q BAD; then
    kimi_cfg_ok=0
  fi
fi
if [[ "$kimi_cfg_ok" -eq 1 ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="kimi config snippet references only scripts that exist in the bundle"
missing=0
[[ -f "$KIMI_DIR/config-hooks.toml" ]] || missing=1
while IFS= read -r cmd; do
  for word in $cmd; do
    case "$word" in
      "$SKILLS_PREFIX"*)
        resolved="$PLUGIN_ROOT/${word#"$SKILLS_PREFIX"}"
        [[ -x "$resolved" ]] || missing=$((missing + 1))
        ;;
    esac
  done
done < <(sed -n 's/^command = "\(.*\)"$/\1/p' "$KIMI_DIR/config-hooks.toml" 2>/dev/null)
if [[ "$missing" -eq 0 ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (%d missing)\n' "$TEST_NAME" "$missing"
fi

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="kimi.plugin.json: name/skills/sessionStart/hooks shape + resolvable paths"
kimi_plugin_ok=1
KIMI_PLUGIN="$PLUGIN_ROOT/kimi.plugin.json"
if ! jq -e '.name == "jus" and .skills == "./skills/" and (.sessionStart.skill | type == "string") and ([.hooks[] | keys[]] - ["event","matcher","command","timeout"] | length == 0)' "$KIMI_PLUGIN" >/dev/null 2>&1; then
  kimi_plugin_ok=0
else
  ss_skill=$(jq -r '.sessionStart.skill' "$KIMI_PLUGIN")
  [[ -f "$PLUGIN_ROOT/skills/$ss_skill/SKILL.md" ]] || kimi_plugin_ok=0
  while IFS= read -r cmd; do
    for word in $cmd; do
      case "$word" in
        "./"*) [[ -x "$PLUGIN_ROOT/${word#./}" ]] || kimi_plugin_ok=0 ;;
      esac
    done
  done < <(jq -r '.hooks[].command' "$KIMI_PLUGIN" 2>/dev/null)
fi
if [[ "$kimi_plugin_ok" -eq 1 ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi

# Version drift vs plugin.json: warn-only between releases, ENFORCED at publish
# time by bin/publish-skills (#2137). Same treatment as
# gemini-extension.json.
KIMI_PLUGIN_VERSION="$(jq -r '.version // ""' "$KIMI_PLUGIN" 2>/dev/null)"
if [[ -n "$KIMI_PLUGIN_VERSION" && "$KIMI_PLUGIN_VERSION" != "$PLUGIN_VERSION" ]]; then
  printf '  \033[33m⚠\033[0m kimi.plugin.json version (%s) differs from plugin.json (%s) — synced at release time\n' "$KIMI_PLUGIN_VERSION" "$PLUGIN_VERSION"
fi

# Cursor Marketplace manifest (#1865): the submission unit is a plugin repo
# with .cursor-plugin/plugin.json; skills auto-discover from the existing
# skills/<name>/SKILL.md layout, so the manifest is metadata only.
CURSOR_PLUGIN="$PLUGIN_ROOT/.cursor-plugin/plugin.json"
assert_jq "cursor plugin manifest is valid JSON named \"jus\"" "$CURSOR_PLUGIN" '.name == "jus"'
assert_jq "cursor plugin manifest version is strict semver" "$CURSOR_PLUGIN" '.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")'
CURSOR_PLUGIN_VERSION="$(jq -r '.version // ""' "$CURSOR_PLUGIN" 2>/dev/null)"
if [[ -n "$CURSOR_PLUGIN_VERSION" && "$CURSOR_PLUGIN_VERSION" != "$PLUGIN_VERSION" ]]; then
  printf '  \033[33m⚠\033[0m .cursor-plugin/plugin.json version (%s) differs from plugin.json (%s) — synced at release time\n' "$CURSOR_PLUGIN_VERSION" "$PLUGIN_VERSION"
fi

codex_hook 2 "kimi: Bash blocker payload blocks (native envelope, direct script)" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"km1\",\"cwd\":\"/tmp\",\"tool_call_id\":\"call_1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push ${FORCE_FLAG:---force} origin main\"}}" \
  "$SCRIPTS_DIR/jus-block-force-push.sh"

codex_hook 2 "kimi: Edit adding a suppression is blocked through the path shim" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"km1\",\"cwd\":\"/tmp\",\"tool_call_id\":\"call_2\",\"tool_name\":\"Edit\",\"tool_input\":{\"path\":\"app/a.ts\",\"old_string\":\"const x = 1\",\"new_string\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\"}}" \
  "$KIMI_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

codex_hook 0 "kimi: Edit REMOVING a suppression passes through the path shim" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"km1\",\"cwd\":\"/tmp\",\"tool_call_id\":\"call_3\",\"tool_name\":\"Edit\",\"tool_input\":{\"path\":\"app/a.ts\",\"old_string\":\"// ${SUPP_MARK}-next-line\\nconst x: any = 1\",\"new_string\":\"const x = 1\"}}" \
  "$KIMI_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

codex_hook 2 "kimi: Write with a suppression in content is blocked through the shim" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"km1\",\"cwd\":\"/tmp\",\"tool_call_id\":\"call_4\",\"tool_name\":\"Write\",\"tool_input\":{\"path\":\"app/b.ts\",\"content\":\"// ${SUPP_MARK}\\nconst y: any = 2\"}}" \
  "$KIMI_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# ⚠️ AN EMPTY `path` MUST NOT CLOBBER A `file_path` THAT IS ALREADY RIGHT
# (#4428). The shim's test was `.path? != null`, and jq's `//` family treats the
# empty string as a value — so a `"path": ""` both propagated as an empty
# `file_path` and overwrote whatever was there.
#
# The consequence runs the OTHER way from every sibling in this class, and that
# is why it needs a test of its own rather than a reading of the diff: an empty
# `file_path` is fail-CLOSED in jus-block-lint-suppression.sh (the file type
# stays unknown, so every pattern stays active). So the cost is a false BLOCK —
# an `eslint-disable` written into a `.rb` file, which no Ruby linter reads and
# the type column exists to allow.
#
# ⚠️ CONTRACT, NOT CAPTURE. Driven against a local stub on 2026-09-19, every
# kimi `Edit` / `Write` payload carried an absolute `tool_input.path` and no
# `file_path` sibling at all, so neither half of this has been seen live. The
# model chooses that argument, so an empty one is reachable.
#
# ⚠️ AND THIS PAIR KEEPS `JUS_HOOKS_EVERYWHERE` SET, UNLIKE THE CURSOR,
# ANTIGRAVITY AND WINDSURF TESTS IN THIS CLASS. Those drop it because the cwd is
# what they are testing, and the project gate reads the cwd first. Here the cwd
# is not in question and the gate is upstream of everything that is: unset the
# flag and both arms exit 0 before the suppression table is ever consulted,
# which is this rule's own vacuity trap wearing the opposite sign. The control
# arm below is what keeps the pair honest instead.
codex_hook 0 "kimi: an empty path does not clobber a file_path that is already right" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"km1\",\"cwd\":\"/tmp\",\"tool_call_id\":\"call_6\",\"tool_name\":\"Edit\",\"tool_input\":{\"path\":\"\",\"file_path\":\"lib/a.rb\",\"old_string\":\"x = 1\",\"new_string\":\"// ${SUPP_MARK}\\nx = 1\"}}" \
  "$KIMI_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# The control arm, and it is what makes the one above mean anything: the SAME
# edit with the file_path missing has no type to gate on, so every pattern
# applies and it blocks. Without this the test above passes over a shim that
# simply stopped blocking.
codex_hook 2 "kimi: the same edit with no file_path at all stays fail-closed" \
  "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"km1\",\"cwd\":\"/tmp\",\"tool_call_id\":\"call_7\",\"tool_name\":\"Edit\",\"tool_input\":{\"path\":\"\",\"old_string\":\"x = 1\",\"new_string\":\"// ${SUPP_MARK}\\nx = 1\"}}" \
  "$KIMI_ADAPT" "$SCRIPTS_DIR/jus-block-lint-suppression.sh"

# track-edits through the shim records the path into edits.log
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="kimi: track-edits via the shim records path as file_path"
KIMI_STATE="$(mktemp -d)"
CLAUDE_PLUGIN_DATA="$KIMI_STATE" "$KIMI_ADAPT" "$SCRIPTS_DIR/jus-track-edits.sh" >/dev/null 2>&1 \
  <<<'{"hook_event_name":"PostToolUse","session_id":"km2","cwd":"/tmp","tool_call_id":"call_5","tool_name":"Edit","tool_input":{"path":"lib/tracked.rb","old_string":"a","new_string":"b"}}' || true
if grep -q "lib/tracked.rb" "$KIMI_STATE/sessions/km2/edits.log" 2>/dev/null; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
fi
rm -rf "$KIMI_STATE"

# Prompt-time nudge: injects a reminder when the tree is dirty, stays silent
# when clean, and must NEVER exit 2 (UserPromptSubmit is blockable — a
# nonzero-2 exit would block the user's own prompt).
KIMI_NUDGE_REPO="$(mktemp -d)"
git -C "$KIMI_NUDGE_REPO" init -q
echo dirty > "$KIMI_NUDGE_REPO/w.txt"
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="kimi: prompt nudge injects a reminder on a dirty tree (exit 0)"
out=$("$KIMI_NUDGE" <<<"{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"km3\",\"cwd\":\"$KIMI_NUDGE_REPO\",\"prompt\":\"continue\",\"is_steer\":false}" 2>/dev/null); ec=$?
if [[ "$ec" -eq 0 && "$out" == *"uncommitted"* ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (exit=%d out=%s)\n' "$TEST_NAME" "$ec" "${out:0:60}"
fi
git -C "$KIMI_NUDGE_REPO" add -A >/dev/null 2>&1
git -C "$KIMI_NUDGE_REPO" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="kimi: prompt nudge stays silent on a clean tree (exit 0)"
out=$("$KIMI_NUDGE" <<<"{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"km3\",\"cwd\":\"$KIMI_NUDGE_REPO\",\"prompt\":\"continue\",\"is_steer\":false}" 2>/dev/null); ec=$?
if [[ "$ec" -eq 0 && -z "$out" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (exit=%d out=%s)\n' "$TEST_NAME" "$ec" "${out:0:60}"
fi
codex_hook 0 "kimi: prompt nudge fails open on malformed input" \
  "not json at all" "$KIMI_NUDGE"
rm -rf "$KIMI_NUDGE_REPO"

# ---- the ~ word-start guard, every adapter (#4417) --------------------------

section "manifest ~ expansion (all adapters)"

# Every manifest routes through `~/.jus-skills/…`, and a shell expands `~` only
# at the START of a word. `--flag=~/x`, `"~/x"`, or a tilde anywhere but the
# first character of a word is a literal: command not found, exit 127, and
# every adapter's fail-open default turns that into a tool whose hooks are ALL
# dead, with no output anywhere. One stray quote in one manifest does it, and
# nothing else in the bundle would report it.
#
# ⚠️ THE RULE IS MEASURED ON THREE TOOLS — two from their own shipped code, one
# live. It is an assumption on the other four, which is exactly why the guard is
# cheap insurance rather than a formality:
#   Cursor — wraps the command in a heredoc and hands the string to a shell, so
#            the shell does the expanding (#4261)
#   Qwen   — `getShellConfiguration()` returns `argsPrefix: ["-c"]` on every
#            POSIX platform, i.e. `bash -c "<cmd>"` (#4261)
#   Codex  — measured 2026-09-17 on codex-cli 0.154.0 (#4417): three SessionStart
#            hooks under an isolated HOME and CODEX_HOME, bare tilde FIRED,
#            quoted tilde did NOT fire, absolute path FIRED as the control arm
#
# ⚠️ THIS WALKS THE DIRECTORY RATHER THAN A LIST, so an eighth adapter is covered
# the day it lands — including by FAILING if its manifest carries a name none of
# the three known ones cover. A silent skip is the failure a check like this
# acquires later, and it is invisible from a green run.
#
# ⚠️ THE THREE MANIFESTS OUTSIDE hooks/<adapter>/ ARE OUT OF SCOPE BY MEASUREMENT,
# not by oversight: hooks/hooks.json, ../kimi.plugin.json and
# ../gemini-extension.json carry ZERO tildes between them, because each is
# installed as a plugin and reaches the scripts by a relative path or by
# ${CLAUDE_PLUGIN_ROOT}. There is nothing here for this rule to hold. Adding one
# to the walk would fail it on "no ~ paths", which is the assertion below
# working correctly.

# Emit every hook command string in a manifest, one per line.
manifest_commands() { # <manifest-path>
  case "$1" in
    *.toml)
      # jq cannot read TOML. `[[hooks]]` accepts only event/matcher/command/
      # timeout, one key per line, the value double-quoted.
      sed -E -n 's/^[[:space:]]*(command|bash)[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\2/p' "$1"
      ;;
    *)
      # Recursive descent rather than a path per tool: the six JSON manifests
      # nest differently from each other and an eighth will nest differently
      # again. Copilot spells the key `bash`; everyone else spells it `command`.
      jq -r '[.. | objects | (.command?, .bash?) | strings] | .[]' "$1" 2>/dev/null
      ;;
  esac
}

# Count the command keys in the raw text, without parsing. This is the check on
# the EXTRACTOR: if the structural read above returns fewer entries than the
# file plainly contains, it half-worked, and a half-worked extractor reports a
# clean manifest for the paths it never looked at.
manifest_command_keys() { # <manifest-path>
  case "$1" in
    *.toml) grep -cE '^[[:space:]]*(command|bash)[[:space:]]*=' "$1" ;;
    *) grep -cE '"(command|bash)"[[:space:]]*:' "$1" ;;
  esac
}

for tilde_dir in "$HOOKS_DIR"/*/; do
  tilde_adapter=$(basename "$tilde_dir")
  # scripts/ holds the shared hooks themselves, not a manifest. Any OTHER new
  # directory here is an adapter until somebody says otherwise, and will fail
  # below for want of a manifest — deliberately, so that it is a decision.
  [[ "$tilde_adapter" == "scripts" ]] && continue

  TESTS_RUN=$((TESTS_RUN + 1))
  TEST_NAME="$tilde_adapter: every ~ in the manifest sits at the start of a word, where a shell expands it"

  tilde_manifest=""
  for tilde_candidate in hooks.json settings.json config-hooks.toml; do
    if [[ -f "$tilde_dir$tilde_candidate" ]]; then
      tilde_manifest="$tilde_dir$tilde_candidate"
      break
    fi
  done
  if [[ -z "$tilde_manifest" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s (no hooks.json, settings.json or config-hooks.toml)\n' "$TEST_NAME"
    continue
  fi

  bad_tilde=""; tilde_cmds=0; tilde_paths=0
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    tilde_cmds=$((tilde_cmds + 1))
    # `read -ra` splits on IFS exactly as a shell does and, unlike `for w in
    # $cmd`, does not glob — a command holding a `*` would otherwise be expanded
    # against the current directory before it was ever examined.
    read -ra tilde_words <<<"$cmd"
    for word in ${tilde_words[@]+"${tilde_words[@]}"}; do
      # `\~` unquoted, as SKILLS_PREFIX does above: shellcheck's SC2088 fires on
      # a quoted tilde even where it is a case PATTERN and a literal is wanted.
      case "$word" in
        \~/*) tilde_paths=$((tilde_paths + 1)) ;;
        *\~*) bad_tilde+="$word " ;;
      esac
    done
  done < <(manifest_commands "$tilde_manifest")
  tilde_keys=$(manifest_command_keys "$tilde_manifest")

  # ⚠️ AN EMPTY WALK LOOKS CLEAN. A manifest this extractor cannot read yields
  # no commands, therefore no bad tildes, therefore a PASS that asserted
  # nothing. All three counts are checked so that failure is loud instead.
  if [[ "$tilde_cmds" -eq 0 ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s (no hook commands read from %s)\n' "$TEST_NAME" "$(basename "$tilde_manifest")"
  elif [[ "$tilde_cmds" -ne "$tilde_keys" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s (read %d of the %d command keys in %s)\n' \
      "$TEST_NAME" "$tilde_cmds" "$tilde_keys" "$(basename "$tilde_manifest")"
  elif [[ "$tilde_paths" -eq 0 ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s (%d command(s), none of them a ~ path — did the install prefix change?)\n' \
      "$TEST_NAME" "$tilde_cmds"
  elif [[ -n "$bad_tilde" ]]; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s (%s)\n' "$TEST_NAME" "$bad_tilde"
  else
    printf '  \033[32m✓\033[0m %s (%d ~ paths over %d commands)\n' "$TEST_NAME" "$tilde_paths" "$tilde_cmds"
  fi
done

# ---- skill-body portability (#1975) ---------------------------------------

section "skill-body portability"

# The skill bodies are read verbatim by Codex, Kimi Code, Cursor, etc., where
# the Claude Code plugin namespace does not exist and the hooks may not run.
# Namespaced skill refs would point agents at names that only exist under a
# Claude Code plugin install, and a Codex-branded AGENTS.md under-serves the
# other AGENTS.md-reading tools — guard both against regression.
assert_no_match() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m✗\033[0m %s\n' "$name"
  else
    printf '  \033[32m✓\033[0m %s\n' "$name"
  fi
}

assert_match() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1" file="$2" pattern="$3"
  if grep -qF "$pattern" "$file"; then
    printf '  \033[32m✓\033[0m %s\n' "$name"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$name")
    printf '  \033[31m✗\033[0m %s\n' "$name"
  fi
}

# ⚠️ GLOBBED, NOT ENUMERATED (#3403). This loop named its two skills, so
# adding a third left it outside every check below — no license assertion, no
# namespaced-ref check — while the harness still reported a clean run. A
# hardcoded list of the things you ship is a walk that gets shorter than the
# tree without ever failing.
skill_files=("$PLUGIN_ROOT"/skills/*/SKILL.md)
if [[ ${#skill_files[@]} -lt 2 || ! -f "${skill_files[0]}" ]]; then
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("skill bodies: the glob found no skills to check")
  printf '  \033[31m✗\033[0m %s\n' "skill bodies: the glob found no skills to check"
fi

for skill_file in "${skill_files[@]}"; do
  skill_name="$(basename "$(dirname "$skill_file")")"
  assert_no_match "$skill_name: no plugin-namespaced ticket-workflow refs" "$skill_file" "jus:ticket-workflow"
  assert_no_match "$skill_name: no plugin-namespaced hard-rules refs" "$skill_file" "jus:hard-rules"

  # gh skill publish (#1868) warns on a missing license field, and license is
  # part of the agentskills.io optional schema — keep it declared.
  TESTS_RUN=$((TESTS_RUN + 1))
  TEST_NAME="$skill_name: frontmatter declares license: MIT"
  if sed -n '2,/^---$/p' "$skill_file" | grep -q '^license: MIT$'; then
    printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
  fi
done

# #2183: an agent with another tracker's skills loaded can route generic
# ticket language ("#123", board, backlog) away from Juscribe. The description
# is the router's matching surface, so the disambiguation lives there and is
# pinned here so it cannot drift out.
assert_match "ticket-workflow: description claims generic ticket language for Juscribe" \
  "$PLUGIN_ROOT/skills/ticket-workflow/SKILL.md" "never a skill for any other issue tracker"
assert_match "hard-rules: description disambiguates from other issue trackers" \
  "$PLUGIN_ROOT/skills/hard-rules/SKILL.md" "not another issue tracker"

# #2682. The enforcement table's Skill column is ✅ on every row by
# construction — the table enumerates the rules THIS skill contains, so a row
# claiming otherwise is stating something the file itself contradicts.
#
# #2282 put a ❌ there. It was correcting a real error at the time (the
# pre-commit gate does not run the tests) and wrote "Prompt-only…" into the
# Hook column to say so — then applied the same correction a second time, in
# the wrong column. Correcting one column while looking at the other is exactly
# when this slips, which is why it is worth a test rather than a re-read.
#
# ⚠️ COUNTED WITH grep, NOT COMPARED IN awk. The first cut of this check was
# `awk … if ($3 != "✅") print $2`, which is green against a table that still
# has a ❌ in it: /usr/bin/awk on macOS (version 20200816) evaluates
# "❌" != "✅" as FALSE. Measured — `printf "cmp=%d", ($3 != "✅")` prints 0 on
# the ❌ row. Two integer counts from grep have no such failure mode.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="hard-rules: every enforcement-table row claims the rule IS in the skill (#2682)"
HR_SKILL="$PLUGIN_ROOT/skills/hard-rules/SKILL.md"
table_rows="$(grep -cE '^\| .* \| *(✅|❌) *\|' "$HR_SKILL")"
skill_yes="$(grep -cE '^\| .* \| *✅ *\|' "$HR_SKILL")"
if [[ "$table_rows" -eq "$skill_yes" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
  grep -nE '^\| .* \| *❌ *\|' "$HR_SKILL" | sed 's/^/      /'
fi

# Guard the guard. If the row pattern stops matching, the equality above holds
# at 0 == 0 and proves nothing — which is the same vacuous-pass shape the awk
# version had, reached a different way.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="hard-rules: the enforcement-table guard actually reads rows (#2682)"
if [[ "$table_rows" -ge 20 ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (matched %s rows)\n' "$TEST_NAME" "$table_rows"
fi

# #2586. The nudge text is read by whoever installs the bundle, in a string
# they cannot edit — so it must not assert a testing methodology. It said
# "root cause + plan + TDD intent", telling teams that do not practise
# test-first development that they owe something this SOP does not require.
# The obligation ("test intent") travels; the methodology does not.
#
# Keyed on the systemMessage line rather than the whole file, deliberately: the
# script's own comments explain what was removed and why, and a whole-file grep
# would forbid recording that.
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="start-comment nudge text names no testing methodology (#2586)"
if grep 'systemMessage:' "$SCRIPTS/jus-start-comment-nudge.sh" | grep -qiE 'TDD|test.driven|test.first'; then
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
else
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
fi

# The other half: it must still ask for the thing that DOES travel.
assert_match "start-comment nudge still asks for test intent (#2586)" \
  "$SCRIPTS/jus-start-comment-nudge.sh" "test intent"

TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="AGENTS.md title is tool-neutral (Codex, Kimi Code, Antigravity all read it)"
if head -1 "$PLUGIN_ROOT/AGENTS.md" | grep -q "OpenAI Codex"; then
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
else
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
fi

# ---- jus-ticket-claim-nudge.sh -------------------------------------------

section "jus-ticket-claim-nudge.sh"

# #3674. The hook fetches a ticket named in a prompt BEFORE the model runs and
# feeds it back as context. Its rspec spec (spec/jus/hooks/) covers the
# behaviour in depth; these cases cover what is specific to shipping it — that
# it cannot fire against somebody else's workspace, and that it never blocks a
# prompt.
#
# ⚠️ It WROTE to the board until #3796, posting a 👀 on every ticket it saw.
# That is gone, and so is its release-side sibling; the rspec spec holds the
# no-mutation guard.
#
# ⚠️ UserPromptSubmit IS A BLOCKABLE EVENT on Claude Code and on Kimi. A
# non-zero exit here swallows the user's message, so every path must exit 0.

CLAIM_HOOK="$SCRIPTS/jus-ticket-claim-nudge.sh"
CLAIM_TMP=$(mktemp -d)

# A `jus` that logs its argv and answers every GET with one ticket.
mkdir -p "$CLAIM_TMP/bin"
cat > "$CLAIM_TMP/bin/jus" <<CLAIMJUS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CLAIM_TMP/calls.log"
[ "\$1" = "api" ] && [ "\$2" = "GET" ] && exec cat <<'JSON'
{"ticket":{"id":"3668","title":"T","state":"prioritized","points":3,
 "description":"d","assignees":[],"blocked":false,"ticket_reactions":[]}}
JSON
echo '{}'
CLAIMJUS
chmod +x "$CLAIM_TMP/bin/jus"

claim_run() { # <cwd> <prompt> [workspace]
  : > "$CLAIM_TMP/calls.log"
  local env_args=(PATH="$CLAIM_TMP/bin:$PATH" CLAUDE_PLUGIN_DATA="$CLAIM_TMP/state-$RANDOM")
  [[ -n "${3:-}" ]] && env_args+=("TICKET_CLAIM_WORKSPACE=$3")
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"s%s","cwd":"%s","prompt":"%s"}' \
    "$RANDOM" "$1" "$2" | env "${env_args[@]}" "$CLAIM_HOOK" 2>&1
}

# A project the walk-up can find: a directory holding .jus/config/workspace_id.
mkdir -p "$CLAIM_TMP/proj/.jus/config" "$CLAIM_TMP/proj/deep/nested"
echo "42" > "$CLAIM_TMP/proj/.jus/config/workspace_id"

TEST_NAME="reads the workspace from .jus/config/workspace_id"
claim_run "$CLAIM_TMP/proj" "please work #3668" >/dev/null
assert_match "$TEST_NAME" "$CLAIM_TMP/calls.log" "/workspaces/42/tickets/3668"

# The worktree case: .jus/config is gitignored, so a worktree has no copy and
# the hook must reach the parent checkout's — the same walk the CLI does.
TEST_NAME="walks up to a parent's config from a subdirectory"
claim_run "$CLAIM_TMP/proj/deep/nested" "please work #3668" >/dev/null
assert_match "$TEST_NAME" "$CLAIM_TMP/calls.log" "/workspaces/42/tickets/3668"

TEST_NAME="TICKET_CLAIM_WORKSPACE overrides the config"
claim_run "$CLAIM_TMP/proj" "please work #3668" "7" >/dev/null
assert_match "$TEST_NAME" "$CLAIM_TMP/calls.log" "/workspaces/7/tickets/3668"

# ⚠️ THE ONE THAT MATTERS FOR SHIPPING. Until #3674 this defaulted to `1`.
# In a project that is not a jus project, or before `jus login`, that would
# fetch a REAL ticket in somebody else's workspace 1 and feed it to the model.
TEST_NAME="asks nothing at all when no workspace resolves"
mkdir -p "$CLAIM_TMP/orphan"
claim_run "$CLAIM_TMP/orphan" "please work #3668" >/dev/null
assert_no_match "$TEST_NAME" "$CLAIM_TMP/calls.log" "workspaces"

TEST_NAME="says nothing, and calls nothing, on a prompt naming no ticket"
out=$(claim_run "$CLAIM_TMP/proj" "what does this use for auth")
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -z "$out" && ! -s "$CLAIM_TMP/calls.log" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (out=%s)\n' "$TEST_NAME" "${out:0:120}"
fi

# Reaches the AGENT, not just the terminal: systemMessage is rendered to the
# user and never reaches the model — only additionalContext does (#3498).
TEST_NAME="feeds the ticket back on additionalContext"
assert_reaches_agent "$TEST_NAME" "$(claim_run "$CLAIM_TMP/proj" "please work #3668")" "UserPromptSubmit"

rm -rf "$CLAIM_TMP"

# ---- the .jus project guard (#4404) ---------------------------------------

section "juscribe_sop_require_jus_project"

# ⚠️ THE ESCAPE HATCH COMES OFF HERE AND GOES BACK ON AT THE END. Everything
# above runs with it set; this section is the only place the guard is live, so
# leaving it unset would silently disable every later test if one is ever added
# below.
unset JUS_HOOKS_EVERYWHERE

GUARD_BARE=$(mktemp -d)
( cd "$GUARD_BARE" && git init -q && git config user.email t@t && git config user.name t \
  && touch a && git add a && git commit -q -m init && echo dirty > b )

GUARD_WIRED=$(mktemp -d)
( cd "$GUARD_WIRED" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p .jus/docs && touch a && git add a && git commit -q -m init && echo dirty > b )

# A subdirectory, because the guard walks UP. A hook firing in `src/` of a wired
# project is the ordinary case, and keying on the cwd alone would miss it.
mkdir -p "$GUARD_WIRED/src/deep"

# --- the three blocking hooks ---

t "force-push guard is silent in a checkout with no .jus"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  "{\"cwd\":\"$GUARD_BARE\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --force\"}}"

t "force-push guard still blocks in a .jus project"
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  "{\"cwd\":\"$GUARD_WIRED\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --force\"}}" \
  "force-push"

t "force-push guard blocks from a subdirectory of a .jus project"
assert_exit 2 "$SCRIPTS/jus-block-force-push.sh" \
  "{\"cwd\":\"$GUARD_WIRED/src/deep\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --force\"}}" \
  "force-push"

t "no-verify guard is silent in a checkout with no .jus"
assert_exit 0 "$SCRIPTS/jus-block-no-verify.sh" \
  "{\"cwd\":\"$GUARD_BARE\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --no-verify -m x\"}}"

t "no-verify guard still blocks in a .jus project"
assert_exit 2 "$SCRIPTS/jus-block-no-verify.sh" \
  "{\"cwd\":\"$GUARD_WIRED\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --no-verify -m x\"}}" \
  "no-verify"

t "lint-suppression guard is silent in a checkout with no .jus"
assert_exit 0 "$SCRIPTS/jus-block-lint-suppression.sh" \
  "{\"cwd\":\"$GUARD_BARE\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$GUARD_BARE/a.ts\",\"content\":\"// eslint-disable-next-line\\nconst x = 1\"}}"

t "lint-suppression guard still blocks in a .jus project"
assert_exit 2 "$SCRIPTS/jus-block-lint-suppression.sh" \
  "{\"cwd\":\"$GUARD_WIRED\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$GUARD_WIRED/a.ts\",\"content\":\"// eslint-disable-next-line\\nconst x = 1\"}}"

# --- the dirty-tree stop nag ---

t "stop hook is silent in a dirty checkout with no .jus"
assert_exit 0 "$SCRIPTS/jus-stop-uncommitted.sh" "{\"cwd\":\"$GUARD_BARE\"}"

t "stop hook still blocks in a dirty .jus project"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" "{\"cwd\":\"$GUARD_WIRED\"}" "STOP BLOCKED"

# --- the two state trackers ---
#
# These write rather than print, so the assertion is on the state file. Without
# it they are indistinguishable from any other silent hook, and "exits 0 with no
# output" is what they do when they succeed.

GUARD_SESSION=guard-$$
GUARD_STATE="$CLAUDE_PLUGIN_DATA/sessions/$GUARD_SESSION"
rm -rf "$GUARD_STATE"

printf '%s' "{\"cwd\":\"$GUARD_BARE\",\"session_id\":\"$GUARD_SESSION\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$GUARD_BARE/a.ts\"}}" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null 2>&1 || true
t "edit tracker writes no state in a checkout with no .jus"
assert_state_file "$GUARD_STATE/last_modified_at" absent

printf '%s' "{\"cwd\":\"$GUARD_WIRED\",\"session_id\":\"$GUARD_SESSION\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$GUARD_WIRED/a.ts\"}}" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null 2>&1 || true
t "edit tracker still writes state in a .jus project"
assert_state_file "$GUARD_STATE/last_modified_at" present

GUARD_SESSION2=guard2-$$
GUARD_STATE2="$CLAUDE_PLUGIN_DATA/sessions/$GUARD_SESSION2"
rm -rf "$GUARD_STATE2"

printf '%s' "{\"cwd\":\"$GUARD_BARE\",\"session_id\":\"$GUARD_SESSION2\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bin/rubocop app\"}}" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null 2>&1 || true
t "bash tracker writes no state in a checkout with no .jus"
assert_state_file "$GUARD_STATE2/last_linted_at" absent

printf '%s' "{\"cwd\":\"$GUARD_WIRED\",\"session_id\":\"$GUARD_SESSION2\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bin/rubocop app\"}}" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null 2>&1 || true
t "bash tracker still writes state in a .jus project"
assert_state_file "$GUARD_STATE2/last_linted_at" present

# --- the boundary is the git toplevel, not any ancestor ---
#
# ⚠️ THE FIRST CUT OF THE GUARD WALKED UP TO `/` AND THIS IS WHY IT DOES NOT.
# Measured on the authoring machine: `$TMPDIR/.jus/baseline/` exists — litter
# from an edge check — so every `mktemp -d` repository sat under a `.jus` and
# the guard passed in all six cases above while appearing to work. An ancestor
# is not ours to read: `$HOME/.jus` would wire every project a person owns.

GUARD_NEST=$(mktemp -d)
mkdir -p "$GUARD_NEST/.jus"
( cd "$GUARD_NEST" && mkdir inner && cd inner && git init -q \
  && git config user.email t@t && git config user.name t \
  && touch a && git add a && git commit -q -m init )

t "a .jus in an ANCESTOR of the repo does not wire it"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  "{\"cwd\":\"$GUARD_NEST/inner\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --force\"}}"

GUARD_NOGIT=$(mktemp -d)
mkdir -p "$GUARD_NOGIT/.jus"

t "a .jus outside any git repository does not wire it"
assert_exit 0 "$SCRIPTS/jus-block-force-push.sh" \
  "{\"cwd\":\"$GUARD_NOGIT\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --force\"}}"

# --- the escape hatch ---

t "JUS_HOOKS_EVERYWHERE=1 restores the old machine-wide behaviour"
TESTS_RUN=$((TESTS_RUN + 1))
guard_ec=0
printf '%s' "{\"cwd\":\"$GUARD_BARE\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push --force\"}}" \
  | JUS_HOOKS_EVERYWHERE=1 "$SCRIPTS/jus-block-force-push.sh" >/dev/null 2>&1 || guard_ec=$?
if [[ "$guard_ec" -eq 2 ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (exit=%s, wanted 2)\n' "$TEST_NAME" "$guard_ec"
fi

# --- every hook, structurally ---
#
# ⚠️ The behavioural cases above cover the six hooks that demonstrably ACT
# outside a Juscribe project. The other six are already quiet there for
# incidental reasons — no workspace id, no active ticket, no nudge map — so a
# behavioural test on them would pass without the guard and prove nothing (an
# empty walk looks clean). This asserts the call site instead, which is the only
# thing that distinguishes "guarded" from "happens to be silent today".

for guard_hook in "$SCRIPTS"/jus-*.sh; do
  t "$(basename "$guard_hook") calls the .jus project guard"
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q 'juscribe_sop_require_jus_project' "$guard_hook"; then
    printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
    printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
  fi
done

rm -rf "$GUARD_BARE" "$GUARD_WIRED" "$GUARD_NEST" "$GUARD_NOGIT"
# ---- the liveness record (#4416) ------------------------------------------

section "hook liveness"

# ⚠️ NOTHING ANYWHERE PROVED A HOOK HAD RUN. Four silencers — a non-2 exit, a
# tool name the guards do not match, a cwd outside a Juscribe project, and a
# manifest the tool never loaded — each produce NO OUTPUT AT ALL. So "installed,
# configured, protecting nothing" read exactly like "installed, configured,
# nothing to block", and on #4261 that state shipped with tests, a README and a
# live verification all passing over it.
#
# ⚠️ THE FLAG STAYS UNSET FOR THIS WHOLE SECTION. `JUS_HOOKS_EVERYWHERE=1`
# short-circuits the project guard before it reads the cwd, so with it set the
# two outcomes this section exists to tell apart never occur.
#
# ⚠️ EVERY PAYLOAD IS BUILT INTO A VARIABLE FIRST, AND THAT IS NOT STYLE.
# A JSON literal written inline inside `"$( … "{\"a\":1,\"b\":2}" )"` loses its
# quoting: the escapes belong to the OUTER double-quoted string, so by the time
# the command substitution re-parses, the braces are bare and bash BRACE-EXPANDS
# on the commas. Measured while writing this section — one call became five,
# each carrying a single `"key":"value"` fragment, every one exit 127. The
# assertion then reads an empty log and fails for a reason that has nothing to
# do with the code under test.
unset JUS_HOOKS_EVERYWHERE

LIVE_HOME=$(mktemp -d)
LIVE_WIRED=$(mktemp -d)
git -C "$LIVE_WIRED" init -q
mkdir -p "$LIVE_WIRED/.jus"
LIVE_BARE=$(mktemp -d)
git -C "$LIVE_BARE" init -q
LIVE_OUTSIDE=$(mktemp -d)

# One invocation, its own plugin-data root, and the recorded line handed back.
# Runs from OUTSIDE any Juscribe project, because the shared scripts fall back
# to $PWD and that fallback is what hid #4261.
live_run() { # <session> <script> <payload> [env assignments...]
  local session="$1" script="$2" payload="$3"; shift 3
  ( cd "$LIVE_OUTSIDE" && env CLAUDE_PLUGIN_DATA="$LIVE_HOME" "$@" "$script" <<<"$payload" ) \
    >/dev/null 2>&1 || true
  cat "$LIVE_HOME/sessions/$session/liveness.log" 2>/dev/null || true
}

live_payload() { # <session> <tool> <command> [cwd]
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","cwd":"%s","tool_name":"%s","tool_input":{"command":"%s"}}' \
    "$1" "${4-$LIVE_WIRED}" "$2" "$3"
}

LIVE_GUARD="$SCRIPTS/jus-block-force-push.sh"
LIVE_FORCE="git push ${FORCE_FLAG:---force} origin main"

live_allowed=$(live_run s1 "$LIVE_GUARD" "$(live_payload s1 Bash 'git status')")

t "a guard that allows records that it ran"
assert_stdout "$TEST_NAME" "outcome=allowed" "$live_allowed"

t "the record names the script that ran"
assert_stdout "$TEST_NAME" "script=jus-block-force-push.sh" "$live_allowed"

t "the record names the event"
assert_stdout "$TEST_NAME" "event=PreToolUse" "$live_allowed"

t "the record names the tool"
assert_stdout "$TEST_NAME" "tool=Bash" "$live_allowed"

# ⚠️ A HOOK THAT RAN AND ALLOWED IS PROOF OF LIFE. Only one that never ran is
# the defect, so the blocking case must record too — otherwise a healthy session
# with nothing to block looks identical to a dead one.
t "a guard that blocks records that it blocked"
assert_stdout "$TEST_NAME" "outcome=blocked" \
  "$(live_run s4 "$LIVE_GUARD" "$(live_payload s4 Bash "$LIVE_FORCE")")"

# ⚠️ SILENCER 3, AND THE WHOLE REASON THE RECORD LIVES OUTSIDE THE PROJECT. A
# record written under `.jus/` cannot be written in exactly the case it exists
# to report.
live_bare=$(live_run s5 "$LIVE_GUARD" "$(live_payload s5 Bash "$LIVE_FORCE" "$LIVE_BARE")")

t "a guard outside a Juscribe project records why, rather than nothing"
assert_stdout "$TEST_NAME" "outcome=not-a-jus-project" "$live_bare"

t "and it does not claim to have lost the cwd — it had one"
assert_stdout "$TEST_NAME" "cwd=payload" "$live_bare"

# ⚠️ THE THIRD VALUE, AND THE ONE #4261 NEEDED. The Cursor shim handed over
# `"cwd": ""`, so the guards ran, could not tell where they were, and exited 0.
# That is not "outside a Juscribe project" and it is not "never ran" — and a
# two-valued record would have reported one of those and been wrong.
t "an EMPTY cwd is recorded as cwd=no-cwd"
assert_stdout "$TEST_NAME" "cwd=no-cwd" \
  "$(live_run s6 "$LIVE_GUARD" "$(live_payload s6 Bash "$LIVE_FORCE" "")")"

t "malformed JSON is recorded as bad-json"
assert_stdout "$TEST_NAME" "outcome=bad-json" \
  "$(live_run _anonymous "$LIVE_GUARD" 'not json at all')"

# ⚠️ SILENCER 2 NEEDS NO OUTCOME OF ITS OWN — the line carries the tool name, so
# a session full of `tool=Shell outcome=allowed` reads itself out as the
# .claude/settings.json-under-Cursor case.
t "a tool the guards do not match still records, with its tool name"
assert_stdout "$TEST_NAME" "tool=Shell" \
  "$(live_run s7 "$LIVE_GUARD" "$(live_payload s7 Shell "$LIVE_FORCE")")"

# ⚠️ SILENCER 1, AND THE ONLY OUTCOME THAT CANNOT USE jq TO WRITE ITSELF.
t "a missing jq is recorded as no-jq"
# ⚠️ `dirname` IS LOAD-BEARING IN THIS LIST. Every guard opens with
# `source "$(dirname "$0")/lib/state.sh"`, so a sandbox PATH without it kills
# the script before lib/state.sh is even read — and the test then reports "no
# record" for a reason that has nothing to do with jq.
LIVE_NOJQ=$(mktemp -d)
for live_tool in bash cat dirname git grep sed awk mkdir printf; do
  live_src=$(command -v "$live_tool" 2>/dev/null) && ln -sf "$live_src" "$LIVE_NOJQ/$live_tool"
done
assert_stdout "$TEST_NAME" "outcome=no-jq" \
  "$(live_run _anonymous "$LIVE_GUARD" '{}' PATH="$LIVE_NOJQ")"
rm -rf "$LIVE_NOJQ"

# ⚠️ THE RECORDING ITSELF MUST STAY SILENT. A hook that prints on the happy path
# is noise in every session forever, and the check is what people run.
t "recording adds nothing to a guard's own output"
live_payload_quiet=$(live_payload s8 Bash 'git status')
live_quiet=$( cd "$LIVE_OUTSIDE" && env CLAUDE_PLUGIN_DATA="$LIVE_HOME" \
  "$LIVE_GUARD" <<<"$live_payload_quiet" 2>&1 )
assert_stdout "$TEST_NAME" "" "$live_quiet"

# ---- the check command ----------------------------------------------------

LIVENESS="$HOOKS_DIR/jus-liveness"

live_check() { # <session>
  ( env CLAUDE_PLUGIN_DATA="$LIVE_HOME" "$LIVENESS" "$1" 2>&1 ) || true
}

live_check_ec() { # <session>
  local ec=0
  ( env CLAUDE_PLUGIN_DATA="$LIVE_HOME" "$LIVENESS" "$1" ) >/dev/null 2>&1 || ec=$?
  # ⚠️ Bracketed, because assert_stdout matches a SUBSTRING: a bare "1" is
  # inside "127", so a crashing check would pass an exit-1 assertion.
  printf '[%s]' "$ec"
}

t "jus-liveness reports the session's hooks as alive"
assert_stdout "$TEST_NAME" "alive" "$(live_check s1)"

t "jus-liveness names each script that ran"
assert_stdout "$TEST_NAME" "jus-block-force-push.sh" "$(live_check s4)"

t "jus-liveness exits 0 on a healthy session"
assert_stdout "$TEST_NAME" "[0]" "$(live_check_ec s1)"

# ⚠️ THE ALARM, and the only state that is unambiguously wrong. Silencer 4 — a
# manifest the tool never loaded — reaches the check this way too.
t "jus-liveness reports a session with no records at all"
assert_stdout "$TEST_NAME" "NO jus hook" "$(live_check never-ran)"

t "a session with no records exits 1"
assert_stdout "$TEST_NAME" "[1]" "$(live_check_ec never-ran)"

# ⚠️ RAN AND COULD NOT TELL WHERE IT WAS is a distinct alarm from both of the
# above, and it is the #4261 shape. A session whose every record is cwd=no-cwd
# is a broken shim, not a quiet one.
t "jus-liveness calls out a session whose every record lost its cwd"
assert_stdout "$TEST_NAME" "every record says cwd=no-cwd" "$(live_check s6)"

t "jus-liveness exits 1 when every record lost its cwd"
assert_stdout "$TEST_NAME" "[1]" "$(live_check_ec s6)"

rm -rf "$LIVE_HOME" "$LIVE_WIRED" "$LIVE_BARE" "$LIVE_OUTSIDE"

export JUS_HOOKS_EVERYWHERE=1

# ---- the undefined-helper guard -------------------------------------------

section "the undefined-helper guard"

# #4462. Everything else in this file asserts on a hook. This section asserts on
# the harness: that a call to a helper which does not exist can no longer pass
# for 342 green tests, which is what it did for eight days until #4431.

t "an undefined helper turns the run red, and names it"
TESTS_RUN=$((TESTS_RUN + 1))
UG_EC=0
UG_OUT=$(JUS_TESTS_SELFCHECK=assert_helper_that_does_not_exist \
  bash "$HOOKS_DIR/tests.sh" 2>&1) || UG_EC=$?
if [[ $UG_EC -eq 1 && "$UG_OUT" == *"undefined command: assert_helper_that_does_not_exist"* ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1)); FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (exit=%s, out=%s)\n' "$TEST_NAME" "$UG_EC" "${UG_OUT:0:240}"
fi

UG_LOG=$(mktemp)
printf '%s\n' \
  "$HOOKS_DIR/tests.sh: line 700: assert_stdout: command not found" \
  "$HOOKS_DIR/tests.sh: line 712: assert_stdout: command not found" \
  "$HOOKS_DIR/tests.sh: line 980: assert_stdout_lacks: command not found" > "$UG_LOG"

# Both names, because #4431's two helpers were called 15 times between them: a
# scanner that reported only the first would have hidden half of it.
t "the scanner counts the repeat calls to one missing helper"
assert_stdout "$TEST_NAME" "2 assert_stdout" "$(undefined_commands "$UG_LOG")"

t "the scanner names a second missing helper separately"
assert_stdout "$TEST_NAME" "1 assert_stdout_lacks" "$(undefined_commands "$UG_LOG")"

t "unrelated stderr is not read as a missing command"
printf '%s\n' "warning: something happened" "npm WARN deprecated foo" > "$UG_LOG"
assert_stdout "$TEST_NAME" "" "$(undefined_commands "$UG_LOG")"

rm -f "$UG_LOG"

# ⚠️ THE FALSE-POSITIVE SURFACE, ENUMERATED. This suite deliberately asks
# whether binaries are present — jq, shellcheck, and the loop that builds the
# jq-less sandbox PATH — and every one of those asks with `command -v`. It is a
# BUILTIN: absence is an exit status, and it prints nothing, so no probe in this
# file can reach the scanner. That is the whole reason the guard needs no
# allowlist, and this is it stated as a test rather than as a comment.
t "a command -v probe for an absent binary writes nothing to stderr"
UG_PROBE=$(command -v jus_no_such_binary_4462 2>&1 >/dev/null)
assert_stdout "$TEST_NAME" "" "$UG_PROBE"

# ---- summary --------------------------------------------------------------

print_summary
