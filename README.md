# jus

Cross-tool Agent Skills bundle packaging the Juscribe Workflow SOP — two on-demand skills plus optional deterministic enforcement hooks (Claude Code only). Loads in any tool that supports the [Agent Skills standard](https://agentskills.io); ships first-class manifests for Claude Code and Gemini CLI.

## What's in the box

```
jus/
├── .claude-plugin/
│   ├── plugin.json                 # Claude Code plugin manifest
│   └── marketplace.json            # Claude Code marketplace manifest (distributable install)
├── CHANGELOG.md                    # Release history + versioning strategy
├── gemini-extension.json           # Gemini CLI extension manifest
├── GEMINI.md                       # Gemini CLI baseline context
├── AGENTS.md                       # OpenAI Codex baseline context
├── skills/
│   ├── hard-rules/SKILL.md         # Non-negotiable rules + the why
│   └── ticket-workflow/SKILL.md    # Single load-bearing skill: lifecycle + estimation/labels/testing/API
└── hooks/
    ├── hooks.json                  # Claude Code hook manifest
    ├── tests.sh                    # Hook + manifest test harness
    └── scripts/                    # bash hook scripts (jq required)
```

> **Distributable layout.** The standalone [`juscribe/jus-skills`](https://github.com/juscribe/jus-skills) repo's root is the contents of this `jus/` directory, so `plugin.json` and `marketplace.json` both sit at the repo root's `.claude-plugin/` and the plugin `source` is `"./"`.

The skills are tool-agnostic Markdown — readable by any agent that loads them. The hooks are Claude Code-specific and provide a deterministic backstop for the most painful hard rules.

## Skills

| Skill                                | When it fires                                                                    |
| ------------------------------------ | -------------------------------------------------------------------------------- |
| `jus:hard-rules`            | Auto-loaded at session start; about-to-write-code; about-to-edit-description     |
| `jus:ticket-workflow`       | The single load-bearing skill — any ticket work: lifecycle, transitions, comments, delivery, **plus** estimation, labels, testing gates, and the `jus` CLI / API reference |

> **One load-bearing skill, by design.** Cold-start validation (#1704 / #1854) found that only `ticket-workflow` (and `hard-rules`) reliably auto-invoke — the earlier `testing-gates`, `juscribe-api`, and `estimation-labels` skills never fired, because `ticket-workflow` already had their content resident. They were retired in #1856 and their reference folded into `ticket-workflow`. Don't slim that content on the assumption a specialist skill will auto-load to cover it — none will.

## Hooks

Nine bash scripts wired into Claude Code's hook system. Each is a deterministic backstop (hard block) or soft nudge supporting the prompt-level rules in `hard-rules` / `ticket-workflow`. All are `jus-`prefixed.

| Hook                                                 | Event                | What it does                                                              |
| ---------------------------------------------------- | -------------------- | ------------------------------------------------------------------------- |
| `jus-block-force-push.sh`                            | `PreToolUse Bash`    | Blocks `git push --force`, `-f`, and `--force-with-lease`                 |
| `jus-block-no-verify.sh`                             | `PreToolUse Bash`    | Blocks any command containing `--no-verify`                               |
| `jus-pre-commit-gate.sh`                             | `PreToolUse Bash`    | Blocks `git commit` if linters haven't run since the last code edit       |
| `jus-block-lint-suppression.sh`                      | `PreToolUse Edit/Write` | Blocks edits that introduce a new `rubocop:disable`, `eslint-disable`, `@ts-ignore`, `:reek:`, etc. |
| `jus-track-edits.sh` + `jus-post-bash-tracker.sh`    | `PostToolUse`        | Records edits, lint/commit successes, and ticket-lifecycle state (active ticket, `started` transition, start-comment posted) in per-session state |
| `jus-dirty-tree-nudge.sh`                            | `PostToolUse Edit/Write` | After 5 uncommitted edits, emits a system-message reminder to commit (non-blocking) |
| `jus-start-comment-nudge.sh`                         | `PostToolUse Edit/Write` | On the first source-file edit after a `started` transition with no start comment yet, nudges (non-blocking) to post the start comment first |
| `jus-stop-uncommitted.sh`                            | `Stop`               | Prevents the session from ending while the working tree is dirty          |

### Per-session state

Hooks track timestamps and counters in `${CLAUDE_PLUGIN_DATA}/sessions/<session_id>/`. State is reset when a successful `git commit` is observed. The `stop-uncommitted.sh` hook respects `stop_hook_active=true` to avoid infinite stop-block loops.

### Tunable

| Variable                        | Default | Effect                                              |
| ------------------------------- | ------- | --------------------------------------------------- |
| `JUSCRIBE_SOP_NUDGE_THRESHOLD`  | `5`     | Edits without a commit before the dirty-tree nudge fires |

## Installing

> **Non-Claude tools all install the same way** — the canonical `.agents/skills/` recipe below. Options D–G add per-tool notes only; none has its own install path.

### The canonical `.agents/skills/` install (all non-Claude tools)

`.agents/skills/` is the open-standard directory read by Codex, Cursor 2.4+, Kimi Code, Windsurf, Zed, Antigravity, and Claude Code. Install with one shared clone plus per-skill symlinks in the **standard layout** (`.agents/skills/<name>/SKILL.md`):

```sh
git clone https://github.com/juscribe/jus-skills.git ~/.jus-skills             # once per machine
mkdir -p .agents/skills && ln -sfn ~/.jus-skills/skills/* .agents/skills/      # this project
mkdir -p ~/.agents/skills && ln -sfn ~/.jus-skills/skills/* ~/.agents/skills/  # or: every project
```

Update with `git -C ~/.jus-skills pull` (re-run the `ln` line if a release adds a new skill). `jus init` runs this recipe for you on skills-capable tools.

- **Standard layout only — never clone the repo into a skills directory.** A nested clone (`.agents/skills/jus/skills/<name>/…`) loads only on tools whose discovery happens to recurse (Codex today, and [openai/codex#22275](https://github.com/openai/codex/issues/22275) asks for that to be restricted). `jus init` offers a migration when it finds one.
- **Symlink caveat** — if a tool doesn't list the skills (Antigravity's IDE ignores symlinks for global skills, issue #633), replace the symlinks with copies: `cp -r ~/.jus-skills/skills/* .agents/skills/`.
- **Baseline context is optional** — the skills are self-sufficient; auto-invocation runs on their `description` frontmatter. The bundle's `AGENTS.md`/`GEMINI.md` stay in `~/.jus-skills/` for tools that want them; `jus init`'s legacy append embeds the SOP into a context file instead (never do both).

### Option A — local development (recommended for monumental)

Already part of the monumental repo. Load it with:

```sh
claude --plugin-dir ./jus
```

`/reload-plugins` picks up changes without restarting.

### Option B — via the marketplace (distributable install)

The bundle ships a `marketplace.json`, so once the `juscribe/jus-skills` repo is
published you install it in two commands from inside Claude Code:

```sh
/plugin marketplace add juscribe/jus-skills   # registers the "jus-skills" marketplace
/plugin install jus@jus-skills                # installs the "jus" plugin from it
```

The `@jus-skills` suffix is the marketplace `name` (from `marketplace.json`), not
the repo name — they happen to match here by design. The version is pinned by
`plugin.json`; see [`CHANGELOG.md`](CHANGELOG.md) for the versioning strategy.
`/plugin marketplace update jus-skills` pulls later releases.

### Option C — manual skills copy (skills only, no hooks)

> Prefer **Option B (marketplace)** — it's the recommended path for external Claude Code users and is the only one that also installs the enforcement hooks. This manual copy is a fallback for users who want *only* the skills in their personal config without enabling the full plugin.

```sh
cp -r jus/skills/* ~/.claude/skills/
```

Hooks must be installed via Option A or B — they require `${CLAUDE_PLUGIN_ROOT}` resolution that only works inside an enabled plugin.

### Option D — Google Antigravity CLI (`agy`)

> ⚠️ **Gemini CLI is being sunset on 2026-06-18** in favor of [Google Antigravity](https://antigravity.google) and its CLI (`agy`). Skills, hooks, subagents, and extensions ("now Antigravity plugins") carry forward. ([Google announcement](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)) The old `gemini extensions install` path stops serving requests after that date — target Antigravity instead.

Antigravity discovers **project skills** from `<workspace-root>/.agents/skills/<name>/SKILL.md` — the same cross-tool path Claude Code, Codex, Cursor, Windsurf, and Zed use. (Antigravity's current default is the plural `.agents/skills/`, with the singular `.agent/skills/` kept for backward compatibility; the official [skills codelab](https://codelabs.developers.google.com/getting-started-with-antigravity-skills) still shows the singular form.) **Install via the canonical `.agents/skills/` recipe above.**

Global (user-level) skills live at `~/.gemini/antigravity/skills/<name>/SKILL.md`.

- **Context files** — Antigravity reads `GEMINI.md` and `AGENTS.md` unchanged ("no modifications needed"; `GEMINI.md` wins on conflict). Do **not** add a `.antigravity.md`; it is not part of the documented context hierarchy.
- **Legacy extension** — bring the existing `gemini-extension.json` across with `agy plugin import gemini` (per Google's migration guide; the exact `agy plugin install/list/...` syntax is not yet documented — only `import gemini` is).
- **Do NOT hand-author an Antigravity `plugin.json`** — its field schema is undocumented in every primary source. Generate it via `agy plugin import gemini`, never by guessing keys. (The bundle's `.claude-plugin/plugin.json` is a *Claude Code* manifest — unrelated; leave it untouched.)
- **Symlink caveat — verify on a live install.** Antigravity's IDE is confirmed to ignore symlinks for *global* skills ([issue #633](https://github.com/google-antigravity/antigravity-cli/issues/633)); project-level symlink-following is unconfirmed. If skills don't appear, swap the `.agents/skills/` symlinks for real copies: `cp -r jus/skills/* .agents/skills/`.

Smoke-test (requires a real `agy` install): launch `agy` in a repo whose `.agents/skills/` exposes the bundle, and confirm the 2 skills appear (they convert to `/slash-commands` in the TUI) and auto-activate on matching intent.

### Option E — Antigravity IDE (Antigravity desktop / successor to Gemini Code Assist)

> ⚠️ **Gemini Code Assist's IDE agent extension is sunset on the same 2026-06-18 date.** Its successor is the Antigravity editor, which shares the same agent harness as the CLI.

The IDE reads the **same project `.agents/skills/<name>/SKILL.md`** layout as the CLI (Option D) — no separate manifest or registration; the portable alias covers both surfaces. Keep `GEMINI.md` + `AGENTS.md` for baseline context.

Smoke-test (requires the Antigravity editor): open a workspace whose `.agents/skills/` exposes the bundle, open the agent panel, and confirm the 2 skills are listed and auto-activate. **If they don't appear, suspect symlink discovery** (issue #633) and switch to copied skill directories.

### Option F — OpenAI Codex (CLI / IDE / app)

OpenAI Codex adopted the [Agent Skills standard](https://agentskills.io) in Dec 2025 across all three surfaces — CLI, the VS Code / JetBrains IDE plugins, and the Codex app. They all read the same `SKILL.md` files this bundle ships; no per-surface variants are needed. (Codex's older "custom prompts" mechanism is deprecated upstream in favor of skills.)

Codex's **documented** skill roots are exactly the canonical ones — project `.agents/skills/` (scanned in every directory from the CWD up to the repo root) and user `~/.agents/skills/` — so **install via the canonical `.agents/skills/` recipe above**; Codex needs nothing else.

Two Codex-specific locations exist but should **not** be used:

- `~/.codex/skills/` still loads, but as a deprecated backward-compat location.
- A project `.codex/skills/` works only through an undocumented config layer, and the previously documented `git clone … .codex/skills/jus` layout survives only because discovery currently recurses six levels deep — behavior [openai/codex#22275](https://github.com/openai/codex/issues/22275) asks OpenAI to restrict. If you installed that way, re-install with the canonical recipe and delete the old clone.

Notes:

- Codex does **not** read the bundle's `AGENTS.md` out of a skills directory — instruction files are composed from the project root down to the CWD only. Use `jus init`'s append if you want the SOP in a context file (never alongside the skills install).
- Auto-invocation uses the `description` frontmatter — the same matching heuristic as Claude Code and Gemini. `allowed-tools` is ignored.

Verify after install: open a Codex session (CLI, IDE chat panel, or app) and ask something like *"what's the ticket workflow?"* — the `ticket-workflow` skill should auto-activate. `/skills` lists loaded skills; a `$ticket-workflow` mention invokes one explicitly.

### Option G — Cursor 2.4+

Cursor 2.4 added an Agent Skills surface that reads `SKILL.md` files directly — there is no extension manifest to register, just a directory convention. Cursor auto-loads skills from any of:

| Path                             | Scope                              |
| -------------------------------- | ---------------------------------- |
| `.cursor/skills/` (project root) | Per-project                        |
| `.agents/skills/` (project root) | Per-project, portable across tools |
| `~/.cursor/skills/`              | Global, all projects               |
| `~/.agents/skills/`              | Global, portable across tools      |

Cursor reads the canonical `.agents/skills/` path natively — **install via the canonical recipe above**. (`.cursor/skills/` also works as a Cursor-only location, but prefer the shared path so one install serves every tool.)

Verify after install (or after `Reload Window`) by opening Cursor's agent panel and asking *"how do I deliver this ticket?"* — the `ticket-workflow` skill should auto-activate based on its `description` frontmatter, the same way Claude Code, Gemini, and Codex do.

Cursor recognizes the same `name` and `description` fields Claude Code uses; `allowed-tools` is silently ignored — same delta we already document for Gemini and Codex. The bundle ships skills only — Cursor's separate Subagents surface (`.cursor/agents/`) is out of scope, and per Cursor's docs, subagents currently can't load skills anyway.

### Option H — monumental project-committed enablement (chosen for this repo)

This is how the bundle is wired into the monumental repo itself (ticket #1835). It is the project-committed variant of Options B/C, chosen over plugin-marketplace registration because it needs **zero per-user setup, survives across sessions, and travels into dispatch worktrees** (so autonomous dispatch agents load the SOP too).

> **Do NOT _also_ marketplace-install the plugin in monumental.** This repo already loads the bundle via the committed copy below, so adding `/plugin install jus@jus-skills` here is pure duplication: the skills show up twice (committed `hard-rules`/`ticket-workflow` **plus** `jus:`-prefixed copies) and the nine hooks register twice (committed `.claude/settings.json` **plus** the plugin), so each hook fires twice. The marketplace install (Option B) is for **other** repos that lack the committed copy. If you installed it here to smoke-test publishing, back it out with `/plugin uninstall jus@jus-skills` && `/reload-plugins` (leave the marketplace *added* — that's harmless).

**Skills** — per-skill relative symlinks point Claude Code's auto-discovered `.claude/skills/` and the cross-tool `.agents/skills/` at the canonical bundle:

```sh
for name in ticket-workflow hard-rules; do
  ln -sfn "../../jus/skills/$name" ".claude/skills/$name"
  ln -sfn "../../jus/skills/$name" ".agents/skills/$name"
done
```

Relative targets mean the symlinks resolve inside any `git worktree` checkout (where `jus/` is also present). `.claude/skills/` is read by Claude Code; `.agents/skills/` is the open-standard path read by Codex, Cursor, Copilot, Windsurf, and Zed — one set of symlinks serves all of them.

**Hooks** — because the skills are loaded via `.claude/skills/` (not as an installed plugin), `${CLAUDE_PLUGIN_ROOT}` does not resolve, so the hooks are wired into the committed `.claude/settings.json` using `${CLAUDE_PROJECT_DIR}` instead. The scripts self-resolve their `lib/state.sh` via `$(dirname "$0")`, so they run identically whether invoked from settings or from a plugin. Committing them to `.claude/settings.json` (not `settings.local.json`) is deliberate: it shares the enforcement and carries it into dispatch worktrees.

**Lint gate (`lefthook`) — monumental-only, NOT a jus requirement.** `lefthook` is monumental's own project lint gate (`lefthook.yml` at the repo root); it is **not** part of this bundle and **not** a prerequisite for adopting jus elsewhere — the bundle's only host dependencies remain `jq` / `bash` / `git` (see Prerequisites). For monumental specifically, enable it with `lefthook install --force` (a plain `lefthook install` is refused because `core.hooksPath` is pinned to `.git/hooks/`). git-secrets is preserved automatically: lefthook only manages the `pre-commit` hook — where `lefthook.yml` re-runs `git secrets` — and leaves the separate `commit-msg` git-secrets hook untouched. Escape hatch: `LEFTHOOK=0 git commit`.

### Cross-tool support matrix

| Tool | Skills supported | Hooks bundled | Install path |
|------|------------------|---------------|--------------|
| Claude Code | ✅ via `.claude-plugin/plugin.json` | ✅ | `claude --plugin-dir ./jus` or `/plugin marketplace add juscribe/jus-skills` → `/plugin install jus@jus-skills` |
| Google Antigravity CLI (`agy`) | ✅ via `.agents/skills/` (Gemini CLI sunset 2026-06-18) | ❌ | canonical `.agents/skills/` install; `agy plugin import gemini` for the legacy ext |
| Antigravity IDE (desktop) | ✅ via `.agents/skills/` (Gemini Code Assist IDE sunset 2026-06-18) | ❌ | canonical `.agents/skills/` install (same project path as the CLI) |
| OpenAI Codex (CLI / IDE / app) | ✅ via `.agents/skills/` (documented roots; same `SKILL.md`) | ❌ | canonical `.agents/skills/` install |
| Cursor 2.4+ | ✅ via Skills surface (uses same `SKILL.md`) | ❌ | canonical `.agents/skills/` install (`.cursor/skills/` also read) |
| Kimi Code (CLI / VS Code / ACP) | ✅ via `.agents/skills/` (also `.kimi-code/skills/`; does **not** read `.claude/skills/`) | ❌ (native hook system exists — adapter tracked by #1977) | canonical `.agents/skills/` install |
| Windsurf | ✅ via `.agents/skills/` (native skills) | ❌ | canonical `.agents/skills/` install |
| Zed | ✅ via `.agents/skills/` (native skills) | ❌ | canonical `.agents/skills/` install |

**Frontmatter portability.** The `SKILL.md` files use `name`, `description`, and `allowed-tools`. The first two are required by every tool above; `allowed-tools` is a Claude Code-only allowlist hint that other tools ignore. One set of skill files works for every supported tool — no per-tool variants needed.

**Hooks are Claude Code-only.** Gemini CLI, Gemini Code Assist, Cursor, and Codex have no equivalent deterministic enforcement mechanism today; the `hard-rules` skill is the prompt-level fallback in those environments.

## Prerequisites

- Claude Code with plugin support
- `jq` on the host — used by every hook script. Install with `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu)
- `bash` 4+ — the scripts use `[[ ... ]]` and `=~` regex
- `git` — for the dirty-tree and stop hooks

If `jq` is missing, hooks **fail open** (exit 0 without enforcing) rather than wedge the tool call. You'll lose enforcement, not Claude Code itself.

## Testing the hooks & manifests

```sh
./jus/hooks/tests.sh
```

Synthetic Claude Code hook inputs are piped to each script; exit codes and output are asserted. A final section validates the distributable manifests — `plugin.json` and `marketplace.json` are well-formed, the version is pinned to `plugin.json`, and the marketplace/plugin names stay consistent with `source: "./"`. The harness uses an isolated `CLAUDE_PLUGIN_DATA` temp dir so it doesn't pollute real state.

## Limitations

- **Hooks are Claude Code-only.** Other agents (Gemini CLI, Cursor, Codex CLI, Aider) get the skill layer only — there is no equivalent harness-level enforcement in those tools.
- **Hooks are advisory, not a sandbox.** A determined model can `disableAllHooks` or edit `settings.json`. The hooks raise the cost of skipping a rule, not the impossibility.
- **The pre-commit gate detects linters by command shape.** If your project uses unusual lint invocations (custom shell wrappers, `make lint`, etc.), add them to `juscribe_sop_is_lint_command` in `hooks/scripts/lib/state.sh`.
- **Chained commands are heuristic.** `bin/rubocop && git commit` is allowed because the gate sees the lint invocation in the command string. Truly novel chaining patterns may need additional patterns.

## Related skills

The hooks back up specific rules in `jus:hard-rules`. The skill's "Two-Layer Enforcement" section maps each rule to its hook (or notes that no hook exists). Read the skill first, then this README for the mechanics.

## License

[MIT](LICENSE) © Juscribe. The license covers copyright only — you may copy, fork, and redistribute the skills and hooks, but the **Juscribe / jus name and brand** are not licensed for reuse.
