# jus enforcement hooks — Gemini CLI adapter

Runs all thirteen shared hook scripts (`../scripts/`) under Gemini CLI's hooks
system (#4419).

> ## ⚠️ NOT LIVE-VERIFIED
>
> Gemini CLI is **not installed** on the machine this was written on, so nothing
> here has been watched refusing anything. Every claim below is read out of the
> published `@google/gemini-cli@0.60.0` package — `bundle/docs/hooks/reference.md`
> and `bundle/docs/tools/` — rather than from a run.
>
> The no-account stub recipe from `../qwen/README.md` should apply: Gemini CLI
> takes `GOOGLE_GEMINI_BASE_URL`, so a local stub answering the Gemini API shape
> can drive a real model-issued tool call through the real hook path. **Running
> it is the work this box is waiting on.**

> ## ⚠️ GEMINI CLI IS NOT SUNSET, WHATEVER TWO OF OUR DOCS SAID
>
> `installing-the-bundle.md` and `../antigravity/README.md` both asserted, as
> fact, that it was retired on 2026-06-18 in favour of Antigravity. Measured
> **2026-09-19** against the npm registry:
>
> | Tag       | Version                                        |
> | --------- | ---------------------------------------------- |
> | `latest`  | 0.60.0                                         |
> | `nightly` | **0.62.0-nightly.20260919** — cut that morning |
> | `preview` | 0.61.0-preview.0                               |
>
> The package's own `time.modified` was that same day, and the licence is
> Apache-2.0. A project sunset in June does not cut a nightly in September.
>
> **Antigravity is a separate product and keeps its own adapter.** What changed
> is that "Gemini" in the `jus init` menu now means this CLI rather than a
> redirect.

## Setup

One shared clone per machine, then merge the `hooks` key into Gemini's settings:

```sh
git clone https://github.com/juscribe/jus-skills.git ~/.jus-skills
```

**Per project** — merge into `.gemini/settings.json`:

```sh
jq -s '.[0] * .[1]' .gemini/settings.json ~/.jus-skills/hooks/gemini/settings.json > .gemini/settings.json.new && mv .gemini/settings.json.new .gemini/settings.json
```

⚠️ **MERGE, NEVER COPY.** `settings.json` is Gemini's whole configuration file,
not a hooks file — the same trap as Qwen's. If it does not exist yet, copy is
safe:

```sh
mkdir -p .gemini && cp ~/.jus-skills/hooks/gemini/settings.json .gemini/settings.json
```

`jus init` does this for you, and `jus refresh-hooks` tops it up when the bundle
registers something new (#4420, #4421).

**Scope.** Gemini merges four layers, highest first: project
`.gemini/settings.json`, user `~/.gemini/settings.json`, system
`/etc/gemini-cli/settings.json`, then extensions. ⚠️ **Install at ONE of them** —
two copies register every hook twice per event.

## Why this shim is nearly a passthrough

Gemini CLI's hook contract already uses Claude Code's field names, which is not
true of any other adapter here:

| What the shared scripts read                              | Gemini CLI                              |
| --------------------------------------------------------- | --------------------------------------- |
| `session_id`, `transcript_path`, `cwd`, `hook_event_name` | the base input schema, exactly          |
| `tool_name`, `tool_input`                                 | `BeforeTool` / `AfterTool`, exactly     |
| `file_path`, `old_string`, `new_string`                   | `replace`'s arguments, exactly          |
| `file_path`, `content`                                    | `write_file`'s arguments, exactly       |
| `command`                                                 | `run_shell_command`'s argument, exactly |
| `stop_hook_active`                                        | `AfterAgent`, exactly                   |

So nothing is renamed and no field is moved. **The shim maps tool names and
does nothing else** — and that one map is load-bearing, because every guard
gates on `tool_name == "Bash"` and a matcher written `Bash` never fires.

**Blocking is exit 2 with stderr as the reason**, which is what the thirteen
shared scripts already do, so `exec` carries the code through untouched.

## Event mapping

| jus hook                                                       | Gemini event  | Matcher                   |
| -------------------------------------------------------------- | ------------- | ------------------------- |
| the five command guards                                        | `BeforeTool`  | `^run_shell_command$`     |
| `jus-block-lint-suppression`                                   | `BeforeTool`  | `^(replace\|write_file)$` |
| `jus-post-bash-tracker`, `jus-docs-nudge`                      | `AfterTool`   | `^run_shell_command$`     |
| `jus-track-edits`, `jus-start-comment-nudge`, `jus-docs-nudge` | `AfterTool`   | `^(replace\|write_file)$` |
| `jus-ticket-claim-nudge`                                       | `BeforeAgent` | —                         |
| `jus-stop-uncommitted`                                         | `AfterAgent`  | —                         |

## ⚠️ The degradation, and it runs the OPPOSITE way to every other one

**Gemini CLI has no `Stop`.** The nearest event is `AfterAgent`, and denying
there **forces a retry**: the `reason` is sent to the agent as a new prompt, and
exit 2 "rejects the response and triggers an automatic retry turn using stderr
as the feedback prompt".

So the dirty-tree gate does not refuse an exit here — it makes the agent **keep
going** with "you have uncommitted work" as its next instruction. That is
arguably what you want from a commit-before-stop rule, and it is emphatically
not what the hook was written to do.

⚠️ **Every other adapter's Stop degradation is "cannot block".** This one blocks
in a direction the script did not choose, which is worse, because it looks like
it worked. `stop_hook_active` is carried on the payload under that exact name,
so the loop guard still ends the retry cycle — that is the only thing keeping
this bounded.

**`continue: false` stops the session outright** and is the honest primitive for
a real refusal. It is deliberately not used: the shared script's contract is exit
2, and a shim that upgraded an advisory exit into a killed session would be
making a policy decision the script did not.

## Skills

Gemini CLI reads `.agents/skills/` and gives it **precedence over
`.gemini/skills/`**, so the canonical install (`jus init`, or the clone plus
symlinks) already works with no extra root — unlike Qwen, which needs one.

## Tests

`jus/hooks/tests.sh`, in the `gemini adapter` section: the manifest is valid JSON
in Gemini's shape, every script it names exists in the bundle, all thirteen are
registered, and the shim maps each of the four tool names — including that an
unknown name falls through to shape inference rather than being dropped.
