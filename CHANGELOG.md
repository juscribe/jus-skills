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

| Bump      | When                                                                                                           |
| --------- | -------------------------------------------------------------------------------------------------------------- |
| **MAJOR** | Breaking change to the behavioral contract — a skill removed/renamed, a hook's block semantics changed, the lifecycle reshaped, or anything that would make an existing setup behave differently in a non-additive way. |
| **MINOR** | Backwards-compatible additions — a new skill or hook, a new rule, a new lifecycle phase, expanded reference material. |
| **PATCH** | Clarifications and fixes that don't change behavior — wording, typos, doc polish, a hook bug fix that only makes it match its documented intent. |

Each release entry below should name the SOP change and, where relevant, the
Juscribe ticket (`#N`) that introduced it.

## [Unreleased]

### Added

- `LICENSE` (MIT, © Juscribe) and a `license` field on `plugin.json` — the bundle
  is published to a public repo, so it needs an explicit license. (#1705)

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
