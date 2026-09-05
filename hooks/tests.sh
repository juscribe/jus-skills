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

# Isolated state directory so tests don't pollute real plugin data.
CLAUDE_PLUGIN_DATA=$(mktemp -d)
export CLAUDE_PLUGIN_DATA
trap 'rm -rf "$CLAUDE_PLUGIN_DATA"' EXIT

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
assert_reaches_agent() { # <name> <hook_output>
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1" out="$2" missing=""
  jq -e '.systemMessage | type == "string" and length > 0' >/dev/null 2>&1 <<<"$out" \
    || missing="systemMessage"
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1 <<<"$out" \
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
# edits made since the last lint — and until #2807 only the dirty-tree nudge
# tested it; the gate's own side was covered solely by sessions that had never
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

# ---- jus-dirty-tree-nudge.sh --------------------------------------------------

section "jus-dirty-tree-nudge.sh"

# A repo with N dirty files, all recorded in edits.log as this session's, and
# checks recorded as having run since the last edit — the state in which a
# commit was possible and did not happen.
#
# `edits.log` rather than a counter is the whole point of #2352: a counter
# double-counts when the same hook is registered twice (measured: the plugin
# copy and the project copy both fire, so the threshold halved and the message
# reported a number that never happened), and it counts edit operations where
# the message claims files.
# ⚠️ The repo path must be the PHYSICAL one. `mktemp -d` hands back
# /var/folders/… while `git rev-parse --show-toplevel` reports
# /private/var/folders/… — macOS symlinks /var. The scoping matches recorded
# absolute paths against "$toplevel/$path", so the two forms must agree or the
# intersection is silently empty and the hook becomes a no-op that still exits
# 0. Real sessions never hit this (Claude Code passes unsymlinked paths for both
# cwd and file_path); a fixture built on mktemp does, and would otherwise "pass"
# by testing nothing.
nudge_repo() {
  local repo dirty_count="$1" sid="$2" state_dir
  repo=$(cd "$(mktemp -d)" && pwd -P)
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
    && touch seed && git add seed && git commit -q -m init )
  state_dir="$CLAUDE_PLUGIN_DATA/sessions/$sid"
  mkdir -p "$state_dir"
  local i
  for (( i = 1; i <= dirty_count; i++ )); do
    echo "dirty" > "$repo/f$i.txt"
    echo "$repo/f$i.txt" >> "$state_dir/edits.log"
  done
  # Checks ran after the last edit: the nudge's precondition.
  echo 100 > "$state_dir/last_modified_at"
  echo 200 > "$state_dir/last_linted_at"
  echo "$repo"
}

nudge_out() {
  printf '{"tool_name":"Edit","session_id":"%s","cwd":"%s"}' "$1" "$2" \
    | "$SCRIPTS/jus-dirty-tree-nudge.sh"
}

