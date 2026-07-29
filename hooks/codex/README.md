# jus enforcement hooks — OpenAI Codex adapter

Runs the same nine shared hook scripts (`../scripts/`) under Codex's native
hooks system (#1976). Codex's wire contract matches Claude Code's closely —
JSON payload on stdin with `tool_name` / `tool_input` / `session_id` /
`stop_hook_active`, exit `2` blocks with stderr as the reason — so the Bash
blockers, the pre-commit gate, the Bash tracker, and the Stop gate run
**unchanged**. The one divergence is file edits: Codex reports them as
`tool_name "apply_patch"` with `tool_input.command` holding raw patch text,
so those hooks run behind `scripts/jus-codex-adapt.sh`, which converts the
patch into the `Edit` shape (added lines → `new_string`, removed →
`old_string`, first `*** Update|Add File:` path → `file_path`).

## Install

Prerequisite: the canonical bundle install (`git clone
https://github.com/juscribe/jus-skills.git ~/.jus-skills`) — every command in
`hooks.json` references `~/.jus-skills/…`. If your clone lives elsewhere,
rewrite the paths (e.g. `sed 's|~/.jus-skills|/your/path|g'`).

- **Per project:** merge this `hooks.json` into `<repo>/.codex/hooks.json`
  (create it as a copy if the project has none).
- **Per user (every project):** merge into `~/.codex/hooks.json`.

Codex **merges hook layers** — project + user + managed all run — so install
in one place only, or the hooks fire twice.

## Trust flow

Codex requires you to review and trust each non-managed hook (recorded per
hook hash — any edit re-flags it). After installing, run the `/hooks` slash
command inside Codex to review and approve. Headless/CI runs can pass
`--dangerously-bypass-hook-trust` for a single invocation.

## What's enforced here vs. Claude Code

Identical coverage: force-push block, `--no-verify` block, pre-commit lint
gate, lint-suppression block (via the patch shim), edit/command tracking,
dirty-tree + start-comment nudges (`systemMessage` is honored by Codex), and
the dirty-tree Stop gate (`stop_hook_active` loop guard included). Session
state lives under `${CLAUDE_PLUGIN_DATA:-$TMPDIR/jus}/sessions/<session_id>`
— the Claude-named env var is just the override knob; unset, it lands in the
temp dir.

Host prerequisites are the same as the shared scripts: `bash` 4+, `jq`,
`git`. Hooks fail open when any of those are missing.

## Live-verified

On codex-cli 0.145.0 against these exact files in a fixture repo (`codex exec
--json --sandbox workspace-write --dangerously-bypass-hook-trust`, auth via
the `CODEX_API_KEY` env var alone — no `codex login` needed for headless
runs): a prompted `git push --force origin main` was denied with the
force-push blocker's full message and nothing reached the remote, and a
prompted apply_patch adding a `rubocop`-`disable` line was blocked through
the `jus-codex-adapt.sh` shim with the file left byte-identical.

## Tests

`../tests.sh` carries a "codex adapter" section: manifest shape + referenced
scripts, the apply_patch shim (block on added suppression, pass on removal),
Bash passthrough, and Stop-payload field compatibility.
