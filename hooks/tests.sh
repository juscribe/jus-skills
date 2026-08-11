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

# After successful commit, edit tracking should reset. The tracker verifies
# resolution against git (#2355), so hand it a clean repo as cwd: the tracked
# /repo/foo.rb is not in its dirty set, which reads as resolved.
GATE_CLEAN_REPO=$(mktemp -d)
( cd "$GATE_CLEAN_REPO" && git init -q && git config user.email t@t && git config user.name t \
  && touch seed && git add seed && git commit -q -m init )
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s","cwd":"%s"}' "$SID_LINTED" "$GATE_CLEAN_REPO" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null
rm -rf "$GATE_CLEAN_REPO"

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
assert_stdout "double delivery reports the same count, not double" "5 files" "$second"
assert_stdout "double delivery is identical to single delivery" "$first" "$second"
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

# Only this session's files count. With two agents sharing a checkout the dirty
# set includes the other session's work, and nudging about it is the #2216
# failure wearing a different hat.
SID_FOREIGN="test-nudge-foreign-$$"
REPO_FOREIGN=$(nudge_repo 2 "$SID_FOREIGN")
for i in 3 4 5 6 7; do echo "someone else" > "$REPO_FOREIGN/other$i.txt"; done
assert_stdout "ignores dirty files this session never touched" "" \
  "$(nudge_out "$SID_FOREIGN" "$REPO_FOREIGN")"
rm -rf "$REPO_FOREIGN"

# Codex records REPO-RELATIVE paths: its `*** Update File:` header carries
# "app/a.ts", and jus-codex-adapt passes that through as file_path. Matching
# only the absolute form left the intersection permanently empty on Codex, so
# both this nudge and the stop gate silently covered nothing while exiting 0.
SID_REL="test-nudge-relative-$$"
REPO_REL=$(nudge_repo 0 "$SID_REL")
for i in 1 2 3 4 5; do
  echo "dirty" > "$REPO_REL/r$i.txt"
  echo "r$i.txt" >> "$CLAUDE_PLUGIN_DATA/sessions/$SID_REL/edits.log"
done
assert_stdout "counts repo-relative recorded paths (Codex shape)" "5 files" \
  "$(nudge_out "$SID_REL" "$REPO_REL")"
rm -rf "$REPO_REL"

# A clean tree is the normal post-commit state; no output, no error.
SID_CLEAN_NUDGE="test-nudge-clean-$$"
REPO_CLEAN=$(nudge_repo 5 "$SID_CLEAN_NUDGE")
( cd "$REPO_CLEAN" && git add -A && git commit -q -m work )
assert_stdout "silent once the work is committed" "" \
  "$(nudge_out "$SID_CLEAN_NUDGE" "$REPO_CLEAN")"
rm -rf "$REPO_CLEAN"

# #2355: the window between a commit and the next edit. The commit event makes
# the tracker delete edits.log AND last_modified_at — so the verification gate
# passes (linted_at >= 0) and, pre-fix, the fallback counted the remaining
# dirty files, which after a real commit are precisely the ones this session
# did NOT touch. The sentinel must keep the nudge silent here.
SID_POSTCOMMIT="test-nudge-postcommit-$$"
REPO_POSTCOMMIT=$(nudge_repo 0 "$SID_POSTCOMMIT")
STATE_POSTCOMMIT="$CLAUDE_PLUGIN_DATA/sessions/$SID_POSTCOMMIT"
# This session's work: tracked, then genuinely committed (clean).
echo "mine" > "$REPO_POSTCOMMIT/mine.txt"
echo "$REPO_POSTCOMMIT/mine.txt" >> "$STATE_POSTCOMMIT/edits.log"
( cd "$REPO_POSTCOMMIT" && git add mine.txt && git commit -q -m mine )
# Another session's in-flight work: dirty, never tracked here.
for i in 1 2 3 4 5; do echo "foreign" > "$REPO_POSTCOMMIT/other$i.txt"; done
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s","cwd":"%s"}' "$SID_POSTCOMMIT" "$REPO_POSTCOMMIT" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null
assert_stdout "silent about foreign dirty files between a commit and the next edit (#2355)" "" \
  "$(nudge_out "$SID_POSTCOMMIT" "$REPO_POSTCOMMIT")"