# assert_stdout <description> <expected-substring-or-empty> <actual>
assert_stdout() {
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

SID_NUDGE="test-nudge-$$"
REPO_UNDER=$(nudge_repo 4 "$SID_NUDGE")
assert_stdout "stays quiet below the threshold (4 dirty files)" "" \
  "$(nudge_out "$SID_NUDGE" "$REPO_UNDER")"
rm -rf "$REPO_UNDER"

SID_AT="test-nudge-at-$$"
REPO_AT=$(nudge_repo 5 "$SID_AT")
assert_stdout "fires at the threshold and names the file count" "5 files" \
  "$(nudge_out "$SID_AT" "$REPO_AT")"

# THE DEFECT THIS TICKET EXISTS FOR. Both hook copies are registered in the
# producing repo (#2353), so every event is delivered twice. A counter reaches
# the threshold in half the edits and reports a number that never happened; a
# derived count is identical however many times it is asked.
SID_TWICE="test-nudge-twice-$$"
REPO_TWICE=$(nudge_repo 5 "$SID_TWICE")
first=$(nudge_out "$SID_TWICE" "$REPO_TWICE")
second=$(nudge_out "$SID_TWICE" "$REPO_TWICE")
# #2353's concern was the COUNT going wrong when one event is delivered twice by
# two registrations — a counter reached 5 in 3 edits and then said "5 file edits".
# The count is derived, so it is still right however many times it is asked, and
# that is what the first assertion below pins.
#
# ⚠️ WHAT CHANGED IN #3507: the second delivery is now SILENT rather than
# identical. The per-ticket dedup flag is written by the first, so the duplicate
# is suppressed — which is the outcome #2353 wanted anyway (one message, correct
# number) rather than two identical ones. The old assertion was `$first ==
# $second`; do not restore it without also removing the dedup.
assert_stdout "double delivery reports the same count, not double" "5 files" "$first"
assert_stdout "the duplicate delivery is suppressed, not repeated" "" "$second"

# The flag is per-ticket, not permanent: a clean tree clears it, so the next
# batch of uncommitted work is nudged again. Without this the hook speaks once
# per ticket for the ticket's whole life, which is the opposite failure from
# firing 32 times.
( cd "$REPO_TWICE" && git add -A && git commit -q -m "committed" )
nudge_out "$SID_TWICE" "$REPO_TWICE" >/dev/null
for i in 1 2 3 4 5; do echo "again $i" > "$REPO_TWICE/g$i.txt"; done
assert_stdout "a clean tree rearms the nudge for the next batch" "5 files" \
  "$(nudge_out "$SID_TWICE" "$REPO_TWICE")"
rm -rf "$REPO_TWICE"

# Editing ONE file repeatedly is not five files. edits.log records a path per
# operation, so the count has to be of DISTINCT paths.
SID_SAME="test-nudge-samefile-$$"
REPO_SAME=$(nudge_repo 1 "$SID_SAME")
for _ in 1 2 3 4 5 6; do echo "$REPO_SAME/f1.txt" >> "$CLAUDE_PLUGIN_DATA/sessions/$SID_SAME/edits.log"; done
assert_stdout "six edits to one file is one file, not six" "" \
  "$(nudge_out "$SID_SAME" "$REPO_SAME")"
rm -rf "$REPO_SAME"

# The complaint that opened #2352: mid-TDD the tree is dirty and red, and there
# is no correct commit to make. last_linted_at < last_modified_at means checks
# have not run since the last edit.
SID_RED="test-nudge-unverified-$$"
REPO_RED=$(nudge_repo 8 "$SID_RED")
echo 300 > "$CLAUDE_PLUGIN_DATA/sessions/$SID_RED/last_modified_at"
echo 200 > "$CLAUDE_PLUGIN_DATA/sessions/$SID_RED/last_linted_at"
assert_stdout "silent while checks have not run since the last edit" "" \
  "$(nudge_out "$SID_RED" "$REPO_RED")"

echo 400 > "$CLAUDE_PLUGIN_DATA/sessions/$SID_RED/last_linted_at"
assert_stdout "fires once checks have run since the last edit" "8 files" \
  "$(nudge_out "$SID_RED" "$REPO_RED")"
rm -rf "$REPO_RED"

# A clean tree is the normal post-commit state; no output, no error.
SID_CLEAN_NUDGE="test-nudge-clean-$$"
REPO_CLEAN=$(nudge_repo 5 "$SID_CLEAN_NUDGE")
( cd "$REPO_CLEAN" && git add -A && git commit -q -m work )
assert_stdout "silent once the work is committed" "" \
  "$(nudge_out "$SID_CLEAN_NUDGE" "$REPO_CLEAN")"
rm -rf "$REPO_CLEAN"

t "non-git cwd is a no-op"
assert_exit 0 "$SCRIPTS/jus-dirty-tree-nudge.sh" \
  "{\"tool_name\":\"Edit\",\"session_id\":\"$SID_AT\",\"cwd\":\"/nonexistent-path-$$\"}"

t "non-edit tool is a no-op"
assert_exit 0 "$SCRIPTS/jus-dirty-tree-nudge.sh" \
  "{\"tool_name\":\"Bash\",\"session_id\":\"$SID_AT\",\"cwd\":\"$REPO_AT\"}"

rm -rf "$REPO_AT"

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

# Build a dirty repo
DIRTY_REPO=$(mktemp -d)
( cd "$DIRTY_REPO" && git init -q && git config user.email t@t && git config user.name t \
  && touch a && git add a && git commit -q -m init && echo dirty > b )

t "blocks stop when working tree is dirty"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\"}" \
  "STOP BLOCKED"

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

rm -rf "$DIRTY_REPO" "$CLEAN_REPO"

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

# ---- summary --------------------------------------------------------------

printf '\n%d tests run, %d failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
if (( TESTS_FAILED > 0 )); then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
exit 0
