# jus enforcement hooks — the bundle, and the traps that span every adapter

> **Trap catalogue** — Read this before writing or changing a payload shim under
> `<tool>/scripts/`. Each adapter's own README carries its tool's behaviour; this
> file carries what is true of **all** of them, so a fix made once is not
> re-derived six times.
>
> The shared guards live in `scripts/`; `scripts/lib/state.sh` is sourced by all
> of them. Each `<tool>/` directory holds that tool's manifest, its shim and its
> README. `tests.sh` is the whole suite and takes no arguments.

## Did the hooks actually RUN?

**Nothing else here answers that.** Four silencers — a non-2 exit, a tool name the
guards do not match, a cwd outside a Juscribe project, and a manifest the tool never
loaded — each produce **no output at all**, so a fully installed, correctly configured
hook set can protect nothing and look completely healthy. On the Cursor adapter that state shipped
with tests, a README and a live verification all passing over it.

Every shared guard records one line per invocation, through the EXIT trap
`juscribe_sop_require_valid_json` installs — so an early `exit 0`, which is how every
silencer leaves, is visible instead of silent:

```text
script=jus-block-force-push.sh event=PreToolUse tool=Bash cwd=payload outcome=blocked
```

Read it back with `hooks/jus-liveness`, which separates the three states nothing else
can tell apart: **ran** (allowed or blocked — both are proof of life), **ran and could
not tell where it was** (`cwd=no-cwd`, the shape Cursor's empty `cwd` left), and **never ran**.

| Outcome              | Means                                                |
| -------------------- | ---------------------------------------------------- |
| `allowed`            | ran, looked, nothing to block                        |
| `blocked`            | ran and refused                                      |
| `no-jq` / `bad-json` | the fail-open paths                                  |
| `not-a-jus-project`  | ran, knew where it was, and it was not one           |
| `no-jus`             | ran, and the `jus` command it needs is not installed |

⚠️ **`cwd=` is a separate field from `outcome=`, and that is the point.** A guard can
lose its cwd _and still be rescued_ by the shared `$PWD` fallback — which is exactly
what hid Cursor's empty `cwd` for weeks. `cwd=no-cwd` on a line that otherwise reads healthy is that
bug announcing itself.

⚠️ **Written outside the project, under `$CLAUDE_PLUGIN_DATA` or `$TMPDIR`.** A record
under `.jus/` could not be written in the case it exists to report. The tool sets
`$CLAUDE_PLUGIN_DATA` for its hooks and nothing sets it in your shell, so
`jus-liveness` searches every root a record lands in: Claude Code's
`~/.claude/plugins/data/<plugin>/`, Copilot's `~/.copilot/plugin-data/<marketplace>/<plugin>/`,
and `$TMPDIR/jus/` for everything else. Set `CLAUDE_PLUGIN_DATA` to read one root only.

## Which nudges reach the model

A nudge exists to tell the **model** something, and the two output fields go to
different places: `systemMessage` is shown to the person in the terminal, and
`hookSpecificOutput.additionalContext` is what Claude Code hands the model. Every
nudge emits both. Whether an adapter's tool passes either on is the tool's
decision, and for a `PreToolUse` nudge — `jus-blocker-date-nudge.sh` — it stands
like this:

| Tool                                     | A `PreToolUse` nudge reaches the model           | Evidence                                                              |
| ---------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------- |
| Claude Code                              | yes, through `additionalContext`                 | PreToolUse output is fed back into the conversation                   |
| Codex                                    | yes, through `systemMessage`                     | measured on 0.154.0                                                   |
| Gemini CLI                               | yes, through `additionalContext` on `BeforeTool` | documented; source-read, not run                                      |
| Qwen Code                                | expected, through `additionalContext`            | measured on `PostToolUse` and `UserPromptSubmit`; not on `PreToolUse` |
| Copilot                                  | **no**                                           | measured: `preToolUse` output reaches the model only as a deny reason |
| Cursor, Kimi Code, Windsurf, Antigravity | **unknown**                                      | not measured on a pre-tool event                                      |

Where it does not arrive, the rule it nudges about is still in the skill.

⚠️ **No timestamp, and that is a cost decision.** macOS ships bash 3.2, which has
neither `printf '%(%s)T'` nor `$EPOCHSECONDS`, so a timestamp means a `date` fork on
every hook of every tool call. The session directory answers "this session?" and the
file's mtime answers "recently?".

## An empty string is not a missing value, and `//` cannot tell them apart

⚠️ **jq's `//` falls back on `null` and `false` only.** An empty string is a
value, so it **wins** a fallback chain and a better later source is never
reached. Measured on `cursor-agent` 2026.09.15-d2fe57e: every event that
carries `cwd` carries it as `""`, so

```text
.cwd // (.workspace_roots // [] | .[0]) // ""
```

handed the shared scripts an empty cwd, and `juscribe_sop_require_jus_project`
answered that by exiting 0. **Every guard allowed exactly what it exists to
block, for weeks, and nothing anywhere said so.**

**The distinction that decides whether a chain is at risk is how many sources it
names**, not whether it mentions a cwd:

- **One source** — `.x // ""` — is safe. An empty `x` and an absent `x` produce
  the same answer, so `//` and a length check agree.
- **Two or more** — `.a // .b // $c` — is the bug. Only here does an empty
  string cost you something that was there.

Every multi-source chain in the bundle now goes through one helper, defined per
shim because the shims are deliberately standalone:

```jq
def pick: map(select(. != null and . != false and . != "")) | first // "";
```

### The audit, per shim

| Shim          | Multi-source chains                                                 | Status                                                                                                                                                                                                                                                                     |
| ------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cursor`      | `cwd` ← `workspace_roots[0]`                                        | **measured** — sends `""`. Fixed                                                                                                                                                                                                                                           |
| `antigravity` | `Cwd` ← `TargetFile` dir ← `workspacePaths[0]` ← `cwd` ← remembered | **measured** — sends no `cwd` at all and `workspacePaths` is `[]`. The empty-string half, where an empty entry beat the remembered cwd, fixed in this audit                                                                                                                |
| `windsurf`    | `cwd` ← `root_workspace_path` ← `$PWD`                              | ⚠️ **unverified** — not installed, and Cascade has no headless mode at all. Hardened anyway; the tests pin the shim's contract, not a captured payload                                                                                                                     |
| `copilot`     | `sessionId` ← `session_id`, `transcriptPath` ← `transcript_path`    | ⚠️ **unverified** — not installed. Also **unreachable**: the passthrough branch returns early on `has("tool_name") or has("session_id")`, so the second candidate is provably absent by the time the program runs. `pick` keeps them right if that branch is ever narrowed |
| `kimi-code`   | `path` → `file_path`, the inverted shape                            | **measured 2026-09-19** — always an absolute `tool_input.path`, never a `file_path` sibling. The contract is guarded anyway: an empty `path` must not overwrite a good `file_path`                                                                                         |
| `codex`       | none                                                                | every `//` in the shim ends at a literal                                                                                                                                                                                                                                   |
| `qwen`        | none                                                                | **measured 2026-09-19** — a real `cwd`, `session_id` and `transcript_path` on `UserPromptSubmit`, `PreToolUse`, `PostToolUse` and `Stop`                                                                                                                                   |

⚠️ **`copilot`'s row is the reason to check REACHABILITY and not just shape.**
Two chains there match the pattern exactly and neither can fire. Grepping for
the shape would have reported two defects fixed; there were none.

### Writing a test for this class — two conditions, both load-bearing

A test in this class must run **from a directory that is not a Juscribe
project** and with **`JUS_HOOKS_EVERYWHERE` unset**. Either one alone lets the
test pass over the bug:

- `tests.sh` exports `JUS_HOOKS_EVERYWHERE=1` globally (line 38), and that flag
  is the **first** thing `juscribe_sop_require_jus_project` reads — so with it
  set the cwd is never consulted at all.
- The shared scripts fall back to `$PWD`, so from inside a wired repository a
  shim that hands over nothing is rescued and looks correct.

That happened on the Cursor shim and was caught only by mutation. ⚠️ **The rule is about
the cwd chains, not a ritual** — the `kimi-code` pair keeps the flag set
deliberately, because there the project gate sits upstream of the thing under
test and unsetting it would make both arms exit 0 before the suppression table
is read. A control arm is what keeps that pair honest instead.

## Why the `$PWD` fallback stays

The fallback in `juscribe_sop_require_jus_project` is what made Cursor's empty `cwd` invisible,
so the audit above asked whether it should go. It stays; the reasoning, and the
replacement that makes that safe, is written on the function itself in
`scripts/lib/state.sh`.

## Measuring a tool's real payload

Reasoning about a vendor's payload is how three of these shims shipped wrong.
The cheapest capture is a hook that writes stdin to a file and exits 0, pointed
at by an **absolute** path in an isolated config:

```sh
#!/usr/bin/env bash
cat > "${JUS_CAPTURE_DIR:?}/$(date +%s)-$$.json"
exit 0
```

⚠️ **Do not override `HOME` to isolate a config when the manifest uses `~`
paths** — every command then resolves into the fake home, and a hook whose
command is missing fires nothing and says nothing (`qwen/README.md`). Use the
tool's own config-root variable (`CODEX_HOME`), a project-level config
(`.qwen/settings.json`), or absolute paths.

⚠️ **A model-issued tool call needs no vendor account.** A local stub answering
`/chat/completions` (SSE) or `/responses` with one canned `tool_calls` reply
drives the real hook path for every OpenAI-compatible tool here — which is how
`qwen` and `kimi-code` were measured on 2026-09-19.
