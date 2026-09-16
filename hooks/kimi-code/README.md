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
- **A commit reminder rides UserPromptSubmit** —
  `scripts/jus-kimi-prompt-nudge.sh` injects a commit-immediately reminder
  into context at prompt time when the working tree is dirty, because exit-0
  stdout on that event is context-injected. It never exits 2 — a blockable
  event blocking the user's own prompt would be worse than no nudge. The
  start-comment nudge has no Kimi channel and stays prompt-level (skill layer).
  ⚠️ **This is Kimi's only mid-session commit reminder, and it has no Claude
  Code counterpart.** It began as the Kimi channel for a `PostToolUse` hook
  that #3952 deleted — that one emitted `systemMessage` only, which the model
  never sees, so it was removed as ineffectual. This one reaches the model, so
  it stays. Do not "restore parity" by deleting it.
- **The Stop rule has no matcher** — Kimi matches Stop hooks against an
  empty string, so any non-empty matcher would never fire.
- **Fail-open is Kimi doctrine**: hook errors/timeouts allow the action.
  Treat the hooks as a guardrail, not a sandbox (same stance as the README).
- **Pre-1.0 churn**: contract pinned against kimi-code 0.29.2 (docs +
  source + live capture). The `[[hooks]]` schema rejects unknown fields, so
  a future field rename fails loudly at config load, not silently.

## ⚠️ TWO manifests, and they had drifted apart (#4208)

`config-hooks.toml` and `../../kimi.plugin.json` carry the **same** rules by
different paths — one appended to `~/.kimi-code/config.toml`, one installed via
`/plugins`. A user gets one of them, so **a hook in one and not the other is an
enforcement rule that exists or not depending on how they installed**, with
nothing telling them which they got.

They were disagreeing: the plugin registered `jus-ticket-claim-nudge.sh` on
`UserPromptSubmit`; the TOML did not. `../tests.sh` now holds the two against
each other, which is a different check from holding each against the Claude
manifest — an exception covering both surfaces excuses the pair together and
hides exactly this.

⚠️ **`jus-kimi-prompt-nudge.sh` does not supersede `jus-ticket-claim-nudge.sh`,
and #4207 wrongly recorded that it did.** They share an event and do different
jobs: the Kimi nudge is a dirty-tree commit reminder with no Claude Code
counterpart (see above — do not delete it), and the claim nudge fetches the
ticket a prompt names and feeds it back as context. Both are registered on both
surfaces.

## Verified — and what is NOT

**Blocking behaviour, on kimi-code 0.29.2 / kimi-k2.7-code** against these exact
files: a prompted `git push --force` was denied (the model relayed the hook's
`git revert` guidance), and a prompted Edit adding an `eslint`-`disable` line
was blocked with the file left byte-identical.

**Config load, on kimi-code 0.29.2** (#4208): the shipped `config-hooks.toml` is
run through `kimi doctor` under an isolated `KIMI_CODE_HOME`, which answers
_"All checked config files are valid"_. This matters more than it sounds: the
`[[hooks]]` schema **rejects unknown fields and an extra key fails the whole
config load**, so "the TOML parses" is not the question. The check is shown to
respond to its variable — adding one `bogus_key` produces
`hooks[11]: Unrecognized key`.

⚠️ **The two blockers added in #4208 — `jus-block-accepted-manifest-edit.sh` and
`jus-blocker-date-nudge.sh` — were NOT exercised in a live session.** The
evidence for them is: the config loads, and each runs clean on the
`PreToolUse`/Bash payload captured from a live 0.29.2 session. That is the same
standard the rest of this adapter's per-hook coverage is held to, but it is not
a live end-to-end run, and it should not be described as one. A live pass needs
a logged-in kimi; do that when there is one.

Host prerequisites match the shared scripts: `bash` 4+, `jq`, `git`.

⚠️ **`KIMI_CODE_HOME` is the knob for testing anything here.** It redirects the
config root, so a check never has to touch `~/.kimi-code/config.toml` — the
user's real file, mode `0600`.

## Tests

`../tests.sh` carries a **"kimi-code adapter"** section: config-snippet and
plugin-manifest shape checks, captured-payload fixtures through the real
scripts (path-key shim, Write content, removal pass-through), tracker state
via the shim, and the prompt nudge's dirty/clean/fail-open behavior.

Since #4208 it also carries **"kimi manifest agreement"**: the two manifests
register the same hooks, both new blockers run on the captured payload, and
`kimi doctor` accepts the shipped config — **skipped, not failed, where kimi is
absent**, since this bundle ships to machines that will never have it.
