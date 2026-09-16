# jus enforcement hooks — GitHub Copilot adapter

Runs all thirteen shared hook scripts (`../scripts/`) under GitHub Copilot's
native hooks system (#4260).

> ## ⚠️ NOT LIVE-VERIFIED. READ THIS BEFORE RELYING ON IT.
>
> **No hook in this adapter has been watched refusing anything.** The `copilot`
> CLI is not installed on the machine this was written on, so what follows rests
> on GitHub's published hooks reference plus the shim's own tests against
> synthetic payloads — not on a session where a `git push --force` was actually
> blocked.
>
> That is the standard the Kimi adapter set and it is the honest label here.
> Compare: the Codex adapter's README describes a prompted force-push blocked
> with the remote tip unmoved, because codex was installed.
>
> **And there is an open upstream bug in the exact mechanism this depends on.**
> [github/copilot-cli#3874](https://github.com/github/copilot-cli/issues/3874),
> _"`preToolUse` agent hook denial does not work"_, filed 2026-06-20 and still
> open with no maintainer reply. The report is against the **Copilot Chat
> extension v1.0.65** rather than the CLI, and the reporter tried exit 2,
> `preToolUse` deny and `permissionRequest` deny — none blocked. Whether the CLI
> shares the defect is unestablished.
>
> **What would settle both:** install the CLI (`npm install -g @github/copilot`),
> prompt it to force-push a throwaway branch, and check the remote tip. Then
> replace this box with what you saw.

## Setup

One shared clone per machine, then either scope:

```sh
git clone https://github.com/juscribe/jus-skills.git ~/.jus-skills
```

**Per project** — Copilot reads every `*.json` under `.github/hooks/`:

```sh
mkdir -p .github/hooks && cp ~/.jus-skills/hooks/copilot/hooks.json .github/hooks/jus.json
```

**Per machine** — same file, user scope:

```sh
mkdir -p ~/.copilot/hooks && cp ~/.jus-skills/hooks/copilot/hooks.json ~/.copilot/hooks/jus.json
```

⚠️ **Copilot COMBINES hooks from every layer it finds** — policy, repository,
user, repository settings, user settings, plugins. Installing at both scopes
registers all thirteen twice and fires each one twice per event. Pick one. This
is the same double-registration trap `installing-the-bundle.md` documents for
Claude Code, and it has the same symptom: nothing fails, a counter just doubles.

The skills are a separate install and do not come with these. See
`installing-the-bundle.md`; Copilot reads `.agents/skills/`, `.github/skills/`
and `.claude/skills/`, so the canonical recipe works unchanged.

## What the shim does

Copilot's documented payload is camelCase and differs from the shared scripts'
Claude-Code shape in four ways, so every hook runs behind
`scripts/jus-copilot-adapt.sh`:

| Copilot                             | shared scripts           |
| ----------------------------------- | ------------------------ |
| `sessionId`                         | `session_id`             |
| `toolName`                          | `tool_name`              |
| `toolArgs` — **a JSON string**      | `tool_input` — an object |
| `toolResult`                        | `tool_response`          |
| `transcriptPath`                    | `transcript_path`        |
| `cwd`, `prompt`, `stop_hook_active` | unchanged                |

⚠️ **`toolArgs` is a string containing JSON, and that is the trap.** GitHub's own
worked example re-parses it (`jq -r '.toolArgs'`, then `jq -r '.command'` on the
result). Read it as an object and every field comes back `null`, which reads as
"no command" — so every blocker passes, silently. This is the Kimi
`tool_response` failure (#4207) with a different field name: a type mismatch that
fails **open**, and the only symptom is protection that was never there.

## The three degradations

**1. Exit codes are not symmetric, and the shim absorbs the difference.**

Copilot documents that for a `preToolUse` command hook, _"exit 2, crashes, and
other non-zero exits all fail-closed and deny the tool call"_. The shared scripts
are deliberately fail-**open** — a missing `jq`, malformed JSON or an unreadable
state file exits 0 rather than wedging the session (`lib/state.sh`) — but a
genuine crash exits 1, and under Copilot's rule that would block a tool call the
hook never meant to judge.

So the shim collapses every exit but 2 to 0. A deliberate block stays a block; a
broken hook stays out of the way.

⚠️ **The cost is real and is stated rather than hidden:** a Copilot user gets
marginally _less_ protection than Copilot's own default from a hook that is
itself broken. That is the right trade for a guard that must never be the reason
somebody cannot work, and it is the same doctrine every other adapter here
follows. If you want Copilot's fail-closed behaviour instead, delete the two
`[[ "$ec" -eq 2 ]]` lines at the end of the shim — and accept that a `jq` upgrade
can then stop the agent working.

**2. Tool names are inferred from the argument shape, not from a name list.**

`bash` is the only tool name GitHub publishes. The edit, write and read names are
not documented, and a guessed name that is wrong **does not fail loudly** — the
hook simply never fires, which is the silent no-protection state this bundle
exists to end. So the shim matches `bash` by name (documented) and otherwise
reads the shape of `toolArgs`:

| `toolArgs` carries            | mapped to                     |
| ----------------------------- | ----------------------------- |
| `.command`                    | `Bash`                        |
| `.edits`                      | `MultiEdit`                   |
| `.old_string` / `.new_string` | `Edit`                        |
| `.content`                    | `Write`                       |
| none of those                 | the raw `toolName`, unchanged |

⚠️ **This is the part most likely to be wrong**, and the install is what settles
it: run one edit with a hook that logs the payload, and replace this table with
the real names.

**3. No `matcher` is set, deliberately.**

Copilot's `matcher` is compiled as `^(?:PATTERN)$` against `toolName`, and a
pattern that does not match a name we do not know registers a hook that never
runs. Every shared script already checks `tool_name` itself and exits 0 when it
does not care, so filtering is left to them. The cost is a few more hook
invocations per turn; the alternative is silent non-coverage.

⚠️ **`jus-docs-nudge.sh` is registered ONCE here, not twice.** Claude's manifest
registers it under two matchers (`Bash` and `Edit|Write|MultiEdit`); with no
matcher, a second registration would simply double-fire it on every tool.

## Event mapping

| Shared hook                           | Claude event       | Copilot event         |
| ------------------------------------- | ------------------ | --------------------- |
| `jus-block-force-push.sh`             | `PreToolUse`       | `preToolUse`          |
| `jus-block-no-verify.sh`              | `PreToolUse`       | `preToolUse`          |
| `jus-pre-commit-gate.sh`              | `PreToolUse`       | `preToolUse`          |
| `jus-block-accepted-manifest-edit.sh` | `PreToolUse`       | `preToolUse`          |
| `jus-blocker-date-nudge.sh`           | `PreToolUse`       | `preToolUse`          |
| `jus-block-lint-suppression.sh`       | `PreToolUse`       | `preToolUse`          |
| `jus-track-edits.sh`                  | `PostToolUse`      | `postToolUse`         |
| `jus-post-bash-tracker.sh`            | `PostToolUse`      | `postToolUse`         |
| `jus-start-comment-nudge.sh`          | `PostToolUse`      | `postToolUse`         |
| `jus-docs-nudge.sh`                   | `PostToolUse` ×2   | `postToolUse` ×1      |
| `jus-stop-uncommitted.sh`             | `Stop`             | `agentStop`           |
| `jus-ticket-claim-nudge.sh`           | `UserPromptSubmit` | `userPromptSubmitted` |

All thirteen registrations are present. `sessionStart`, `sessionEnd` and
`errorOccurred` have no shared hook behind them and are left unregistered.

## Two surfaces, and only one of them is testable here

Copilot hooks run in both the **CLI** and the **cloud coding agent**. The cloud
agent reads `.github/hooks/*.json` from the repository only — no user scope — and
runs on GitHub's infrastructure, so nothing about it can be verified from a
laptop. Whatever the install settles about the CLI, **say so about the CLI**; the
cloud agent's behaviour stays unestablished either way.

## Audit trail

Copilot writes a `policyDeny` entry to `.github/hooks/logs/audit.jsonl` when a
hook denies. That file is the cheapest place to confirm a block actually
happened, and it is worth checking before believing a hook fired — a model that
declines to run a command for its own reasons looks identical from the transcript.

## Tests

`jus/hooks/tests.sh`, in the `copilot adapter` section: the manifest is valid
JSON in Copilot's shape, every script it names exists in the bundle, and the shim
normalises each payload shape — including that a blocker still exits 2 through
it, that a non-2 failure is collapsed to 0, and that the string-valued `toolArgs`
is re-parsed rather than read as an object.
