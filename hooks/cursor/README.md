# jus enforcement hooks — Cursor adapter

Runs all thirteen shared hook scripts (`../scripts/`) under Cursor's native
hooks system (#4261).

> ## ✅ LIVE-VERIFIED against cursor-agent 2026.09.15-d2fe57e, 2026-09-17
>
> A model-issued `git push --force origin main` was **blocked by
> `beforeShellExecution`** — the agent quoted this bundle's own refusal text back
> — and the remote tip did not move. The control arm, same repository and the
> same prompt with the manifest removed, force-pushed and moved the tip
> `a4f9dbb → c7835b5`.
>
> ⚠️ **The first control arm proved nothing, and that is worth knowing before
> you repeat this.** Asked plainly, the model declined on its own —
> indistinguishable from a hook refusing. Both arms were re-run with one prompt
> that explicitly confirms the intent, and only then did the two diverge.
>
> ⚠️ **Two of the thirteen hooks do not run in a headless `cursor-agent -p`
> session at all** — see degradation 4. This box is about the command blockers,
> which run everywhere.
>
> Method, event-by-event firing table and the payload shapes: _Live-verified_ below.

> ⚠️ **These hooks do nothing outside a Juscribe project** (#4404). Each runs
> only when the payload's `cwd` is inside a git repository whose toplevel holds
> a `.jus/` directory; everywhere else they exit 0 in silence. That is the
> shared scripts' behaviour, so it applies here however this adapter is
> installed — including a user-scope install that every project on the machine
> sees. `JUS_HOOKS_EVERYWHERE=1` restores the old machine-wide behaviour.

## Setup

One shared clone per machine, then either scope:

```sh
git clone https://github.com/juscribe/jus-skills.git ~/.jus-skills
```

**Per project:**

```sh
mkdir -p .cursor && cp ~/.jus-skills/hooks/cursor/hooks.json .cursor/hooks.json
```

**Per machine:**

```sh
cp ~/.jus-skills/hooks/cursor/hooks.json ~/.cursor/hooks.json
```

⚠️ **Do not install at both scopes.** Cursor merges what it finds, so every hook
registers twice and fires twice per event — the same trap
`installing-the-bundle.md` documents for Claude Code, with the same symptom:
nothing fails, a counter just doubles.

✅ **The `~` in every `command` DOES expand, and here is why.** Cursor documents
project hook commands as running from the project root with relative paths like
`.cursor/hooks/script.sh`; this manifest uses `~/.jus-skills/...` because the
bundle lives outside the project and there is no relative path from `.cursor/` to
a home directory. Cursor does not spawn the command directly — it builds

```text
<command> <<'CURSOR_HOOK_EOF'
<payload JSON>
CURSOR_HOOK_EOF
```

and hands that whole string to a shell, which a heredoc is meaningful to and
nothing else. **The shell is what expands the tilde**, so Cursor never has to.

⚠️ **Which means the expansion is positional: a shell expands `~` only at the
START of a word.** `"~/.jus-skills/..."`, `--flag=~/...` or a tilde anywhere but
the first character is a literal, the command is not found, the exit is 127, and
Cursor treats a non-2 exit as fail-**open** — so every hook silently does
nothing and the session looks healthy. `tests.sh` has a guard for exactly this;
it was written by mutating a quoted path into the manifest and watching all
three transport tests go to 127.

## Trust and approval

✅ **A headless `cursor-agent -p` run needs no trust step and no `--trust`.**
Measured 2026-09-17 in a git repository cursor-agent had never opened: the run
proceeded, and a hook registered in `.cursor/hooks.json` fired on the first shell
command. `--trust` exists and is harmless; this adapter does not depend on it.

⚠️ **A hooks config whose path passes through a symlink loads NOTHING, and
says nothing.** Same directory, same manifest, `.cursor/hooks.json` replaced by a
symlink to an identical file: hooks fired **1** time before and **0** after. So
do not symlink it at a shared clone — copy it, as _Setup_ says.

⚠️ **Approval does not outrank a hook, which is the point.** `--force` (and
its alias `--yolo`) auto-approve every tool call, and the force-push guard denied
under it anyway. That is what makes the verification below a test of the hook
rather than of the approval prompt.

Cursor names its own settings screen in the text the agent sees when a hook
denies something — _"To view or modify configured hooks, go to Cursor Settings >
Hooks"_ — so a user who meets one of these guards is pointed at where to look.

## Why this one is nearly a passthrough

Cursor's `preToolUse` and `postToolUse` payloads already carry `tool_name` and
`tool_input` under exactly the names the shared scripts read, and **exit 2
blocks** — documented as "equivalent to `permission: deny`". So neither the
input nor the output needs translating on those two events.

⚠️ **And its failure default already matches ours.** Cursor treats any non-zero
exit other than 2 as fail-**open** unless the hook sets `failClosed: true`. That
is this bundle's own doctrine, so the Cursor shim needs none of the exit-code
collapse the Copilot one does — see `hooks/copilot/README.md` for what that
asymmetry costs there. **Do not add `failClosed: true` to this manifest**: it
turns a broken `jq` into a stopped agent.

What does need a shim is that Cursor splits shells, edits and prompts into their
**own events**, none of which carries `tool_name`:

| Cursor event                 | carries                         | normalized to              |
| ---------------------------- | ------------------------------- | -------------------------- |
| `beforeShellExecution`       | `command`, `cwd`, `sandbox`     | `tool_name: "Bash"`        |
| `afterShellExecution`        | `command`, `output`, `duration` | `Bash` + `tool_response`   |
| `afterFileEdit`              | `file_path`, `edits[]`          | `tool_name: "MultiEdit"`   |
| `beforeSubmitPrompt`         | `prompt`, `attachments`         | `prompt`, unchanged        |
| `stop`                       | `status`, `loop_count`          | `cwd` + `stop_hook_active` |
| `preToolUse` / `postToolUse` | `tool_name`, `tool_input`       | passthrough                |

✅ **The shell events are why this adapter is the sturdiest of the five.**
`beforeShellExecution` hands over `command` directly, so the five command
blockers never have to guess what Cursor calls its shell tool — the failure mode
that forces shape-inference on Copilot (#4260) does not arise here.

## The four degradations

**1. ⚠️ `stop` CANNOT BLOCK, so the dirty-tree gate becomes advice.**

Cursor lists `stop` among the hooks that cannot refuse an action.
`jus-stop-uncommitted.sh` is a hard gate on Claude Code, Codex and Kimi's plugin
path: it exits 2 and the session cannot end with uncommitted work. On Cursor the
message is printed and the session ends anyway.

This is the Kimi shape exactly — enforcement degrading to a reminder — and it is
the single thing that stops this being full parity. It is also the most
consequential of the thirteen to lose, because it is the one that catches work
about to be abandoned rather than work about to be done wrong.

**2. There is no before-file-edit event.**

`afterFileEdit` fires once the write has happened, so it cannot refuse one.
`jus-block-lint-suppression.sh` therefore rides `preToolUse`, which is the only
pre-hook that can see an edit. Cursor **does** send a real `tool_name` there — a
shell call arrives as `Shell` and a whole-file write as `Write`, both measured on
2026.09.15-d2fe57e — but it is Cursor's vocabulary rather than Claude's and it is
undocumented, so the shim infers from the argument shape instead:

| `tool_input` carries          | mapped to   |
| ----------------------------- | ----------- |
| `.edits`                      | `MultiEdit` |
| `.old_string` / `.new_string` | `Edit`      |
| `.content`                    | `Write`     |
| `.command`                    | `Bash`      |

⚠️ **The inference is confined to `preToolUse`.** Every other event above already
knows what it is, and guessing where you do not have to is how a shim acquires a
second failure mode.

**3. `stop` carries neither `cwd` nor `stop_hook_active`.**

The workspace comes from the common `workspace_roots` array, and the loop guard
from `loop_count`, which Cursor increments each time the stop hook has already
run this turn. The shim maps `workspace_roots[0]` → `cwd` and `loop_count > 0` →
`stop_hook_active`.

⚠️ **Get either wrong and the failure is silent in opposite directions:** a
missing `cwd` means the hook never finds a repository and never fires; a missing
loop guard means it fires forever.

**4. ⚠️ A HEADLESS `cursor-agent -p` RUN FIRES NEITHER `stop` NOR
`beforeSubmitPrompt`.**

Measured 2026-09-17 by registering a probe on all nineteen events Cursor defines
and running the same task twice. In `-p` (print / non-interactive) mode the run
fires `sessionStart`, the tool events and `sessionEnd`, and neither
`beforeSubmitPrompt` nor `stop`. Driven through a pty in the interactive TUI the
same build fires both, as documented.

So on a headless run `jus-stop-uncommitted.sh` and `jus-ticket-claim-nudge.sh`
are **dead**, while the board of configured hooks looks full. The shim maps both
events correctly — checked against captured payloads — and they are simply never
delivered.

⚠️ **This is not degradation 1 and it has a different fix, namely none.**
There, `stop` fires and cannot refuse, so the message at least prints. Here it
does not fire, so nothing prints either. `sessionEnd` is the only event at the
end of a headless turn; it is not registered, because it cannot block and would
turn one silent gap into two places to look.

## `beforeMCPExecution` is NOT registered, and that is a decision

Cursor has two events Claude Code does not — `beforeShellExecution` and
`beforeMCPExecution` — and the second is a genuine gap in what this bundle
protects. An MCP tool can reach the same outcomes as a shell command, unwatched.

**It is still not registered, because our guards have nothing to match.**
`jus-block-force-push.sh` and `jus-block-no-verify.sh` are command-**text**
matchers: they read `tool_input.command` and look for `--force` or `--no-verify`.
A `beforeMCPExecution` payload carries `mcp_server_name`, a server URL or command,
and an arbitrary `tool_input` object — there is no command string in it.
Registering them there would add hook invocations that can never fire, which
reads as coverage on an audit and is not.

**What covering it would actually take** is a different guard that matches on MCP
_tool names_ — and there is no portable answer to what a force-push-equivalent
MCP tool is called on someone else's setup. That is its own ticket. The gap is
named here so the next person meets it as a decision rather than an oversight.

## Event mapping

| Shared hook                           | Claude event       | Cursor event                                  |
| ------------------------------------- | ------------------ | --------------------------------------------- |
| `jus-block-force-push.sh`             | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-block-no-verify.sh`              | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-pre-commit-gate.sh`              | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-block-accepted-manifest-edit.sh` | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-blocker-date-nudge.sh`           | `PreToolUse`       | `beforeShellExecution`                        |
| `jus-block-lint-suppression.sh`       | `PreToolUse`       | `preToolUse`                                  |
| `jus-post-bash-tracker.sh`            | `PostToolUse`      | `afterShellExecution`                         |
| `jus-track-edits.sh`                  | `PostToolUse`      | `afterFileEdit`                               |
| `jus-start-comment-nudge.sh`          | `PostToolUse`      | `afterFileEdit`                               |
| `jus-docs-nudge.sh`                   | `PostToolUse` ×2   | `afterShellExecution` **and** `afterFileEdit` |
| `jus-stop-uncommitted.sh`             | `Stop`             | `stop` — **advisory, never under `-p`**       |
| `jus-ticket-claim-nudge.sh`           | `UserPromptSubmit` | `beforeSubmitPrompt` — **never under `-p`**   |

✅ **`jus-docs-nudge.sh` is registered twice here and that is correct**, unlike on
Copilot. Claude registers it under two matchers of one event; Cursor has two
distinct events, so two registrations fire on different things rather than
double-firing on the same one.

## Skills, and not loading them twice

Cursor reads `.agents/skills/`, `.cursor/skills/`, `~/.agents/skills/` and
`~/.cursor/skills/`, and for compatibility also `.claude/skills/` and
`.codex/skills/`. The canonical install writes `.agents/skills/` only, so one
install is one copy.

⚠️ **The risk is a project that already has another tool's directory.** A repo
carrying both `.agents/skills/jus-*` and `.claude/skills/jus-*` — say because
someone set it up for Claude Code first — gives Cursor the same skills twice,
listed twice, with nothing saying which is which. Symlinking both at the same
shared clone does not help: Cursor discovers by path, not by inode.

## ⚠️ AND IT LOADS CLAUDE CODE'S **HOOKS** TOO, WHICH IS THE BIGGER ONE

The compatibility reading is not limited to skills. `cursor-agent` loads hook
configuration from **seven** places, and three of them are Claude Code's:

| Source               | Path                                           |
| -------------------- | ---------------------------------------------- |
| enterprise           | `/etc/cursor/hooks.json` (Linux)               |
| team                 | `.cursor/managed/active-team-hooks/hooks.json` |
| user                 | `~/.cursor/hooks.json`                         |
| project              | `.cursor/hooks.json`                           |
| claude-user          | `~/.claude/settings.json`                      |
| claude-project       | `.claude/settings.json`                        |
| claude-project-local | `.claude/settings.local.json`                  |

It parses Claude Code's `hooks` block, converts the event names
(`PreToolUse`→`preToolUse`, `PostToolUse`→`postToolUse`,
`UserPromptSubmit`→`beforeSubmitPrompt`, `Stop`→`stop`, `SessionStart`,
`SessionEnd`, `PreCompact`, `SubagentStop`; `Notification` and
`PermissionRequest` are dropped) and the tool matchers (`Bash`→`Shell`,
`Edit`→`Write`, `Glob`→dropped), and runs them.

⚠️ **`CLAUDE_PROJECT_DIR` is set by Cursor itself**, to the workspace path. So a
`.claude/settings.json` registering `${CLAUDE_PROJECT_DIR}/jus/hooks/scripts/...`
— which is how this bundle installs on Claude Code — **resolves and runs**. It
does not quietly fail to find anything.

⚠️ **Cursor's de-duplication does not reach this.** It drops a Claude-sourced
hook only when the command string is byte-identical to a Cursor-sourced one. Our
Cursor commands go through the shim (`jus-cursor-adapt.sh <script>`) and our
Claude ones do not, so the strings differ and both survive. **In a repo set up
for Claude Code, installing this manifest as well registers every jus hook
twice.**

✅ **What that costs is spawns, not behaviour — measured, not reasoned.** All
thirteen shared scripts were fed the payloads a Claude-format registration
actually delivers under Cursor (`preToolUse` / `postToolUse` / `stop`, Cursor's
field names, Cursor's `Shell` tool name after the `Bash`→`Shell` matcher
conversion). **Every one exited 0, printed nothing and wrote nothing** —
including `jus-track-edits.sh`, which was the one that could have double-written
state. They are inert because they gate on `tool_name == "Bash"` and on a `cwd`
that Cursor's `stop` payload does not carry.

⚠️ **Inert cuts the other way too: the Claude registration protects nothing on
Cursor.** No Claude event maps to `beforeShellExecution`, so a repo relying on
`.claude/settings.json` alone has **no command blockers under Cursor at all** —
it just looks like it does, because the hooks are configured and running.

**So: install this manifest either way.** The duplicate registration is thirteen
no-op spawns per event, and it is the only thing that gives Cursor the five
command blockers. If you want the spawns gone, the Claude hooks would have to
leave `.claude/settings.json` — and `.claude/settings.local.json` is read by
Cursor too, so there is no Claude-only location to move them to.

## Live-verified

**cursor-agent 2026.09.15-d2fe57e, macOS, 2026-09-17 (#4261).** The fixture is a
throwaway git repository with a **local bare remote** beside it, a `.jus/`
directory at its toplevel, and `.cursor/hooks.json` copied from this manifest
with `~/.jus-skills/hooks` rewritten to a staged copy of the bundle. Local and
remote were deliberately diverged, so a plain push is refused and only a force
can land.

| Arm     | Manifest  | Outcome                                              | Remote tip                |
| ------- | --------- | ---------------------------------------------------- | ------------------------- |
| hook    | installed | blocked; the agent quoted this bundle's refusal text | unmoved                   |
| control | removed   | force-pushed                                         | moved `a4f9dbb → c7835b5` |

⚠️ **Run the control arm, and expect to run it twice.** Asked plainly to run
`git push --force origin main`, the model refused on its own and the tip did
not move — a result identical to a working hook. The prompt that separates them
states the repository is disposable and confirms the intent to overwrite; under
it, the control arm pushes and the hook arm still blocks. A single arm proves
nothing here.

### Which events actually fire

A probe registered on **all nineteen** events Cursor defines
(`index.js`'s own event map), run against the same task:

| Event                                          | headless `-p`                         | interactive TUI     |
| ---------------------------------------------- | ------------------------------------- | ------------------- |
| `sessionStart` / `sessionEnd`                  | fires                                 | fires               |
| `preToolUse` / `postToolUse`                   | fires                                 | fires               |
| `beforeShellExecution` / `afterShellExecution` | fires                                 | fires               |
| `beforeReadFile`                               | fires                                 | fires               |
| `afterFileEdit`                                | fires — **only for a real edit tool** | fires               |
| `afterAgentThought` / `afterAgentResponse`     | fires                                 | fires               |
| `beforeSubmitPrompt`                           | **never**                             | fires               |
| `stop`                                         | **never**                             | fires, cannot block |

✅ **`afterFileEdit` does fire**, against an early reading of the same data that
said it did not. The model had been editing files with a shell redirect, so the
write arrived as `beforeShellExecution` and no edit event existed to fire.
Prompted to use its edit tool instead, the event fires with
`{file_path, edits: [{old_string, new_string}]}` — exactly what the shim maps to
`MultiEdit`. **If you re-measure this, say which tool made the edit**; the two
are indistinguishable in the firing table alone.

### ⚠️ `cwd` is the empty string, and it defeated `//`

`beforeShellExecution`, `preToolUse` and `postToolUse` all arrive carrying
`"cwd": ""`. jq's `//` falls back on `null` and `false` only, so the shim's
`.cwd // .workspace_roots[0]` kept the empty string, and
`juscribe_sop_require_jus_project` then exits 0 — **every guard silently
allowing what it exists to block.**

It never showed up live, because Cursor spawns hooks with the workspace root as
their working directory even when the CLI was launched elsewhere with
`--workspace`, and the shared scripts fall back to `$PWD`. That fallback was
carrying the adapter. The shim now treats an empty `cwd` as absent, and
`tests.sh` asserts it from a process standing **outside** a Juscribe project with
`JUS_HOOKS_EVERYWHERE` unset — both conditions are needed, or the test passes
over the bug.

### Repeating it

1. `cursor-agent login`, then check with `cursor-agent --list-models`. ⚠️ **Not
   `cursor-agent status`**, which reported `✓ Login successful!` on a machine with
   no credential on disk at all; the only tell was a parenthesised
   `(unable to fetch user details)`.
2. Build the fixture above, outside any real repository.
3. `cursor-agent -p --force --trust` from the fixture. `--force` is what makes
   the test meaningful: the hook denial has to beat auto-approval.
4. Note the remote tip before and after, on both arms.

## Tests

`jus/hooks/tests.sh`, in the `cursor adapter` section: the manifest is valid JSON
in Cursor's shape, every script it names exists, all thirteen are registered, and
the shim normalises each of the six event shapes — including that `stop` derives
its `cwd` from `workspace_roots` and its loop guard from `loop_count`.

Three of them use **Cursor's own transport** rather than piping into the shim:
they stage the bundle under a temporary `HOME`, build the heredoc command line
Cursor builds, run it through `/bin/sh`, and assert the force-push guard exits 2
and an ordinary push exits 0. That is what makes the tilde claim above a test
rather than a reading.
