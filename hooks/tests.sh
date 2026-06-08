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

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HOOKS_DIR/scripts"

TESTS_RUN=0
TESTS_FAILED=0
FAILURES=()

# Isolated state directory so tests don't pollute real plugin data.
CLAUDE_PLUGIN_DATA=$(mktemp -d)
export CLAUDE_PLUGIN_DATA
trap 'rm -rf "$CLAUDE_PLUGIN_DATA"' EXIT

# ---- helpers ---------------------------------------------------------------

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

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

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

# ---- jus-pre-commit-gate.sh + tracking ----------------------------------------

section "jus-pre-commit-gate.sh + tracking"

# Use a fresh session id per scenario for isolation
SID_CLEAN="test-clean-$$"
SID_EDITED="test-edited-$$"
SID_LINTED="test-linted-$$"
SID_DOCS="test-docs-$$"

t "allows git commit when no edits tracked"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_CLEAN\"}"

# Simulate an Edit on a Ruby file
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/foo.rb","old_string":"a","new_string":"b"},"session_id":"%s"}' "$SID_EDITED" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null

t "blocks git commit after a code edit, no lint"
assert_exit 2 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_EDITED\"}" \
  "linters have not been run"

t "allows git commit when the command itself runs a linter"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bin/rubocop foo.rb && git commit -m x\"},\"session_id\":\"$SID_EDITED\"}"

# Simulate edit then lint
printf '{"tool_name":"Edit","tool_input":{"file_path":"/repo/foo.rb","old_string":"a","new_string":"b"},"session_id":"%s"}' "$SID_LINTED" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null
sleep 1
printf '{"tool_name":"Bash","tool_input":{"command":"bin/rubocop foo.rb"},"tool_response":{"interrupted":false},"session_id":"%s"}' "$SID_LINTED" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "allows git commit after lints have run"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_LINTED\"}"

# After successful commit, edit tracking should reset
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s"}' "$SID_LINTED" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "allows git commit with no edits after a prior commit cleared state"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_LINTED\"}"

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
sleep 1
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
sleep 1
printf '{"tool_name":"Bash","tool_input":{"command":"bin/rubocop foo.rb"},"tool_response":{"stdout":"","stderr":"","interrupted":false,"isImage":false},"session_id":"%s"}' "$SID_REAL" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "records lint from real harness payload (no exit_code) → allows commit"
assert_exit 0 "$SCRIPTS/jus-pre-commit-gate.sh" \
  "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\"},\"session_id\":\"$SID_REAL\"}"

# ---- jus-dirty-tree-nudge.sh --------------------------------------------------

section "jus-dirty-tree-nudge.sh"

SID_NUDGE="test-nudge-$$"
state_dir="$CLAUDE_PLUGIN_DATA/sessions/$SID_NUDGE"
mkdir -p "$state_dir"

t "stays quiet under threshold"
echo 1 > "$state_dir/unsaved_edits"
assert_exit 0 "$SCRIPTS/jus-dirty-tree-nudge.sh" \
  "{\"tool_name\":\"Edit\",\"session_id\":\"$SID_NUDGE\",\"cwd\":\"/tmp\"}"

# Test in a real (clean) git repo to verify the clean-tree branch
TMP_REPO=$(mktemp -d)
( cd "$TMP_REPO" && git init -q && git config user.email t@t && git config user.name t \
  && touch a && git add a && git commit -q -m init )
SID_CLEAN_NUDGE="test-nudge-clean-$$"
state_dir2="$CLAUDE_PLUGIN_DATA/sessions/$SID_CLEAN_NUDGE"
mkdir -p "$state_dir2"
echo 9 > "$state_dir2/unsaved_edits"

t "resets counter when working tree is clean"
assert_exit 0 "$SCRIPTS/jus-dirty-tree-nudge.sh" \
  "{\"tool_name\":\"Edit\",\"session_id\":\"$SID_CLEAN_NUDGE\",\"cwd\":\"$TMP_REPO\"}"
counter=$(cat "$state_dir2/unsaved_edits" 2>/dev/null || echo missing)
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="counter reset to 0 after clean check"
if [[ "$counter" == "0" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (got: %s)\n' "$TEST_NAME" "$counter"
fi

# Dirty tree → emits systemMessage on stdout
echo "dirty" > "$TMP_REPO/dirty.txt"
SID_DIRTY_NUDGE="test-nudge-dirty-$$"
state_dir3="$CLAUDE_PLUGIN_DATA/sessions/$SID_DIRTY_NUDGE"
mkdir -p "$state_dir3"
echo 9 > "$state_dir3/unsaved_edits"

t "emits systemMessage when tree is dirty and threshold reached"
out=$(printf '{"tool_name":"Edit","session_id":"%s","cwd":"%s"}' "$SID_DIRTY_NUDGE" "$TMP_REPO" \
       | "$SCRIPTS/jus-dirty-tree-nudge.sh")
TESTS_RUN=$((TESTS_RUN + 1))
TEST_NAME="dirty-tree-nudge stdout contains systemMessage"
if [[ "$out" == *"systemMessage"* && "$out" == *"without committing"* ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s\n' "$TEST_NAME"
  printf '      got: %s\n' "${out:0:300}"
fi

rm -rf "$TMP_REPO"

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

rm -rf "$DIRTY_REPO" "$CLEAN_REPO"

# ---- start-comment-nudge.sh + lifecycle tracking --------------------------

section "jus-start-comment-nudge.sh + start-comment tracking"

TRACK="$SCRIPTS/jus-post-bash-tracker.sh"
NUDGE="$SCRIPTS/jus-start-comment-nudge.sh"

# JSON builders (jq handles escaping of the nested quotes).
mk_bash() { jq -nc --arg cmd "$1" --arg sid "$2" '{tool_name:"Bash",tool_input:{command:$cmd},tool_response:{interrupted:false},session_id:$sid}'; }
mk_edit() { jq -nc --arg fp "$1" --arg sid "$2" '{tool_name:"Edit",tool_input:{file_path:$fp},session_id:$sid}'; }

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

# Scenario A — started, no comment yet → tracker arms, nudge fires on a source edit, then fires once.
SID_A="sc-a-$$"; DIR_A="$CLAUDE_PLUGIN_DATA/sessions/$SID_A"
mk_bash "jus api PATCH /workspaces/1/tickets/1852/transition '{\"state\":\"started\"}'" "$SID_A" | "$TRACK" >/dev/null

t "tracker records active_ticket on a started transition"
assert_state_eq "$DIR_A/active_ticket" "1852"

t "nudge fires on the first source-file edit when no start comment exists"
assert_exit 0 "$NUDGE" "$(mk_edit /repo/app/models/foo.rb "$SID_A")" "start comment"

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
for hook in jus-block-force-push jus-block-no-verify jus-pre-commit-gate \
            jus-block-lint-suppression jus-track-edits jus-dirty-tree-nudge \
            jus-start-comment-nudge jus-post-bash-tracker jus-stop-uncommitted; do
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
assert_jq "plugin.json version is 1.0.1" "$PLUGIN_JSON" '.version == "1.0.1"'
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
