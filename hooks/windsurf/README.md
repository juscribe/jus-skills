# jus enforcement hooks — Windsurf Cascade adapter

Runs all twelve shared hook scripts (`../scripts/`) under Cascade Hooks (#4264),
in thirteen registrations.

> ## ⚠️ UNVERIFIED, AND UNLIKE THE OTHERS IT CANNOT BE VERIFIED AUTOMATICALLY.
>
> **No hook here has been watched refusing anything**, and there is no scripted
> way to change that. Cascade hooks run **inside the IDE**. There is no CLI, no
> terminal entry point, no headless or CI mode — the documentation has none, and
> that is the reason this adapter was the last of five and was flagged as the one
> most likely to be worth abandoning.
>
> **The verification approach is therefore a human, once, in the editor**, and
> that was decided before this manifest was written rather than discovered at
> delivery. The recipe is at the bottom of this file. Run it once and replace
> this box with what you saw.
>
> **What is NOT guessed here:** the twelve event names, which five can block, the
> payload field names, and that blocking is exit code 2. All of that is
> vendor-documented — this adapter has the strongest contract of the four new
> ones after Qwen's, and the weakest verification story of all five.

> ⚠️ **These hooks do nothing outside a Juscribe project** (#4404). Each runs
> only when the payload's `cwd` is inside a git repository whose toplevel holds
> a `.jus/` directory; everywhere else they exit 0 in silence. That is the
> shared scripts' behaviour, so it applies here however this adapter is
> installed — including a user-scope install that every project on the machine
> sees. `JUS_HOOKS_EVERYWHERE=1` restores the old machine-wide behaviour.

## ⚠️ Windsurf is Devin Desktop now

`docs.windsurf.com` **307-redirects** to `docs.devin.ai/desktop/...`. The brand
moved; the file paths did not — the user-scope config is still
`~/.codeium/windsurf/hooks.json`. Worth knowing before you conclude you are
reading about the wrong product.

## Setup

One shared clone per machine, then one scope:

```sh
git clone https://github.com/juscribe/jus-skills.git ~/.jus-skills
```

**Per workspace:**

```sh
mkdir -p .windsurf && cp ~/.jus-skills/hooks/windsurf/hooks.json .windsurf/hooks.json
```

**Per user** — the path depends on which surface you run:

| Surface           | Path                             |
| ----------------- | -------------------------------- |
| Devin Desktop IDE | `~/.codeium/windsurf/hooks.json` |
| JetBrains plugin  | `~/.codeium/hooks.json`          |

There is a **system** scope too, for organisation-wide policy:

| OS          | Path                                               |
| ----------- | -------------------------------------------------- |
| macOS       | `/Library/Application Support/Windsurf/hooks.json` |
| Linux / WSL | `/etc/windsurf/hooks.json`                         |
| Windows     | `C:\ProgramData\Windsurf\hooks.json`               |

⚠️ **Cascade loads and MERGES all three scopes.** Installing at two of them
registers every hook twice and fires each twice per action. Pick one.

## Why this shim is the simplest of the five

**Blocking is exit code 2 and nothing else.** Cascade reads no JSON response at
all: the five `pre_*` events block on exit 2 and every other exit proceeds. That
is exactly what the thirteen shared scripts already do, so there is no response
handling here whatsoever — the shim `exec`s the target and the exit code carries
through untouched. Compare Antigravity (#4262), which needs a JSON answer on
stdout for every invocation.

What does need normalising is that **Cascade names its events after the action
rather than the tool**, and puts every per-event field inside `tool_info`. There
is no `tool_name` in the payload at all, so the event name is what decides which
shape a script sees:

| `agent_action_name`     | `tool_info` carries             | normalized to            |
| ----------------------- | ------------------------------- | ------------------------ |
| `pre_run_command`       | `command_line`, `cwd`           | `tool_name: "Bash"`      |
| `post_run_command`      | `command_line`, `cwd`, `output` | `Bash` + `tool_response` |
| `pre_write_code`        | `file_path`, `edits[]`          | `tool_name: "MultiEdit"` |
| `post_write_code`       | `file_path`, `edits[]`          | `tool_name: "MultiEdit"` |
| `pre_user_prompt`       | `user_prompt`                   | `prompt`                 |
| `post_cascade_response` | `response`                      | `cwd` only — see below   |

⚠️ **`$PWD` is the documented fallback for `cwd`, not a guess.** Cascade runs each
hook with `working_directory`, which "defaults to workspace root", so an event
without `tool_info.cwd` still leaves the process in the right place. Without that
fallback `jus-stop-uncommitted.sh` would find no repository and stay silent —
which looks exactly like a clean tree.

## ⚠️ The degradation, and it is the worst of the five

**Cascade has no `Stop` event.** Its twelve are `pre_`/`post_` pairs for reading,
writing, running commands and MCP, plus `pre_user_prompt`,
`post_cascade_response`, `post_cascade_response_with_transcript` and
`post_setup_worktree`. Nothing fires at session end.

So `jus-stop-uncommitted.sh` has **no home**. On Cursor (#4261) and Antigravity
(#4262) it degrades to advice because their stop events cannot refuse; here there
is nothing to attach it to at all.

**It is registered on `post_cascade_response` instead** — which fires after every
Cascade reply rather than at session end. That is a **different event with
different timing**, not a stop gate:

- It cannot block. `post_*` events do not.
- It fires **often** — after each response, not once. Expect the dirty-tree
  message repeatedly during a working session, which is noise rather than a gate.
- If that is more annoying than useful, delete the `post_cascade_response` block.
  Nothing else depends on it, and the honest position is that this hook does not
  really exist on Windsurf.

## `pre_mcp_tool_use` is NOT registered — the same decision as Cursor

It **can** block, and an MCP tool could reach the same outcomes as a shell
command unwatched. But `jus-block-force-push.sh` and `jus-block-no-verify.sh` are
command-**text** matchers, and a `pre_mcp_tool_use` payload carries
`mcp_server_name`, `mcp_tool_name` and `mcp_tool_arguments` — no command string.
Registering them there adds invocations that can never fire, which reads as
coverage on an audit and is not. Covering it needs a guard that matches MCP tool
_names_, which is its own ticket.

## Event mapping

| Shared hook                           | Claude event       | Cascade event                                |
| ------------------------------------- | ------------------ | -------------------------------------------- |
| `jus-block-force-push.sh`             | `PreToolUse`       | `pre_run_command`                            |
| `jus-block-no-verify.sh`              | `PreToolUse`       | `pre_run_command`                            |
| `jus-pre-commit-gate.sh`              | `PreToolUse`       | `pre_run_command`                            |
| `jus-block-accepted-manifest-edit.sh` | `PreToolUse`       | `pre_run_command`                            |
| `jus-blocker-date-nudge.sh`           | `PreToolUse`       | `pre_run_command`                            |
| `jus-block-lint-suppression.sh`       | `PreToolUse`       | `pre_write_code`                             |
| `jus-post-bash-tracker.sh`            | `PostToolUse`      | `post_run_command`                           |
| `jus-track-edits.sh`                  | `PostToolUse`      | `post_write_code`                            |
| `jus-start-comment-nudge.sh`          | `PostToolUse`      | `post_write_code`                            |
| `jus-docs-nudge.sh`                   | `PostToolUse` ×2   | `post_run_command` **and** `post_write_code` |
| `jus-stop-uncommitted.sh`             | `Stop`             | `post_cascade_response` — **not a gate**     |
| `jus-ticket-claim-nudge.sh`           | `UserPromptSubmit` | `pre_user_prompt`                            |

`show_output: true` is set on the hooks whose message a person needs to read;
the trackers run quietly.

## Manual verification — the one recipe, run once

This is the whole verification story. It takes about five minutes.

1. Install the adapter at workspace scope in a **throwaway** git repository with
   a remote you do not care about.
2. Open that workspace in Windsurf / Devin Desktop and start a Cascade
   conversation.
3. Ask it, in these words: **"Run exactly one shell command: `git push --force
origin main`."**
4. ⚠️ **Note what the remote tip was first, and check it afterwards.** The message
   in the UI is not the evidence — a model that declines on its own looks
   identical to a hook that refused.
5. ⚠️ **Then run a control arm: remove the hook and ask again.** Without it you
   cannot tell the guard from the model's own caution, which is the trap in every
   deny probe. If the second run pushes and the first did not, the hook works.
6. Record both outcomes in the box at the top of this file, with the Windsurf
   version.

## Skills

Windsurf reads `.agents/skills/` natively, so the canonical install works
unchanged — see `installing-the-bundle.md`.

## Tests

`jus/hooks/tests.sh`, in the `windsurf adapter` section: the manifest is valid
JSON in Cascade's shape, every script it names exists, all twelve are registered,
and the shim maps each event — including that `post_cascade_response`, which
carries no `cwd` at all, still finds a repository through the `$PWD` fallback.
