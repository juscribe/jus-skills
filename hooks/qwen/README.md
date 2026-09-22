# jus enforcement hooks — Qwen Code adapter

Runs all twelve shared hook scripts (`../scripts/`) under Qwen Code's hooks
system (#4263), in **thirteen registrations** — the same count and the same
split as the Claude Code manifest.

> ## ✅ LIVE-VERIFIED against qwen 0.24.0, 2026-09-17
>
> Every claim below was measured, each against a control arm:
>
> | Probe                                                | Result                                                                         |
> | ---------------------------------------------------- | ------------------------------------------------------------------------------ |
> | Model-issued forced push, manifest installed         | **Refused**, remote tip unmoved                                                |
> | Same, manifest absent (control)                      | Pushed; tip moved                                                              |
> | Model-issued `edit` adding a lint suppression        | **Refused**, file unchanged                                                    |
> | Same, control                                        | Suppression landed in the file                                                 |
> | Model-issued `write_file` carrying a suppression     | **Refused**                                                                    |
> | `Stop` with a dirty tree                             | **Blocks and forces continuation** — 9 model requests against 2 in the control |
> | `UserPromptSubmit` stdout                            | Injected into the model's context                                              |
> | `PostToolUse` `hookSpecificOutput.additionalContext` | Injected into the model's context                                              |
>
> **The "no degradation" claim below survives the measurement.** All thirteen
> registrations do on Qwen what they do on Claude Code.
>
> **No sign-in was involved** — see _Verifying this yourself_ below.

> ⚠️ **These hooks do nothing outside a Juscribe project** (#4404). Each runs
> only when the payload's `cwd` is inside a git repository whose toplevel holds
> a `.jus/` directory; everywhere else they exit 0 in silence. That is the
> shared scripts' behaviour, so it applies here however this adapter is
> installed — including a user-scope install that every project on the machine
> sees. `JUS_HOOKS_EVERYWHERE=1` restores the old machine-wide behaviour.

## The ticket's question, and the answer that flipped it

#4263 was filed asking whether a Qwen hook can **deny** or only annotate, and
said to establish that before building anything. It can deny.

|                | Qwen Code                                                                                                                                            | Claude Code                       |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| exit `0`       | stdout **JSON** controls behaviour. ⚠️ Plain text is **not** added to context — measured, `hookSpecificOutput.additionalContext` is the only channel | Claude Code adds plain stdout too |
| **exit `2`**   | **"Blocking error. Ignores stdout, passes stderr as error feedback to the model"**                                                                   | same                              |
| other non-zero | non-blocking; stderr in debug mode only; execution continues                                                                                         | same                              |
| response       | `hookSpecificOutput.permissionDecision` = `allow` / `deny` / `ask`                                                                                   | same                              |
| payload        | `tool_name`, `tool_input`, `tool_use_id`, `session_id`, `transcript_path`, `permission_mode`                                                         | same names                        |
| `Stop`         | carries `stop_hook_active` — _"true when continuing due to previous stop hook block"_                                                                | same                              |

The observe-only shape the ticket described is real, but it is the **skill
frontmatter** surface. The full hooks system is a separate and much larger one —
22 events — and it is modelled on Claude Code's.

✅ **`Stop` blocks here.** On Cursor and Antigravity the dirty-tree gate degrades
to a message because their stop events cannot refuse; Qwen's `stop_hook_active`
exists precisely to guard a stop hook that already blocked. **This is the only
one of the four new adapters with no degradation against Claude Code.**

## Verifying this yourself — no Qwen account needed

⚠️ **The sign-in this adapter waited on turned out to be unnecessary.** Qwen takes
an OpenAI-compatible provider as first-class flags, so a local stub answering
`/chat/completions` with a canned `tool_calls` response drives a **real**
model-issued tool call through the real hook path, with no account and no network.

```sh
qwen -y --auth-type openai --openai-base-url http://127.0.0.1:8812 --openai-api-key stub -m stub-model "…"
```

⚠️ **`--auth-type openai` is required, and its absence does not read as a missing
flag.** With a base URL and a key but no auth type, the run dies at _"No auth type
is selected"_ — which reads like a credential problem rather than a flag problem.

⚠️ **Do not pass `--bare`.** It skips startup auto-discovery, and that includes
hook discovery: the run completes, looks clean, and fires nothing.

⚠️ **Do not override `HOME` to isolate the config.** `jus` resolves the bundle
at `~/.jus-skills` (#4759), so a fake home resolves to a bundle that is not
there — and a hook that cannot find its bundle fails **open**, silently, which
is the same shape as the pre-launcher trap this replaces. Measured then: a
clean "qwen cannot deny" result, which is the wrong answer to this adapter's
deciding question. Symlink the bundle into the fake home, point
`JUS_SKILLS_DIR` at it, or leave `HOME` alone.

⚠️ **Always run a control arm.** The trap above was caught by the control failing
to differ from the guarded arm, and by nothing else.

⚠️ **Qwen requires `read_file` before `edit`**, and refuses a relative `file_path`.
A control arm that skips either reports the edit not landing, which is
indistinguishable from the blocker working.

## Setup

One shared clone per machine, then merge the `hooks` key into Qwen's settings:

```sh
git clone https://github.com/juscribe/jus-skills.git ~/.jus-skills
```

**Per project** — merge into `.qwen/settings.json`:

```sh
jq -s '.[0] * .[1]' .qwen/settings.json ~/.jus-skills/hooks/qwen/settings.json > .qwen/settings.json.new && mv .qwen/settings.json.new .qwen/settings.json
```

⚠️ **MERGE, NEVER COPY.** `settings.json` is Qwen's whole configuration file, not
a hooks-only file — overwriting it discards the model, the auth and everything
else the user has set. If `.qwen/settings.json` does not exist yet, copy is safe:

```sh
mkdir -p .qwen && cp ~/.jus-skills/hooks/qwen/settings.json .qwen/settings.json
```

⚠️ **Registering at project _and_ user scope fires every hook twice.** Pick one.

## Every command is `jus hook`, so `jus` has to be on PATH

Since #4759 no command in this manifest names a location — each is
`jus hook [--adapt qwen] <name>`, and `jus` resolves the bundle at run time.
`../tests.sh` holds every manifest to that shape, and refuses one carrying a
path, a `~` or a `$`.

⚠️ **The chain is a FALLBACK, and `JUS_SKILLS_DIR` comes FIRST — it wins even
when the directory it names does not exist.** `JUS_SKILLS_DIR`, then the
Homebrew prefix, then `~/.jus-skills`: the first one found answers. So a typo in
that variable silently disables every guard while a healthy clone sits in
`~/.jus-skills`. It is **not** layered overrides with the most specific last,
which is how an eye trained on git config or eslint will read it.

✅ **Qwen reaches it through a shell, which is how `jus` is found on `PATH`.**
It does not spawn a hook command directly: `getShellConfiguration()` returns
`argsPrefix: ["-c"]` on every POSIX platform, so the whole command string is
handed to `bash -c` — read from qwen-code's own shipped source on #4261. Qwen is
also one of the five adapters `script/dev/drive-adapter` drives end to end: on
#4759 it PASSed with this launcher on `PATH`, and FAILed with hook liveness
**SILENT** against the released CLI that predates `jus hook`. That pair is the
measurement, and it is why the CLI must be published before the bundle.

⚠️ **THE OLD TILDE TRAP IS GONE AND ITS FAILURE SHAPE IS NOT.** Until #4759
every command named `~/.jus-skills/…`; a shell expands `~` only at the START of
a word, so a tilde one character later was a literal, the command was not found,
the exit was 127, and a non-2 exit is fail-**open** — every hook silently dead
with the session looking healthy (#4417). A missing `jus` on `PATH` produces
exactly that, so it is the first thing to check when the guards go quiet:
`jus hook --where` prints which bundle answered, and `jus doctor` says so too.

## ⚠️ The matcher trap, which is why this shim exists at all

[QwenLM/qwen-code#11823](https://github.com/QwenLM/qwen-code/issues/11823), filed
2026-09-14:

> _"A tool hook matcher written with Claude Code's tool names never matches in
> qwen-code when that name differs from qwen's own display name."_

A `"matcher": "Bash"` **never fires**. `"Write|Edit"` fires for `edit` and not for
`write_file`. Qwen's permission rules already map the Claude names; its hook
matchers do not. PR #11826 is referenced as the fix, so a current build may
behave differently.

**This manifest matches on Qwen's own names** — `run_shell_command`, `edit`,
`write_file` — and the shim renames afterwards. That is correct on every version,
before the fix and after it, and it fails loudly rather than silently if a name
ever changes: the hook simply does not appear in `/hooks`.

⚠️ **Do not "simplify" the matchers to Claude names once #11826 ships.** It would
make this adapter silently inert on every older Qwen a user might be running, and
a hook that does not fire produces no error at all.

## What the shim does — and does not

**Only the tool name**, because everything else already matches:

| Qwen                | shared scripts |
| ------------------- | -------------- |
| `run_shell_command` | `Bash`         |
| `edit`              | `Edit`         |
| `write_file`        | `Write`        |
| `read_file`         | `Read`         |

✅ **The map is explicit, not shape-inferred.** Qwen publishes its thirteen tool
names, so inferring would be choosing to be less certain than the vendor — the
opposite of the Copilot adapter, which has to infer because GitHub publishes only
`bash`. A shape fallback sits behind the map for a tool it has not met (a new
Qwen tool, or a plugin's) and never overrides a known name.

⚠️ **There is NO response translation, deliberately.** Exit 2 plus stderr is
already what Qwen reads as a block, and a shared script's `hookSpecificOutput`
object on exit 0 is already the shape Qwen expects. The shim `exec`s the target,
so its stdout, stderr and exit code reach Qwen untouched. Wrapping either would
be the Antigravity work (#4262) done where it is not needed.

✅ **No empty-string exposure.** The shim has no multi-source fallback chain, and a
capture on 2026-09-19 found a real `cwd`, `session_id` and `transcript_path` on
all four registered events. The class and the seven-shim audit:
[`../README.md`](../README.md) (#4428).

## Event mapping

Thirteen registrations, twelve scripts — the same as Claude Code's manifest.

| Shared hook                           | Claude event + matcher                   | Qwen event + matcher                   |
| ------------------------------------- | ---------------------------------------- | -------------------------------------- |
| `jus-block-force-push.sh`             | `PreToolUse` / `Bash`                    | `PreToolUse` / `^run_shell_command$`   |
| `jus-block-no-verify.sh`              | `PreToolUse` / `Bash`                    | `PreToolUse` / `^run_shell_command$`   |
| `jus-pre-commit-gate.sh`              | `PreToolUse` / `Bash`                    | `PreToolUse` / `^run_shell_command$`   |
| `jus-block-accepted-manifest-edit.sh` | `PreToolUse` / `Bash`                    | `PreToolUse` / `^run_shell_command$`   |
| `jus-blocker-date-nudge.sh`           | `PreToolUse` / `Bash`                    | `PreToolUse` / `^run_shell_command$`   |
| `jus-block-lint-suppression.sh`       | `PreToolUse` / `Edit\|Write\|MultiEdit`  | `PreToolUse` / `^(edit\|write_file)$`  |
| `jus-post-bash-tracker.sh`            | `PostToolUse` / `Bash`                   | `PostToolUse` / `^run_shell_command$`  |
| `jus-track-edits.sh`                  | `PostToolUse` / `Edit\|Write\|MultiEdit` | `PostToolUse` / `^(edit\|write_file)$` |
| `jus-start-comment-nudge.sh`          | `PostToolUse` / `Edit\|Write\|MultiEdit` | `PostToolUse` / `^(edit\|write_file)$` |
| `jus-docs-nudge.sh`                   | `PostToolUse` ×2                         | `PostToolUse` ×2 — both matchers       |
| `jus-stop-uncommitted.sh`             | `Stop`                                   | `Stop` — **a real gate here**          |
| `jus-ticket-claim-nudge.sh`           | `UserPromptSubmit`                       | `UserPromptSubmit`                     |

✅ **`jus-docs-nudge.sh` is registered twice, exactly as on Claude Code**, because
Qwen's matchers split the same event the same way. On Copilot and Antigravity it
appears once, because those tools have no matcher to split on.

## Skills — and the second install root

⚠️ **Qwen does not read `.agents/skills/`.** It scans `.qwen/skills/` and
`~/.qwen/skills/` and nothing else;
[QwenLM/qwen-code#2042](https://github.com/QwenLM/qwen-code/issues/2042) asks for
`.agents` support and is closed with no linked PR. `jus init` writes both roots
(#4257); a hand install must too, or Qwen loads no skills and reports success.

```sh
mkdir -p .qwen/skills && ln -sfn ~/.jus-skills/skills/* .qwen/skills/
```

## Tests

`jus/hooks/tests.sh`, in the `qwen adapter` section: the settings file is valid
JSON with a `hooks` key, every script it names exists, all twelve are registered,
**no matcher uses a Claude Code tool name** (the #11823 trap, asserted rather than
remembered), and the shim renames each of Qwen's four tools before the guards see
them — including that a `run_shell_command` force-push blocks and that `write_file`
reaches the suppression guard, which is the exact pair #11823 reports breaking.