rm -rf "$REPO_POSTCOMMIT"

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

# #2216: scope the block to files THIS session touched. With two agent
# sessions in one repo, the hook used to fire on the other session's in-flight
# edits. jus-track-edits records every Edit/Write path per session in
# edits.log; the stop hook now blocks only on the dirty files that appear there.
STOP_SID="stop-scope-2216"
STOP_STATE="$CLAUDE_PLUGIN_DATA/sessions/$STOP_SID"
mkdir -p "$STOP_STATE"
STOP_TOP=$( cd "$DIRTY_REPO" && git rev-parse --show-toplevel )

# The only tracked edit is an unrelated path — the dirty file `b` is another
# session's, so the stop must NOT block.
printf '%s\n' "/some/other/session/file.rb" > "$STOP_STATE/edits.log"
t "does not block on a dirty file this session never touched (#2216)"
assert_exit 0 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"session_id\":\"$STOP_SID\"}"

# Codex records the path REPO-RELATIVE (its `*** Update File:` header), so the
# scoping has to match both forms or it silently covers nothing there (#2352).
STOP_SID_REL="stop-scope-relative"
STOP_STATE_REL="$CLAUDE_PLUGIN_DATA/sessions/$STOP_SID_REL"
mkdir -p "$STOP_STATE_REL"
printf '%s\n' "b" > "$STOP_STATE_REL/edits.log"
t "blocks on a relative recorded path (Codex shape, #2352)"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"session_id\":\"$STOP_SID_REL\"}" \
  "STOP BLOCKED"

# Now the dirty file IS one this session edited — block exactly as before.
printf '%s\n' "$STOP_TOP/b" >> "$STOP_STATE/edits.log"
t "still blocks on a dirty file this session touched (#2216)"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"session_id\":\"$STOP_SID\"}" \
  "STOP BLOCKED"

# No edit log for the session (e.g. all edits went through Bash, which is not
# tracked) — fall back to blocking on any dirty file, preserving the guard.
t "falls back to blocking any dirty file when the session has no edit log (#2216)"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"session_id\":\"stop-scope-nolog\"}" \
  "STOP BLOCKED"

