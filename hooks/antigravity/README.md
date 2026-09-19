# jus enforcement hooks — Google Antigravity adapter

Runs all twelve shared hook scripts (`../scripts/`) under Antigravity's hooks
system (#4262).

> ## ⚠️ THIS FILE SAID GEMINI CLI WAS SUNSET. IT IS NOT (#4419)
>
> The claim was that Antigravity replaced Gemini CLI, retired 2026-06-18, and
> this adapter was built on it. Measured **2026-09-19** against the npm
> registry: `@google/gemini-cli` is on `latest` **0.60.0**, cut a **nightly
> 0.62.0-nightly.20260919 that morning**, has a `0.61.0-preview.0` in flight,
> and is Apache-2.0. A project sunset in June does not cut a nightly in
> September.
>
> **Nothing about this adapter changes.** Antigravity is a separate product with
> its own hook contract, and everything below still holds. What changed is that
> it is no longer Gemini CLI's successor here: Gemini CLI has its own adapter at
> `../gemini/`, and `jus init`'s "Gemini" now means that.
>
> ⚠️ **The manifests are not interchangeable, and that is the practical cost of
> the old claim.** This one registers `PreToolUse`, `PostToolUse`, `Stop` and
> `PreInvocation`; **Gemini CLI fires none of those names**, so it would have
> registered nothing at all.

> ## ⚠️ THE DOCUMENTATION IS INSIDE THE BINARY, NOT ON THE WEB
>
> This adapter's first cut was written from three third-party blog posts and a
> pull request, on the belief that Google documents none of this —
> `antigravity.google/docs/cli/reference` lists a `/hooks` slash command and
> stops, and the plugins page says hooks live "inside a plugin's `hooks.json` or
> your primary `settings.json`" and stops.
>
> **`agy` ships the complete lifecycle-hooks guide as an embedded string.** File
> format, the five events, every per-event input and output contract, the
> matcher rules, the limitations:
>
> ```sh
> strings -a "$(command -v agy)" | grep -A400 '^# Lifecycle Hooks'
> ```
>
> It is more precise than anything published about this tool, it is versioned
> with the binary you actually have, and it was on the machine the whole time.
> **Read it before changing anything here**, and prefer it over this file where
> the two disagree.
>
> Everything below was then measured against `agy 1.2.5` in the orb, signed in,
> reading `~/.gemini/antigravity-cli/log/`. Where a number or a key appears, it
> came from a captured payload or an engine log line.

> ⚠️ **These hooks do nothing outside a Juscribe project** (#4404). Each runs
> only when the payload's `cwd` is inside a git repository whose toplevel holds
> a `.jus/` directory; everywhere else they exit 0 in silence.
> `JUS_HOOKS_EVERYWHERE=1` restores the old machine-wide behaviour. ⚠️ **On this
> tool that gate is the hard part** — see _The cwd Antigravity never sends_.

## Setup

One shared clone per machine, then the **global** config:

```sh
git clone https://github.com/juscribe/jus-skills.git ~/.jus-skills
```

```sh
mkdir -p ~/.gemini/config && cp ~/.jus-skills/hooks/antigravity/hooks.json ~/.gemini/config/hooks.json
```

⚠️ **Global, not project scope, and this reverses what the first cut said.**
Project scope (`<workspace>/.agents/hooks.json`) is what every third-party
source agreed on and it is a real path — the 1.1.1 changelog fixed it "by
reloading hooks whenever workspaces change". **In `agy -p` no workspace-change
event ever fires**, so it never loads. Measured with the same file at both
paths, the workspace trusted in `settings.json`:

| Path                             | Engine log                                       |
| -------------------------------- | ------------------------------------------------ |
| `~/.gemini/config/hooks.json`    | `loaded 3 named hooks from 1 hooks.json file(s)` |
| `<workspace>/.agents/hooks.json` | `loaded 0 named hooks from 0 hooks.json file(s)` |

⚠️ **`~/.gemini/antigravity-cli/hooks.json` is the wrong global path**, though
the Antigravity developer guide names it. The changelog records that as a bug:
_"Fixed a bug where the `/hooks` command wrote configurations to
`~/.gemini/antigravity-cli/hooks.json` instead of the shared
`~/.gemini/config/hooks.json`."_

⚠️ **A hook declared in both scopes runs twice** — both are loaded and merged.
Pick one.

## How the `~` in every command is expanded — the one adapter that may be exempt

`../tests.sh` holds every path in this manifest at the start of a word, because
that is the only position a shell expands `~` (#4417). Antigravity is the one
adapter where that guard may be stricter than the engine requires, and it is
unresolved.

**What its own shipped code says.** The lifecycle-hooks guide is embedded in the
`agy` binary rather than published on the web, and on the `command` field it
reads:

> **`command`** (string, required): The shell command to execute (run via `sh -c`
> on Unix, `cmd /c` on Windows). `~` is expanded to the home directory.

Read it yourself:

```sh
strings -a "$(command -v agy)" | grep -A60 '^# Lifecycle Hooks'
```

⚠️ **It says `~` is expanded. It does not say WHERE in the string.** If the
engine expands only a leading tilde, or leaves it to the `sh -c` it also names,
the positional rule holds here exactly as everywhere else. If it expands
anywhere, this adapter is genuinely exempt — and a vendor guarantee is still not
a local check, so the guard stays either way.

⚠️ **The live probe is still owed.** Three `PreInvocation` hooks — bare tilde,
quoted tilde, and an absolute path as the control arm — never reached the
engine: an isolated `HOME` carries no Antigravity credentials, so the run stopped
at the OAuth prompt and the control arm did not fire either. That is
inconclusive, not negative. Settling it needs the real `HOME`, which means
writing to your own `~/.gemini/config/hooks.json`.

## ⚠️ One malformed entry disables the whole file

```
hooks.go:101] Failed to parse hooks file …/hooks.json:
  invalid hook "gwrapped": command hook must specify 'command'
```

Parsing is **per file, not per hook**. A single entry the engine dislikes takes
every other named hook in that file down with it, and the only symptom is
`loaded 0 named hooks` in a log nobody reads. The adapter installs cleanly and
protects nothing.

The shape that caused it is the one difference between the two families of
event, and it is easy to get wrong because the tool events want the opposite:

| Event                                     | Structure                                             |
| ----------------------------------------- | ----------------------------------------------------- |
| `PreToolUse`, `PostToolUse`               | **grouped** — `{"matcher": …, "hooks": [handler, …]}` |
| `PreInvocation`, `PostInvocation`, `Stop` | **flat** — `[handler, …]`, `command` directly on each |

⚠️ **A matcher of `""` matches nothing here**, despite the guide listing it
beside `"*"`. `.*` fired on every tool and is what this manifest uses.

## ⚠️ The response is validated strictly, per event

Hook stdout is parsed with **protojson, `DiscardUnknown` off**, against a
**different message for each event**. An unrecognised key is a hard error:

```
prehooks.go:43] failed to unmarshal result from hook … via protojson:
  {"decision":"allow","allow_tool":true,"bogus_unknown_key":"x"}:
  proto: (line 1:2): unknown field "decision"
```

That is `PreInvocation` rejecting `decision` at the **first** key. The identical
payload on `Stop` failed at 1:21 instead — there `decision` is valid and
`allow_tool` is not.

⚠️ **And a `PreToolUse` hook whose answer does not parse FAILS THE TOOL CALL.**
This is the one fail-closed path in the bundle and it is the engine's behaviour,
not ours: a malformed answer does not degrade to "allowed", it wedges the agent.

**So the first cut's hedge was fatal.** It emitted both contested deny
spellings — `allow_tool`/`deny_reason` from the developer guide alongside
`decision`/`reason` from atuinsh/atuin#4117 — reasoning that an unrecognised
sibling key is inert (#3256). Here it is not. That hedge would have broken
**every tool call** rather than half of one, and it was named in this file as
the single highest-risk unknown. The pull request was right; the guide was
wrong.

| Event            | What the shim writes on a block      | What it writes otherwise                                |
| ---------------- | ------------------------------------ | ------------------------------------------------------- |
| `PreToolUse`     | `{"decision":"deny","reason":…}`     | `{"decision":"allow"}`, plus `reason` when a hook spoke |
| `PostToolUse`    | —                                    | `{}` always                                             |
| `PreInvocation`  | —                                    | `{"injectSteps":[{"ephemeralMessage":…}]}` or `{}`      |
| `PostInvocation` | —                                    | same as `PreInvocation`                                 |
| `Stop`           | `{"decision":"continue","reason":…}` | `{}`                                                    |

**This is why the event name is the shim's first argument.** It cannot be
inferred from the payload, and a handler invoked under the wrong event answers
in a shape that event rejects. `tests.sh` checks every command in the manifest
passes the event it is registered under.

## ⚠️ The cwd Antigravity never sends

No payload carries a `cwd`, and `workspacePaths` came back `[]` on **every**
captured payload — tool events and invocation events alike. Since all twelve
shared scripts gate on the cwd being inside a repo holding `.jus/`, a shim that
derives nothing disarms all of them, silently, while looking installed.

**`$PWD` is not a fallback either.** Antigravity runs a hook in the directory
containing its `hooks.json`, measured `/home/caleon/.gemini/config` — which for
the global install this README now prescribes is never a Juscribe project.

So the shim derives one, in this order:

| Source                                       | When                                                        |
| -------------------------------------------- | ----------------------------------------------------------- |
| `.toolCall.args.Cwd`                         | `run_command` — the only tool that carries it               |
| directory of `.toolCall.args.TargetFile`     | the file tools, whose `Cwd` is **null**                     |
| `.workspacePaths[0]` / `.cwd`                | if a future version populates either                        |
| the cwd remembered for this `conversationId` | `PreInvocation`, `PostInvocation`, `Stop`, which carry none |

⚠️ **The derived directory need not exist yet.** `TargetFile` is where a file is
_about_ to be written, so creating `src/new/thing.ts` yields a `src/new` that
`git -C` cannot enter — which reads as "not a repository" and allows the very
edit the guard exists to catch. The shim climbs to the nearest existing
ancestor.

The remembered cwd lives in `${JUS_ANTIGRAVITY_STATE:-$TMPDIR/jus/antigravity}`,
keyed by conversation, written by the tool events.

⚠️ **The cwd chain here also had the empty-string defect**, where an empty
`workspacePaths` entry beat the remembered directory this shim exists to keep.
Fixed on #4428; the class and the seven-shim audit are in
[`../README.md`](../README.md).

## Payload mapping

| Antigravity                         | shared scripts                        |
| ----------------------------------- | ------------------------------------- |
| `.toolCall.args.CommandLine`        | `tool_input.command` (tool `Bash`)    |
| `.toolCall.args.TargetFile`         | `tool_input.file_path`                |
| `.toolCall.args.CodeContent`        | `tool_input.content` (tool `Write`)   |
| `.toolCall.args.TargetContent`      | `tool_input.old_string` (tool `Edit`) |
| `.toolCall.args.ReplacementContent` | `tool_input.new_string`               |
| `.conversationId`                   | `session_id`                          |
| `.transcriptPath`                   | `transcript_path`                     |

⚠️ **The tool names are Antigravity's own and match nothing we ship** —
`run_command`, `write_to_file`, `replace_file_content`, `view_file`. The first
cut inferred the tool from Claude's _argument_ names (`old_string`, `content`,
`edits`), none of which appears anywhere in an Antigravity payload, so every
edit reached the guards unrecognised and passed.

⚠️ **The command is nested two levels deeper than anywhere else**, and the cwd
arrives as its sibling rather than at the top level.

## Event mapping — twelve, not thirteen

| Shared hook                           | Claude event       | Antigravity event                 |
| ------------------------------------- | ------------------ | --------------------------------- |
| `jus-block-force-push.sh`             | `PreToolUse`       | `PreToolUse`                      |
| `jus-block-no-verify.sh`              | `PreToolUse`       | `PreToolUse`                      |
| `jus-pre-commit-gate.sh`              | `PreToolUse`       | `PreToolUse`                      |
| `jus-block-accepted-manifest-edit.sh` | `PreToolUse`       | `PreToolUse`                      |
| `jus-blocker-date-nudge.sh`           | `PreToolUse`       | `PreToolUse`                      |
| `jus-block-lint-suppression.sh`       | `PreToolUse`       | `PreToolUse`                      |
| `jus-track-edits.sh`                  | `PostToolUse`      | `PostToolUse`                     |
| `jus-post-bash-tracker.sh`            | `PostToolUse`      | `PostToolUse`                     |
| `jus-start-comment-nudge.sh`          | `PostToolUse`      | `PostToolUse` — **text deferred** |
| `jus-docs-nudge.sh`                   | `PostToolUse` ×2   | `PostToolUse` ×1                  |
| `jus-stop-uncommitted.sh`             | `Stop`             | `Stop` — **blocks, see below**    |
| `jus-ticket-claim-nudge.sh`           | `UserPromptSubmit` | `PreInvocation`                   |

✅ **`Stop` really blocks here, and this file said the opposite.** The first cut
called the dirty-tree gate advisory, "exactly as it does on Cursor (#4261) and
Kimi". It is not: `{"decision": "continue", "reason": …}` refuses the stop and
re-enters the loop with the reason injected as a system message. **Antigravity
is the first non-Claude tool where that hook keeps its teeth.**

⚠️ **A `PostToolUse` hook has no channel to the model at all.** Its contract is
an empty object — there is no field a message could ride. That is the same
enforcement-becomes-nothing loss Kimi has on its post-tool event, and the remedy
is the same one Kimi's adapter uses: the shim buffers the text and the next
`PreInvocation` injects it as an `ephemeralMessage`. Without that, two of the
twelve would be inert.

⚠️ **`jus-docs-nudge.sh` is registered once**, like Copilot and unlike Cursor:
Antigravity has one post-tool event, so a second registration would double-fire
rather than cover a second surface.

## ⚠️ The sandbox is NOT on by default in the CLI

This file used to say Antigravity "sandboxes by default — `sandbox-exec` on
macOS, `nsjail` on Linux", and used that to argue about which of our hooks the
sandbox makes redundant. **Neither string appears in the binary** (`bwrap` does,
three times), and the CLI exposes sandboxing as an opt-in `--sandbox` flag
— _"Run in a sandbox with terminal restrictions enabled"_ — backed by an
`enableTerminalSandbox` user setting and a per-command `BypassSandbox`
argument.

Measured: with no `--sandbox` flag, a tool call rewrote a git repository
**outside** the workspace directory. A default-on sandbox mounting `write_file`
paths read-write and everything else read-only does not permit that.

The redundancy question survives the correction, and the answer is unchanged:
**none of the twelve is redundant**, because the two constraints are orthogonal.
A sandbox constrains **where** a write may land; every one of these constrains
**what is done**, wherever it lands. `block-force-push` and `block-no-verify`
are git operations against a remote, not filesystem writes.
`block-lint-suppression` cares about the _content_ of an edit to a file a
sandbox would already permit. `block-accepted-manifest-edit` cares about _which_
board artefact is changing. `pre-commit-gate`, `stop-uncommitted` and the nudges
are session and workflow state. A sandbox stops an agent escaping the project;
these stop it working badly inside one.

## Skills

Antigravity reads project `.agents/skills/` plus `GEMINI.md` and `AGENTS.md` as
context, so the canonical install works unchanged. ⚠️ **Its IDE ignores symlinks
for global skills** (issue #633) — use copies there: `cp -r ~/.jus-skills/skills/*
.agents/skills/`.

⚠️ **`.agents/` still matters for skills even though hooks moved to the global
path.** They are different discovery mechanisms; only the hooks one failed.

## Live verification

Run in the orb against `agy 1.2.5` (#4262), with the control arm
`.jus/docs/vendor-capability-claims.md` requires:

| Run                      | Prompt                                         | Outcome                                                 | Remote tip            |
| ------------------------ | ---------------------------------------------- | ------------------------------------------------------- | --------------------- |
| Hooks installed          | overwrite the remote branch with the local one | **blocked**, the hook's reason quoted back by the model | `02ff583` — unmoved   |
| `hooks.json` moved aside | identical prompt, identical model              | pushed                                                  | `ac16c01` — **moved** |

The control arm is the half that matters: without it, "it refused" cannot be
told apart from the model declining on its own. The engine log recorded **zero**
`Failed to parse hooks` and **zero** `unmarshal result` errors across the run,
which is what says the manifest and all five response shapes are accepted.

## Tests

`jus/hooks/tests.sh`, in the `antigravity adapter` section — 24 of them.

⚠️ **The load-bearing assertions are the negative ones.** Every answer is
checked for the _absence_ of the keys its event rejects, because that is the
defect that ships green everywhere else: a hedge that looks like belt and braces
and is actually a parse error on every tool call.
