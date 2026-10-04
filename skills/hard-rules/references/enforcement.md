# Enforcement — which rules the hooks back, and what they cannot do

Read when you need to know whether a rule is enforced mechanically where you are running, or why a hook did or did not fire. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Two-Layer Enforcement: Skill + Hooks

Some of these rules are also enforced **deterministically** by the jus enforcement hooks (under `hooks/`) — **when your harness runs them**. Claude Code runs them natively; eight other tools run the same scripts through an adapter — `hooks/antigravity/`, `hooks/codex/`, `hooks/copilot/`, `hooks/cursor/`, `hooks/gemini/`, `hooks/kimi-code/`, `hooks/qwen/`, `hooks/windsurf/` (Kimi also installs as a plugin, via the bundle's `kimi.plugin.json`). **Shipping an adapter is not the same as it being installed, and being installed is not the same as it blocking** — the bundle README's cross-tool support matrix grades every row, and the section below carries the degradations. **Where no adapter is installed — and on a tool with no hook surface at all, which today is Zed — every rule in `SKILL.md` is prompt-level only: nothing blocks you mechanically, which makes following this skill MORE important, not less.** Where they do run, the hooks are a backstop — they fire even if a model "forgot" the rule — but the skill remains the source of truth and the only layer that explains the _why_.

| Rule | Skill (prompt) | Hook (where hooks run) |
| --- | :-: | --- |
| Every piece of work has a ticket | ✅ | — |
| Description and effort estimate required | ✅ | — |
| Transitions at the natural moment | ✅ | `UserPromptSubmit` — nudge only: a prompt naming a ticket gets the ticket and the command that starts it |
| Never transition to `accepted` / `rejected` | ✅ | — |
| **Commit immediately after code changes** | ✅ | `Stop` blocks if working tree is dirty — on a turn that ends normally. An interrupted or errored turn skips it, and the next turn to end normally is blocked instead |
| Never move on with a dirty working tree | ✅ | — (the `Stop` row above is the end-of-turn backstop) |
| One commit per ticket, carrying a ticket reference | ✅ | — |
| Never amend a delivered commit | ✅ | — |
| **Never `git push --force` (any variant)** | ✅ | `PreToolUse Bash` — blocks the command |
| Never `git push` (stakeholder pushes manually) | ✅ | — |
| **Never use `--no-verify`** | ✅ | `PreToolUse Bash` — blocks the command, and the same skip through `-n`, `HUSKY=0`, `LEFTHOOK=0`, `LEFTHOOK_EXCLUDE`, `SKIP` or `PRE_COMMIT_ALLOW_NO_CONFIG` |
| **Never suppress linters inline** (any `disable` / `ignore` / `expect-error` directive) | ✅ | `PreToolUse Edit/Write` — blocks the edit. `PreToolUse Bash(git commit)` — blocks a commit that adds one, whatever wrote it |
| Fix all lint warnings in modified files | ✅ | — |
| **Lint changed files BEFORE committing** | ✅ | `PreToolUse Bash(git commit)` — blocks if no lint ran since last code edit |
| Run the tests covering the changed files before committing | ✅ | Prompt-only. The commit hook runs linters and whatever tests the project wired into it — **it does not run a full suite**. Do not read a passing commit as a passing test run. |
| Diff coverage meets the project's bar (100% by default) | ✅ | — |
| Follow existing standards and conventions | ✅ | `PostToolUse` — nudge only: names the project's own doc for an area at ticket pickup and on the first edit under a mapped path |
| Reuse existing styles, components, patterns | ✅ | — |
| **Never overwrite stakeholder description text (agent text stays current)** | ✅ | — |
| **Never edit the description of an accepted or cancelled ticket** — correct it with a comment | — | `PreToolUse Bash` — blocks the edit |
| Never deliver work that defers/skips/deviates | ✅ | — |
| Re-read ticket before finishing | ✅ | — |
| Every delivery comment includes verification steps + git | ✅ | — |
| Add an External dependency when waiting on user input | ✅ | — |
| A blocker whose condition is a time carries `due_on` and `due_kind` | ✅ | `PreToolUse Bash` — nudge only, when the text names a time and the date columns are empty |
| A SEQUENCE of steps is subtasks, never description checkboxes (one step needs none); mixed-actor tickets assign both | ✅ | — |
| Tick every checkbox and subtask before delivering — and never tick an unmet one | ✅ | — |
| Never inline prose into a shell command; never hand over a wrapping command | ✅ | — |
| Check the ticket's own claims and state what the approach assumes | ✅ | — |
| Post the start comment before the first source edit | ✅ | `PostToolUse Edit/Write` — nudge only |
| New tickets to the bottom of the backlog unless urgent or deliberately placed | ✅ | — |
| Blocked on a third party: split at the boundary, deliver your half | ✅ | — |
| Document discoveries immediately | ✅ | — |

### What hooks can and can't do

- **An adapter shipping says nothing about how well we know it works, or about whether it can refuse.** Three things the ✅ column above cannot show, each read off the adapter's own README:
  - **How well we know it works.** Live-verified against a real install, with a control arm: Codex, Cursor, Copilot, the Antigravity CLI. Read out of the vendor's shipped source but never run by us: Gemini CLI, Qwen Code. Unverified, and not verifiable headlessly: Windsurf, whose Cascade hooks are IDE-only. The Antigravity desktop IDE rides the CLI's adapter on the CLI's evidence.
  - **Whether the dirty-tree gate can actually refuse.** A real gate on Claude Code, Codex, Kimi Code's plugin, Antigravity and Qwen. It degrades to a message on Cursor, whose `stop` cannot block and does not run headless at all, and on Copilot, whose `agentStop` printed and let the session end under `-p`. Gemini CLI has no stop event and its `AfterAgent` **retries** on a deny rather than blocking; Windsurf's Cascade has no stop event at all, so the hook has nowhere to live there.
  - **Whether a nudge reaches the model.** Kimi Code and Copilot both have observe-only PostToolUse: the trackers still write their state, but a hook that exists to _tell the model something_ needs a channel. Kimi's rides a prompt-time reminder; Copilot has nothing to reroute through. Codex blocks fully and gates each hook behind a per-hook trust flow — approve with `/hooks`.
- **Tools with no hook surface at all get the skill layer only.** Today that is Zed, the one row of the matrix where none was found. Reconcile against the matrix and the adapter READMEs, which carry the dates and the grades — not against this list.
- ⚠️ **In a git worktree, the hooks see a `.jus/` directory only if one is tracked.** They act only where a `.jus/` sits between the working directory and the repository root, and `jus init` keeps `.jus/config/` and `.jus/tmp/` out of git. So in a project with no tracked file under `.jus/`, a worktree has none, and every hook is silently off there. `git ls-files .jus` prints nothing in that case. Commit a file under `.jus/` to fix it.
- ⚠️ **In Claude Code, a `PostToolUse` hook does not run after a call that exits non-zero.** A lint that failed is rightly not recorded, but neither is anything else in that call: a lint chained before a command that fails, or a transition piped into a filter that exits non-zero. Run the checks a hook must see in a call of their own, and make a call whose success matters exit 0.
- Hooks fail open: if `jq` or another required tool is missing on the host, the hook exits 0 rather than wedging the tool call. The skill remains the primary teaching mechanism.
- ⚠️ **A hook's output goes to one of two places, and only one of them is the model.** `systemMessage` is rendered in the terminal for the *user*; `hookSpecificOutput.additionalContext` is what the model receives. They are separate fields, and emitting only the first means the agent never sees the message — it looks like a working hook from every angle except the one that matters. `jus-docs-nudge.sh` and `jus-start-comment-nudge.sh` emit **both**. ⚠️ **A hook emitting only `systemMessage` is not a backstop for anything.** One that had read as a commit guard for months was removed, because it and was only ever talking to the terminal — it looked correct in the manifest, in the rule table, and in its own tests.
- ⚠️ **Not every event can carry `additionalContext`** — some accept the field and discard it. Check before designing a hook around one.
- Hooks block deterministically (exit 2) but a determined model can disable them through its harness configuration (in Claude Code: `disableAllHooks` or a settings edit). The hooks are a guardrail, not a sandbox.

See `hooks/` and the bundle README for installation and the per-harness coverage.