# #2355: a `git commit` makes the tracker delete edits.log, which used to be
# indistinguishable from "never tracked" — so for the window after every commit
# the scoping fell back to claiming EVERY dirty line, and the hook told the
# session to commit another session's files (it fired for real on 2026-08-10:
# a #2353 session was instructed to commit .claude/settings.json, a file only
# the concurrent #2348 session had touched). The tracker now verifies against
# git that the commit RESOLVED the tracked edits and leaves an edits_cleared_at
# sentinel: log missing + sentinel present = this session owns nothing until it
# records another edit.
#
# The incident shape: this session's tracked file `a` was genuinely committed
# (clean), the remaining dirty `b` is another session's in-flight work.
STOP_SID_COMMIT="stop-scope-committed-2355"
STOP_STATE_COMMIT="$CLAUDE_PLUGIN_DATA/sessions/$STOP_SID_COMMIT"
mkdir -p "$STOP_STATE_COMMIT"
printf '%s\n' "$STOP_TOP/a" > "$STOP_STATE_COMMIT/edits.log"
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s","cwd":"%s"}' "$STOP_SID_COMMIT" "$DIRTY_REPO" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "does not block on foreign dirty files after a commit resolved tracked edits (#2355)"
assert_exit 0 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"session_id\":\"$STOP_SID_COMMIT\"}"

# The sentinel must be CONDITIONAL on tracked edits having existed. A session
# whose writes all went through Bash has no log to resolve; writing the
# sentinel on its commits would switch the block-everything fallback off for
# the rest of the session — the exact coverage hole the ticket forbids.
STOP_SID_NOLOG_COMMIT="stop-scope-nolog-commit-2355"
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s","cwd":"%s"}' "$STOP_SID_NOLOG_COMMIT" "$DIRTY_REPO" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "a never-tracked session keeps the block-everything fallback after a commit (#2355)"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"session_id\":\"$STOP_SID_NOLOG_COMMIT\"}" \
  "STOP BLOCKED"

# The tool_response carries no exit status (#1873), so a FAILED or partial
# commit reaches the tracker's commit branch too. The tracked `b` is still
# dirty — nothing was resolved — so tracking must be KEPT: a sentinel here
# would let the session end its turn with its OWN work uncommitted.
STOP_SID_FAILED="stop-scope-failedcommit-2355"
STOP_STATE_FAILED="$CLAUDE_PLUGIN_DATA/sessions/$STOP_SID_FAILED"
mkdir -p "$STOP_STATE_FAILED"
printf '%s\n' "$STOP_TOP/b" > "$STOP_STATE_FAILED/edits.log"
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s","cwd":"%s"}' "$STOP_SID_FAILED" "$DIRTY_REPO" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "keeps blocking on own dirty files after a commit that did not resolve them (#2355)"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"session_id\":\"$STOP_SID_FAILED\"}" \
  "STOP BLOCKED"

t "an unresolved commit keeps the edit log (#2355)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -s "$STOP_STATE_FAILED/edits.log" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (edits.log was cleared)\n' "$TEST_NAME"
fi

# Recording a new edit re-arms the scoping: jus-track-edits clears the
# sentinel, the fresh log is non-empty, and intersection behaviour resumes.
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s/b"},"session_id":"%s"}' "$STOP_TOP" "$STOP_SID_COMMIT" \
  | "$SCRIPTS/jus-track-edits.sh" >/dev/null

t "recording an edit clears the commit sentinel (#2355)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ ! -f "$STOP_STATE_COMMIT/edits_cleared_at" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (sentinel still present)\n' "$TEST_NAME"
fi

t "blocks again once a new edit is recorded after the commit (#2355)"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"session_id\":\"$STOP_SID_COMMIT\"}" \
  "STOP BLOCKED"

# Porcelain without -uall COLLAPSES an untracked directory to one "?? newdir/"
# line, which can never match a logged file inside it — so the intersection
# silently skipped such files (pre-existing #2216 blind spot), and worse, the
# #2355 resolution check read them as "resolved" and wrote the sentinel over
# the session's own uncommitted work. The helper now passes -uall.
STOP_SID_NEWDIR="stop-scope-newdir-2355"
STOP_STATE_NEWDIR="$CLAUDE_PLUGIN_DATA/sessions/$STOP_SID_NEWDIR"
mkdir -p "$STOP_STATE_NEWDIR" "$DIRTY_REPO/newdir"
echo "own" > "$DIRTY_REPO/newdir/own.rb"
printf '%s\n' "$STOP_TOP/newdir/own.rb" > "$STOP_STATE_NEWDIR/edits.log"

t "blocks on a tracked file inside an untracked directory (#2355)"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\",\"session_id\":\"$STOP_SID_NEWDIR\"}" \
  "STOP BLOCKED"

# A commit in ANOTHER repo cannot resolve this log. `cd /other && git commit`
# runs with the session's persistent cwd still here, so the tracker would
# verify against the wrong toplevel, where foreign-repo log entries vacuously
# never match the dirty set — a FAILED commit over there read as "resolved".
# Any absolute log entry outside the verification toplevel must keep the log.
CROSS_REPO=$(cd "$(mktemp -d)" && pwd -P)
( cd "$CROSS_REPO" && git init -q && git config user.email t@t && git config user.name t \
  && touch seed && git add seed && git commit -q -m init && echo dirty > mine.rb )
STOP_SID_CROSS="stop-scope-crossrepo-2355"
STOP_STATE_CROSS="$CLAUDE_PLUGIN_DATA/sessions/$STOP_SID_CROSS"
mkdir -p "$STOP_STATE_CROSS"
printf '%s\n' "$CROSS_REPO/mine.rb" > "$STOP_STATE_CROSS/edits.log"
printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && git commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s","cwd":"%s"}' "$CROSS_REPO" "$STOP_SID_CROSS" "$DIRTY_REPO" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "a cross-repo commit keeps the log instead of writing the sentinel (#2355)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -s "$STOP_STATE_CROSS/edits.log" && ! -f "$STOP_STATE_CROSS/edits_cleared_at" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (log kept: %s, sentinel absent: %s)\n' "$TEST_NAME" \
    "$([[ -s "$STOP_STATE_CROSS/edits.log" ]] && echo yes || echo no)" \
    "$([[ ! -f "$STOP_STATE_CROSS/edits_cleared_at" ]] && echo yes || echo no)"
fi

t "still blocks in the other repo after the cross-repo commit failed (#2355)"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$CROSS_REPO\",\"session_id\":\"$STOP_SID_CROSS\"}" \
  "STOP BLOCKED"
rm -rf "$CROSS_REPO"

# The _anonymous state dir is shared by every session without an id. A
# sentinel there would assert "owns nothing" on behalf of ALL of them, and
# nothing prunes it — so one anonymous commit would permanently switch off the
# never-tracked fallback for every later anonymous session. No session_id →
# no sentinel; tracking still clears, which is the pre-#2355 status quo.
ANON_STATE="$CLAUDE_PLUGIN_DATA/sessions/_anonymous"
mkdir -p "$ANON_STATE"
printf '%s\n' "$STOP_TOP/a" > "$ANON_STATE/edits.log"
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"interrupted":false},"cwd":"%s"}' "$DIRTY_REPO" \
  | "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null

t "an anonymous resolved commit clears tracking but writes no sentinel (#2355)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ ! -f "$ANON_STATE/edits_cleared_at" && ! -f "$ANON_STATE/edits.log" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (sentinel: %s, log: %s)\n' "$TEST_NAME" \
    "$([[ -f "$ANON_STATE/edits_cleared_at" ]] && echo present || echo absent)" \
    "$([[ -f "$ANON_STATE/edits.log" ]] && echo present || echo absent)"
fi

t "anonymous sessions keep the block-everything fallback after a commit (#2355)"
assert_exit 2 "$SCRIPTS/jus-stop-uncommitted.sh" \
  "{\"cwd\":\"$DIRTY_REPO\"}" \
  "STOP BLOCKED"

# session_dirty_lines fails OPEN on a git-status error (right for its advisory
# consumers), but the tracker uses emptiness as a POSITIVE trust signal — a
# status failure must not read as "everything resolved". Stub git so rev-parse
# succeeds and `status` fails, the one split the unverifiable-cwd guard misses.
REALGIT=$(command -v git)
GITSTUB=$(mktemp -d)
cat > "$GITSTUB/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "status" ]] && exit 128; done
exec "$REALGIT" "\$@"
STUB
chmod +x "$GITSTUB/git"
STOP_SID_GITFAIL="stop-scope-gitfail-2355"
STOP_STATE_GITFAIL="$CLAUDE_PLUGIN_DATA/sessions/$STOP_SID_GITFAIL"
mkdir -p "$STOP_STATE_GITFAIL"
printf '%s\n' "$STOP_TOP/a" > "$STOP_STATE_GITFAIL/edits.log"
printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"interrupted":false},"session_id":"%s","cwd":"%s"}' "$STOP_SID_GITFAIL" "$DIRTY_REPO" \
  | PATH="$GITSTUB:$PATH" "$SCRIPTS/jus-post-bash-tracker.sh" >/dev/null
rm -rf "$GITSTUB"

t "a git-status failure keeps the log instead of reading as resolved (#2355)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -s "$STOP_STATE_GITFAIL/edits.log" && ! -f "$STOP_STATE_GITFAIL/edits_cleared_at" ]]; then
  printf '  \033[32m✓\033[0m %s\n' "$TEST_NAME"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILURES+=("$TEST_NAME")
  printf '  \033[31m✗\033[0m %s (log kept: %s, sentinel absent: %s)\n' "$TEST_NAME" \
    "$([[ -s "$STOP_STATE_GITFAIL/edits.log" ]] && echo yes || echo no)" \
    "$([[ ! -f "$STOP_STATE_GITFAIL/edits_cleared_at" ]] && echo yes || echo no)"
fi

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

for skill_file in "$PLUGIN_ROOT/skills/ticket-workflow/SKILL.md" "$PLUGIN_ROOT/skills/hard-rules/SKILL.md"; do
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
