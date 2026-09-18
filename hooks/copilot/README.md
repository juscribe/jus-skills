# jus enforcement hooks — GitHub Copilot adapter

Runs all thirteen shared hook scripts (`../scripts/`) under GitHub Copilot's
native hooks system (#4260).

> ## ✅ LIVE-VERIFIED against copilot 1.0.85, 2026-09-17
>
> A model-issued `git push --force origin main` was **denied by the preToolUse
> hook** and the remote tip did not move. The control arm — same repository, same
> command, manifest not installed — force-pushed successfully and moved the tip,
> so the block is this adapter's doing and not a Copilot guardrail.
>
> **[github/copilot-cli#3874](https://github.com/github/copilot-cli/issues/3874)
> does not reach the CLI.** That issue reports `preToolUse` denial not working;
> it is filed against the Chat extension v1.0.65, and denial works here.
>
> **No GitHub account, Copilot subscription or sign-in was involved** — see
> _Verifying this yourself_ below. The CLI half of the ticket's verification
> criterion is met; the cloud agent remains unverifiable from a laptop.
>
> ⚠️ **The same run found the adapter silently unprotecting every edit**, which
> is written up under _The degradations_ below. An adapter built from another
> vendor's payload shape passes its own tests and protects nothing.

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

## The degradations

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

**2. Tool names and argument names are Copilot's own, and guessing them fails
open.**

Read off the `tools` array copilot 1.0.85 sends its model:

| Copilot tool | Its arguments                | Mapped to |
| ------------ | ---------------------------- | --------- |
| `bash`       | `command`                    | `Bash`    |
| `edit`       | `path`, `old_str`, `new_str` | `Edit`    |
| `create`     | `path`, `file_text`          | `Write`   |
| `view`       | `path`                       | `Read`    |

The shim renames `path` → `file_path`, `old_str` → `old_string`, `new_str` →
`new_string`, `file_text` → `content`, each only when the Claude-shaped key is
absent. A tool on neither list still falls back to argument-shape inference, so a
plugin tool or a later rename does not silently disable a blocker.

⚠️ **THIS SHIPPED WRONG AND IS THE ADAPTER'S ONE MEASURED FAILURE.** The first
cut inferred `Edit` from `old_string`/`new_string` and `Write` from `content` —
Claude Code's names, which Copilot never sends. Every edit-based blocker
therefore fell through its own `tool_name` guard and exited 0. Measured live on
2026-09-17: a model-issued `edit` adding `# rubocop:disable Metrics/AbcSize`
went straight into the file, with `jus-block-lint-suppression.sh` registered and
firing. **Nothing reported anything.** The tests were green because they were
built from the same guess as the shim.

**3. No `matcher` is set, deliberately.**

Copilot's `matcher` is compiled as `^(?:PATTERN)$` against `toolName`, and a
pattern that does not match a name we do not know registers a hook that never
runs. Every shared script already checks `tool_name` itself and exits 0 when it
does not care, so filtering is left to them. The cost is a few more hook
invocations per turn; the alternative is silent non-coverage.

⚠️ **`jus-docs-nudge.sh` is registered ONCE here, not twice.** Claude's manifest
registers it under two matchers (`Bash` and `Edit|Write|MultiEdit`); with no
matcher, a second registration would simply double-fire it on every tool.

**4. A hook can only speak to the model by denying a tool call.**

Measured on 1.0.85, each with a control arm:

| Event                 | hook prints to stdout                    | to stderr     | exits 2                                      |
| --------------------- | ---------------------------------------- | ------------- | -------------------------------------------- |
| `preToolUse`          | **reaches the model** as the deny reason | terminal only | **denies**                                   |
| `postToolUse`         | nothing                                  | nothing       | terminal only, **does not deny**             |
| `userPromptSubmitted` | nothing                                  | nothing       | —                                            |
| `sessionStart`        | nothing                                  | nothing       | —                                            |
| `agentStop`           | —                                        | terminal      | did **not** force a continuation (`-p` mode) |

So the six `preToolUse` blockers are fully effective and, thanks to the deny
translation above, they explain themselves. **The four `postToolUse` hooks are
observe-only**: `jus-track-edits.sh` and `jus-post-bash-tracker.sh` still do
their real job, which is writing state to disk, but `jus-start-comment-nudge.sh`
and `jus-docs-nudge.sh` exist to _tell the model something_ and no channel
carries it. This is the Kimi degradation (#4207) — with the difference that Kimi
could reroute through prompt-submit and Copilot cannot, because
`userPromptSubmitted` injects nothing either.

⚠️ **`agentStop` did not force a continuation** in non-interactive `-p` mode: the
dirty-tree message printed to the terminal and the session ended. Whether an
interactive session continues is untested.

## Verifying this yourself — no GitHub account needed

⚠️ **The sign-in this adapter waited on turned out to be unnecessary**, and the
route generalises to the other four adapters. `COPILOT_PROVIDER_BASE_URL` points
the CLI at any OpenAI-compatible endpoint and, in GitHub's own words, _"GitHub
authentication is not required"_. A stub that answers `/chat/completions` with a
canned `tool_calls` response drives a **real** model-issued tool call, through the
real permission path, with no account, no subscription and no network.

```sh
COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:8731 COPILOT_PROVIDER_TYPE=openai \
  COPILOT_PROVIDER_API_KEY=stub COPILOT_MODEL=stub-model COPILOT_ALLOW_ALL=true \
  copilot -p "force push main" --allow-all-tools
```

⚠️ **Without a provider override there is nothing to verify.** An unauthenticated
run dies at the credential check _before the session starts_ — not one hook
fires, `sessionStart` included. The codex trick of reaching for an event that
precedes the network call (#4288) does **not** transfer.

⚠️ **`COPILOT_ALLOW_ALL=true` is what trusts the directory**, and exactly `true`:
other truthy spellings only auto-approve tools and leave the hooks unloaded, so
the run looks clean and proves nothing.

⚠️ **Always run a control arm.** With the manifest removed the same force-push
must succeed and move the remote tip. Without it, "the command did not run" is
equally explained by the model declining, a bad stub response, or a typo in the
manifest path.

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
laptop. Everything above was measured on the **CLI**; the cloud agent's behaviour
stays unestablished.

## Audit trail

⚠️ **Not `.github/hooks/logs/audit.jsonl`** — this README claimed that file and a
`policyDeny` entry until it was checked; neither exists on 1.0.85. The real
record is per session, under `COPILOT_HOME` (default `~/.copilot`):

```sh
jq -c 'select(.type | startswith("hook"))' ~/.copilot/session-state/<session-id>/events.jsonl
```

Each hook produces a `hook.start` carrying the payload it was handed and a
`hook.end` carrying its result; a denial also shows as a
`tool.execution_complete` with `success: false`, and an `agentStop` block as a
`session.warning`. This is the cheapest place to confirm a block actually
happened — a model that declines to run a command for its own reasons looks
identical from the transcript.

⚠️ **`hook.end`'s `success: true` means the hook RAN, not that it allowed.** A
deny is `success: true` with the reason in `output`. Filtering on `success` to
find blocks finds none of them.

## Tests

`jus/hooks/tests.sh`, in the `copilot adapter` section (17 tests): the manifest is
valid JSON in Copilot's shape, every script it names exists in the bundle, all
thirteen are registered exactly once, and the shim normalises each payload shape
— the string-valued `toolArgs` re-parsed rather than read as an object, the
measured `edit`/`create` names and their `path`/`old_str`/`new_str`/`file_text`
arguments, the shape fallback for a tool on neither list, a non-2 failure
collapsed to 0, and the JSON deny form carrying the blocker's own reason.

⚠️ **These payloads are measured, not inferred, and that is the lesson.** The
first cut built them from Claude Code's field names; they passed, and the adapter
protected nothing. A test written from the same assumption as the code under test
confirms the assumption, not the behaviour. The live run above is what the
section is anchored to — keep them in step.
