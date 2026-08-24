# Changelog

All notable changes to the **jus** plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Versioning strategy

The plugin version tracks the **Juscribe SOP itself**, not the monumental app. The
single source of truth is `version` in [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json);
the marketplace entry deliberately omits a version so the two can never drift
(Claude Code lets `plugin.json` silently win when both declare one).

Bump the version when the SOP changes, by impact on an adopting agent:

| Bump      | When                                                                                                                                                                                                                    |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **MAJOR** | Breaking change to the behavioral contract — a skill removed/renamed, a hook's block semantics changed, the lifecycle reshaped, or anything that would make an existing setup behave differently in a non-additive way. |
| **MINOR** | Backwards-compatible additions — a new skill or hook, a new rule, a new lifecycle phase, expanded reference material.                                                                                                   |
| **PATCH** | Clarifications and fixes that don't change behavior — wording, typos, doc polish, a hook bug fix that only makes it match its documented intent.                                                                        |

Each release entry below should name the SOP change and, where relevant, the
Juscribe ticket (`#N`) that introduced it.

## [1.4.7] — 2026-08-24

### Changed

- Self-review: the section note quoted the wrong figure and pointed at the wrong tests (#2807)
- Drop the five sleeps, and assert what they were believed to be covering (#2807)

## [1.4.6] — 2026-08-21

### Changed

- The enforcement table said a rule was absent from the skill stating it (#2682)
- Guard the hook text too, not just the skill bodies (#2586)
- The published SOP stops mandating a testing methodology (#2586)

## [1.4.5] — 2026-08-19

### Changed

- Fix a false API claim this ticket published, and wire the guards into the gate (#2506)
- .jus/SOP.md becomes a generated artefact, and a phantom param dies (#2506)

## [1.4.4] — 2026-08-15

### Changed

- References are automatic; a prerequisite is a dependency (#2532)
- Move the batch rule to CLAUDE.md — it is not the plugin's to carry (#2525)
- Drain deliverable tickets before asking a blocking question (#2525)

## [1.4.3] — 2026-08-14

### Changed

- Marker titles name the thing itself — no prefixes, no leading icons (#2462)
- Nudge project docs at ticket pickup, keyed on labels and title (#2487)

## [1.4.2] — 2026-08-11

### Changed

- Strip the per-session file-ownership tracking out of the hooks (#2392)
- Shell was invisible to the gate in both directions (#2387)
- Partition the log instead of bailing on the first out-of-repo entry (#2388)
- A session that edited nothing no longer claims the whole dirty tree (#2366)
- Prune the resolved entries from a kept edits.log (#2362)
- Close the gate bypass: git global options no longer hide a commit (#2363)
- Record the 1.4.1 changelog entry that the release shipped without (#2261)

## [1.4.1] — 2026-08-10

> Entry written after `v1.4.1` was tagged, so the published snapshot at that tag
> does not contain it. Recorded here rather than skipped: the changelog is the
> record of what a version contains, and a missing entry is worse than a late
> one. It publishes with the next release. See #2374 — the release tool now
> takes the entry as an input, so the step cannot be skipped again.

### Fixed

- **The stop gate no longer blocks on other sessions' files after a commit**
  (#2355): the #2216 session scoping fell back to blocking on _any_ dirty file
  in the post-commit window, so a second agent working in the same repo could
  not stop. Resolution is now verified against git — a commit clears tracking
  only when it actually resolved the tracked edits — and a cross-repo or failed
  commit keeps the log rather than reading as resolved.
- **The dirty-tree nudge counts what it claims** (#2352): it fired at three
  edits reporting five, because it counted edit _events_ rather than distinct
  uncommitted files, and repeated delivery double-counted. It now derives the
  count from files, stays silent until checks have run since the last edit, and
  matches repo-relative recorded paths — the shape Codex records, which the
  session scoping previously missed entirely.
- **Editing an accepted release manifest is refused** (#2333): nothing
  mechanically prevented a description `PATCH` on an accepted ticket, so a
  shipped runbook could be rewritten to look like it had unrun commands. Comments
  are untouched — they are the sanctioned correction path — as are transitions
  and non-description updates.

## [1.4.0] — 2026-08-09

### Added

- **Mixed-actor ticket rule** (`hard-rules` → "Mixed-Actor Tickets — One Timeline, Both Assigned"; `ticket-workflow` → description conventions + `assignee_ids` metadata row): tickets that interleave stakeholder-only steps with agent steps assign BOTH parties and carry a single numbered, actor-tagged, checkboxed step list in execution order — never separate per-actor sections. The first unchecked box shows whose move it is; the External-blocker protocol fires whenever the next unchecked step is the stakeholder's.

## [1.3.1] — 2026-08-09

### Changed

- **Description rule scoped to its actual intent** (#2300, stakeholder
  correction): the append-only protection covers _stakeholder-authored_ text
  only — preserved verbatim, always. Agent-authored additions below the
  `---` separator are living documentation with an affirmative duty to stay
  current: edit them in place when facts change; do **not** stack dated
  "Update (…):" layers onto agent-authored sections. Reworded in
  `hard-rules` (rule section, enforcement table, frontmatter) and
  `ticket-workflow` (description conventions, cross-reference).

## [1.3.0] — 2026-08-09

### Added

- **`jus-docs-nudge.sh`** (`PostToolUse Edit|Write|MultiEdit`): on the first
  edit under a path the project maps in `.jus/docs-nudges.tsv`, a non-blocking
  nudge names the project doc for that subsystem and its when-to-read hint —
  once per doc per active ticket. A silent no-op for projects with no map, so
  the hook is safe everywhere. Registered for Claude Code and the Codex
  adapter; Kimi rides the prompt-time reminder like the other nudges (#2290,
  measured motivation in #2277: a documented gotcha re-derived from scratch
  15 hours after being written up).
- **Read-side documentation rule** in the `hard-rules` skill's Document
  Discoveries section: check the project docs index before debugging a
  subsystem, and route shared-relevance gotchas to the shared docs rather
  than per-user auto-memory (#2290, #2287).

## [1.2.3] — 2026-08-08

### Added

- **Ticket→project conversion**, documented in the `ticket-workflow` skill —
  the previously-missing `converted` and `archived` states and the
  `POST /workspaces/{ws}/tickets/{id}/convert` endpoint, so a ticket that has
  outgrown itself is converted (carrying title, description, requester and
  stakeholder) instead of cancelled and hand-recreated (#2205).
- **Retired-token guidance** in the `ticket-workflow` skill: a 401 naming an
  expired or retired token is a stop condition with a type-correct remedy —
  rotate a bot key, re-login a mobile session — not something to retry
  around (#2223).

### Fixed

- **The stop hook scopes its dirty-tree check to files this session actually
  edited** (its own `edits.log`), ending false blocks on a concurrent
  session's uncommitted files in a shared checkout (#2216).
- **Skill descriptions disambiguate Juscribe from other trackers**, so
  generic ticket language in a prompt no longer routes an agent to another
  tool's workflow skill (#2183).
- **Plugin-install surfaces say when `/reload-plugins` is required**, instead
  of leaving a freshly-installed plugin silently unloaded (#2194).
- **`hooks/tests.sh` no longer describes a manifest sync that was never
  implemented** (#2137).

## [1.2.2] — 2026-08-05

### Fixed

- **Request-shape gotchas for the `jus` API**, added to the `ticket-workflow`
  skill. Each is listed by the _symptom you are looking at_ rather than the
  cause, because every one presents as a hang, a no-op, a bare 500, or a silent
  success rather than an error:
  - a body-less `PATCH` hanging forever on stdin instead of defaulting to `{}`;
  - `position` silently ignored on create, so a new ticket lands at the end;
  - a backwards `/transition` returning a body of nulls and changing nothing;
  - `*_ids` writes succeeding while echoing back `null`, prompting a needless retry;
  - an enum-case mismatch (`"Release"` for `release`) surfacing as an
    unexplained **HTTP 500** that names no field.
    (#2121, #2129)

## [1.2.1] — 2026-08-03

Release-wrapper tag only — content is identical to 1.2.0. `gh skill publish`
needed a fresh semver tag to cut the GitHub release that makes the bundle
discoverable and installable for GitHub Copilot (`gh skill install
juscribe/jus-skills`), and the tag-protection ruleset added during the publish
makes the existing `v1.2.0` immutable. This entry aligns the monorepo manifests
with the published tag; the next SOP change ships as 1.2.2. (#1868)

## [1.2.0] — 2026-07-28

### Added

- **OpenAI Codex hooks adapter** (`hooks/codex/`): the shared enforcement
  scripts under Codex's native hooks system — Bash and Stop hooks register
  unchanged (the wire contracts match field-for-field); file edits run behind
  `jus-codex-adapt.sh`, which converts raw `apply_patch` text into the Edit
  shape the suppression blocker's delta logic expects. Ships a merge-ready
  `hooks.json`, trust-flow docs, and a tests.sh section. (#1976)
- **Kimi Code hooks adapter + plugin packaging**: `hooks/kimi-code/` carries
  a `config-hooks.toml` for `~/.kimi-code/config.toml` plus a `path` →
  `file_path` shim (Kimi's one payload divergence, pinned empirically on
  0.29.2), and the bundle root gains **`kimi.plugin.json`** — skills, hooks,
  and a session-start `hard-rules` load in a single Kimi plugin install.
  Kimi's observe-only PostToolUse means the dirty-tree nudge rides a new
  prompt-time reminder (`jus-kimi-prompt-nudge.sh`) instead. Live-verified:
  a prompted force-push and a suppression edit were both denied in real
  kimi-k2.7-code sessions. (#1977)

### Fixed

- The force-push and `--no-verify` blockers anchor to an **actual git
  invocation**: the command splits into segments (quoted regions dropped —
  a quoted string can only ever be an argument), and a force flag /
  `--no-verify` blocks only as an argument word of a `git push` / git
  segment. Previously the tokens matched anywhere in the raw command string,
  so a grep of the hook source, docs text quoting the rule, a `jus api`
  comment body, or a `-f` belonging to another chained command
  (`rm -f x && git push origin main`) all blocked spuriously. Also fixes a
  false negative: `git -C <path> push --force` was missed. (#1985)
- The lint-suppression blocker maps each directive to the file types its
  linter actually reads (rubocop/reek → ruby, eslint/ts directives → ts/js,
  mypy/pyright → py, nolint/nosec → go); quoting a token in docs or shell
  test fixtures no longer blocks an edit. A missing `file_path` stays
  fail-closed — every pattern remains active. (#1985)

## [1.1.1] — 2026-07-27

First published release since 1.0.1 — this tag also carries the previously
unpublished 1.1.0 content below.

### Changed

- Skill bodies no longer assume a Claude Code plugin host: enforcement is
  framed **harness-conditionally** (deterministic where the jus hooks run —
  Claude Code today, with Codex/Kimi Code adapters tracked under #1818 —
  explicitly prompt-level-only everywhere else), skill cross-references use
  plain names (the `jus:` prefix exists only under a Claude Code plugin
  install), and the document-discoveries rule targets "your agent's context
  file" rather than CLAUDE.md. `AGENTS.md` is retitled as shared baseline
  context for every AGENTS.md-reading tool (Codex, Kimi Code, Antigravity, …)
  instead of Codex-branded. (#1975)
- One canonical non-Claude install — a shared clone at `~/.jus-skills` plus
  per-skill symlinks producing the standard `.agents/skills/<name>/SKILL.md`
  layout — replaces the three contradictory recipes in the README, including
  the retired `git clone … .codex/skills/jus` nested-clone instruction that
  only loaded on tools with recursive skill discovery. (#1972)

### Docs

- README support matrix gains **Kimi Code** (native Agent Skills via
  `.agents/skills/` + `.kimi-code/skills/`; does not read `.claude/skills/`;
  hook adapter tracked by #1977). (#1978)

### Fixed

- `hooks/tests.sh` no longer pins a literal plugin version (the hardcoded
  `1.0.1` assertion broke on the 1.1.0 bump and nothing ran the harness to
  notice): the version is asserted as strict semver, `gemini-extension.json`
  gets shape checks plus a warn-only drift note, and new portability guards
  assert the skill bodies stay free of plugin-namespaced references. (#1973,
  #1975)
- `gemini-extension.json` version synced to `plugin.json` (was stuck at
  0.1.0 since the manifest was introduced). (#1885)

## [1.1.0] — 2026-07-16

### Added

- `LICENSE` (MIT, © Juscribe) and a `license` field on `plugin.json` — the bundle
  is published to a public repo, so it needs an explicit license. (#1705)
- `ticket-workflow` Phase 0 (Prerequisites) + a `hard-rules` preflight line: the
  plugin ships skills + hooks but **not** the `jus` CLI, so the skills now state
  the install/auth prerequisites up front and tell the agent to surface the
  one-line setup step (and stop, not loop) when `jus` is missing/unauthenticated.
  (#1879)
- `ticket-workflow` "Formatting descriptions and comments": descriptions and
  comments render as markdown on the board, so the skill now prescribes the
  form, not just the content — bold section labels (**Root cause:** / **Plan:**
  / **To verify:**), bullets/numbered steps, fenced code blocks, `#N`/`pN`
  refs — with a worked start-comment example. Previously this was an uncaptured
  convention, so public-plugin agents produced unformatted walls of text.
  (#1917)
- `ticket-workflow` "Fleshing out a sparse user-created ticket" + a sharpened
  `hard-rules` bullet: picking up a bare title / one-line ticket now carries an
  explicit duty to add substance — root cause or approach, acceptance criteria,
  test notes — via the append-only description protocol at pickup. The pre-start
  gate alone could previously be satisfied with a token one-liner. (#1921)

### Docs

- README Option H now warns against _also_ marketplace-installing the plugin in
  monumental — the committed copy already loads it, so doing both duplicates the
  skills and double-fires the hooks. (#1705)
- `ticket-workflow` test-command reference: backend coverage is gated on
  `COVERAGE=1 bin/rspec` — a plain run leaves the lcov data stale and
  diff-cover then reports phantom uncovered lines. (#1920)

## [1.0.1] — 2026-06-06

### Fixed

- Pre-commit gate's state-tracked lint rule never fired. `jus-post-bash-tracker.sh`
  read `.tool_response.exit_code` to decide a lint had succeeded, but Claude Code's
  Bash `tool_response` carries no exit status (only `stdout`/`stderr`/`interrupted`/
  `isImage`), so it always defaulted to "failed" and never wrote `last_linted_at`.
  A `git commit` could then only pass by chaining a lint into the commit command,
  and bare `git commit`s in headless dispatches were denied outright (burning
  turns). The tracker now records a lint whenever a recognized lint command runs,
  skipping only an `interrupted` one; lefthook stays the real backstop that re-runs
  the linters at commit time, so a genuinely broken commit is still blocked. (#1873)

## [1.0.0] — 2026-06-05

First distributable release — the plugin is now installable from a standalone
marketplace, not just committed inside the monumental repo.

### Added

- `.claude-plugin/marketplace.json` so the bundle installs via
  `/plugin marketplace add juscribe/jus-skills` → `/plugin install jus@jus-skills`. (#1705)
- `homepage` field on `plugin.json` pointing at the published repo. (#1705)
- This changelog and the versioning strategy above. (#1705)
- Manifest-validation tests in `hooks/tests.sh` (valid JSON, version pinned to
  `plugin.json`, marketplace/plugin name consistency, `source: "./"`). (#1705)

### Notes

- The published `juscribe/jus-skills` repo's root is the contents of `jus/`, so
  `plugin.json` and `marketplace.json` both sit at the repo root's
  `.claude-plugin/` and the plugin `source` is `"./"`.
- Everything that predates 1.0.0 — the two skills, the nine enforcement hooks,
  and the cross-tool manifests — shipped while the bundle was committed-in-repo
  (Option H, #1835); 1.0.0 marks the move to standalone distribution.
