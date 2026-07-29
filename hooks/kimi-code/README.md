# jus enforcement hooks — Kimi Code adapter

Runs the shared hook scripts (`../scripts/`) under Kimi Code's native hooks
system (#1977). Kimi's wire contract is Claude-shaped — snake_case JSON on
stdin with Claude's own tool names (`Bash`/`Edit`/`Write`), exit `2` blocks
with stderr as the reason, `Stop` carries `stop_hook_active` — with one
empirically pinned divergence (kimi-code 0.29.2): the file-path key is
`path`, not `file_path`. `scripts/jus-kimi-adapt.sh` maps that key and
delegates; the Bash blockers, pre-commit gate, Bash tracker, and Stop gate
run unchanged.

## Two ways to install

**1. Plugin (recommended — skills + hooks + auto-loaded hard-rules in one).**
The bundle root ships `kimi.plugin.json`: skills from `./skills/`, these
hooks with plugin-relative paths (Kimi runs plugin hooks with cwd = plugin
root), and `sessionStart.skill: hard-rules` so the guardrails skill loads at
every session start. Install the published bundle
(`github.com/juscribe/jus-skills`) through Kimi's plugin manager (`/plugins`).

**2. Config append (hooks only).** Kimi reads hooks **only** from
`~/.kimi-code/config.toml` — there is no project-level config. Append
`config-hooks.toml` to it (paths assume the canonical `~/.jus-skills`
install; adjust if your clone lives elsewhere). Don't combine with the
plugin install — the rules would fire twice (Kimi de-duplicates only
identical `(cwd, command)` pairs, and the two installs use different paths).

## Kimi-specific behavior

- **Blockable events are PreToolUse, Stop, UserPromptSubmit only.**
  PostToolUse is observe-only: the trackers still run and write session
  state (so the pre-commit lint gate works), but nothing they print reaches
  the model.
- **The dirty-tree nudge rides UserPromptSubmit instead of PostToolUse** —
  `scripts/jus-kimi-prompt-nudge.sh` injects a commit-immediately reminder
  into context at prompt time when the working tree is dirty (exit-0 stdout
  on that event is context-injected; the PostToolUse `systemMessage` channel
  does not exist on Kimi). It never exits 2 — a blockable event blocking the
  user's own prompt would be worse than no nudge. The start-comment nudge
  has no Kimi channel and stays prompt-level (skill layer).
- **The Stop rule has no matcher** — Kimi matches Stop hooks against an
  empty string, so any non-empty matcher would never fire.
- **Fail-open is Kimi doctrine**: hook errors/timeouts allow the action.
  Treat the hooks as a guardrail, not a sandbox (same stance as the README).
- **Pre-1.0 churn**: contract pinned against kimi-code 0.29.2 (docs +
  source + live capture). The `[[hooks]]` schema rejects unknown fields, so
  a future field rename fails loudly at config load, not silently.

## Live-verified

On kimi-code 0.29.2 / kimi-k2.7-code against these exact files: a prompted
`git push --force` was denied (the model relayed the hook's `git revert`
guidance), and a prompted Edit adding an `eslint`-`disable` line was blocked
with the file left byte-identical.

Host prerequisites match the shared scripts: `bash` 4+, `jq`, `git`.

## Tests

`../tests.sh` carries a "kimi-code adapter" section: config-snippet and
plugin-manifest shape checks, captured-payload fixtures through the real
scripts (path-key shim, Write content, removal pass-through), tracker state
via the shim, and the prompt nudge's dirty/clean/fail-open behavior.
