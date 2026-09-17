# jus enforcement hooks — OpenAI Codex adapter

Runs all twelve shared hook scripts (`../scripts/`) under Codex's native
hooks system (#1976, completed in #4207).

> ⚠️ **`jus-ticket-claim-nudge.sh` WAS omitted, on a premise that is now
> falsified (#3674, resolved in #4207).** It was left out because nothing then
> available established that Codex fires `UserPromptSubmit` — the adapter's
> contract was described only for `PreToolUse`, `PostToolUse` and `Stop`. Codex
> exposes **twelve** hook events (`codex-rs/.../HookEventName.ts`), and a
> payload capture on 0.154.0 confirms the event fires carrying
> `hook_event_name`, `prompt`, `cwd` and `session_id` — exactly the fields the
> hook reads. It is registered.
>
> ⚠️ **The event-name casing is two different surfaces, and the generated file
> is the wrong one to copy.** `HookEventName.ts` is camelCase because it is the
> **app-server protocol**. The `hooks.json` config layer is PascalCase —
> `codex-rs/config/src/hook_config.rs` carries `#[serde(rename = "UserPromptSubmit")]`
> per event. Use `PreToolUse` / `PostToolUse` / `UserPromptSubmit` / `Stop`.

Codex's wire contract matches Claude Code's closely — JSON payload on stdin with
`tool_name` / `tool_input` / `session_id` / `stop_hook_active`, exit `2` blocks
with stderr as the reason — so the Bash blockers, the pre-commit gate, the Bash
tracker, and the Stop gate run **unchanged**.

**Two divergences, not one:**

1. **File edits.** Codex reports them as `tool_name "apply_patch"` with
   `tool_input.command` holding raw patch text, so those hooks run behind
   `scripts/jus-codex-adapt.sh`, which converts the patch into the `Edit` shape
   (added lines → `new_string`, removed → `old_string`, first
   `*** Update|Add File:` path → `file_path`).

2. ⚠️ **`tool_response` is a STRING here, and it silently killed the lint gate
   (#4207).** Claude Code sends an object; Codex sends a plain string. The Bash
   tracker read `.tool_response.interrupted`, jq cannot index a string, and it
   exited **5** — carried straight out by `set -euo pipefail`. Codex logged
   `PostToolUse Failed` and continued, so the only symptom was a line in its own
   hook log, while `last_linted_at` was never written and
   `jus-pre-commit-gate`'s state-tracked rule was **dead on Codex** — #1873
   returning through a payload shape instead of a missing field. Fixed in the
   **shared** script (a type guard, degrading to "not interrupted") rather than
   in the shim, because a hook that throws on an unexpected field type breaks
   the same fail-open doctrine the malformed-JSON sweep enforces.

> ⚠️ **These hooks do nothing outside a Juscribe project** (#4404). Each runs
> only when the payload's `cwd` is inside a git repository whose toplevel holds
> a `.jus/` directory; everywhere else they exit 0 in silence. That is the
> shared scripts' behaviour, so it applies here however this adapter is
> installed — including a user-scope install that every project on the machine
> sees. `JUS_HOOKS_EVERYWHERE=1` restores the old machine-wide behaviour.

## ⚠️ A Codex PLUGIN install gives you the skills and NOT these hooks (#4234)

Codex has a plugin system — `codex plugin add`, `codex plugin marketplace add` —
and **this bundle installs through it today with no extra files**:

```sh
codex plugin marketplace add https://github.com/juscribe/jus-skills.git
codex plugin add jus@jus-skills
```

Measured on codex-cli 0.154.0: all three skills arrive, namespaced by plugin —
`jus:hard-rules`, `jus:retrospective`, `jus:ticket-workflow`. Codex finds them by
default component discovery off `skills/`, which is why no `.codex-plugin/`
manifest is needed.

⚠️ **THE HOOKS DO NOT COME WITH THEM, AND NOTHING SAYS SO.** A plugin install
leaves you with the prompt-level layer and no enforcement, while looking like a
complete install. The hooks must still be installed by the `hooks.json` route
below — the two are complementary here, not alternatives.

**Measured, not inferred** (#4234). A `PreToolUse`/`^Bash$` hook that fires
through a project `.codex/hooks.json` does **not** fire when delivered by a
plugin. The control matters: same script, same repo, same prompt, traced by the
hook's own appended line rather than by what the model said.

⚠️ **A `hooks` field in the plugin manifest does not change this**, and it is
worth knowing because the manifest is ACCEPTED. `.codex-plugin/plugin.json`
takes `"hooks": "./hooks.json"` — the field is in Codex's own
`plugin-json-spec.md` — and a plugin declaring it installs without complaint and
still fires nothing. The same spec says at line 215 that "validation rejects
unsupported manifest fields such as `hooks`". Both cannot be true; what was
observed is neither rejection nor effect, which is the worst of the three.

⚠️ **Hooks declared inline as an array, Kimi-style, are also inert.** Tested
separately, same result.

## ⚠️ `codex exec` HANGS UNLESS YOU CLOSE STDIN

**`codex exec … < /dev/null`.** Without it, a scripted run can hang forever with
no error, which reads as the hook, the sandbox or the plugin misbehaving — it is
none of those.

`codex exec` reads stdin: its own `--help` says instructions come from there when
no prompt argument is given, and that piped stdin is appended as a `<stdin>`
block when one is. Under an agent or a CI runner stdin is typically an open pipe
that never reaches EOF, so Codex waits on input that will never arrive. The one
tell is a line on **stderr**:

```
Reading additional input from stdin...
```

Measured on #4234: the same command took **7.3s** with `< /dev/null` and was
still hanging at **420s** without it. Backgrounding it works too, for the same
reason and by accident — which is how this was found, after auth, project trust,
`CODEX_HOME` isolation, prompt shape and plugin presence had each been wrongly
suspected and eliminated in turn.

## Install

Prerequisite: the canonical bundle install (`git clone
https://github.com/juscribe/jus-skills.git ~/.jus-skills`) — every command in
`hooks.json` references `~/.jus-skills/…`. If your clone lives elsewhere,
rewrite the paths (e.g. `sed 's|~/.jus-skills|/your/path|g'`).

⚠️ **`jus init` DOES THIS FOR YOU since #4239.** Pick `ChatGPT / Codex` at the
tool prompt and it merges the rules below into `<repo>/.codex/hooks.json` —
merging rather than overwriting, and idempotent, so re-running adds nothing. It
needs `jq`; without it the install is skipped with a message rather than
half-written. Everything below is the manual path, for a project set up some
other way.

- **Per project:** merge this `hooks.json` into `<repo>/.codex/hooks.json`
  (create it as a copy if the project has none).
- **Per user (every project):** merge into `~/.codex/hooks.json`.

Codex **merges hook layers** — project + user + managed all run — so install
in one place only, or the hooks fire twice.

## Trust flow

Codex requires you to review and trust each non-managed hook (recorded per
hook hash — any edit re-flags it). After installing, run the `/hooks` slash
command inside Codex to review and approve.

⚠️ **This is why no installer can finish the job, `jus init` included.** Until
you approve, the hooks are present and not running — which looks exactly like a
completed install. `jus init` says so on the way out for that reason. Headless/CI runs can pass
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

**On codex-cli 0.154.0** (2026-09-15, #4207), against these exact files in a
fixture repo with a local bare remote — `codex exec --sandbox workspace-write
--dangerously-bypass-hook-trust -m gpt-6-astra`:

- A prompted `git push --force origin main` was **blocked**; the remote tip was
  unchanged.
- Every hook fired, traced by wrapping each command and recording its exit:
  `UserPromptSubmit` → `jus-ticket-claim-nudge`; `PreToolUse`/Bash → all five
  blockers including the two added in #4207; `PreToolUse`/`apply_patch` and
  `PostToolUse`/`apply_patch` → the shim; `Stop` → the dirty-tree gate, which
  **exited 2 and then 0 on the re-entry** (loop guard working).
- `tool_name` for a file edit is still `apply_patch`, so the shim is still the
  right adaptation.

⚠️ **Guardian can refuse before a hook ever runs.** Asking for a lint suppression
on 0.154.0 produced _"automatic approval review rejected the requested comment
because the Juscribe SOP forbids inline lint suppressions"_ — Codex's own review
layer reading the SOP, not our blocker. **A refusal is therefore not evidence
that a hook fired.** Verify with a trace of the hook's own exit, or with the unit
tests in `../tests.sh`; a benign edit is the way to observe the `apply_patch`
path without Guardian intercepting.

**Prior verification** was on codex-cli 0.145.0 with auth via `CODEX_API_KEY`
alone (no `codex login` needed for headless runs).

## Tests

`../tests.sh` carries a **"codex adapter"** section: manifest shape + referenced
scripts, the apply_patch shim (block on added suppression, pass on removal),
Bash passthrough, Stop-payload field compatibility, and — since #4207 — the
string `tool_response` regression, asserted twice: that the tracker does not
exit 5, and that `last_linted_at` is still recorded. The second is the one that
matters, because the first passes for a hook that does nothing at all.

It also carries an **"adapter hook parity"** section, which is what keeps this
file honest: every hook the Claude manifest registers must appear in each
adapter's manifest or be named in `ADAPTER_EXCEPTIONS` with a reason, and an
exception naming a hook that _is_ registered fails as stale.
