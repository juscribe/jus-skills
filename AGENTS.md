# Juscribe Workflow SOP — agent baseline context

This bundle ships two on-demand Agent Skills that codify the Juscribe ticket-management workflow. Skills auto-invoke when their `description` field matches the user's intent; you can also call them directly. Any tool implementing the [Agent Skills standard](https://agentskills.io) reads the same `SKILL.md` files — OpenAI Codex (CLI / IDE / app), Kimi Code (CLI / VS Code / ACP), Cursor, Windsurf, Zed, Google Antigravity, and Claude Code among them. This file is the shared baseline context for every tool that reads an `AGENTS.md`.

## Skills shipped

- **ticket-workflow** — the single load-bearing skill: every phase of the ticket lifecycle (pickup, investigate, code, commit, self-review, finish, deliver), batch-work rules, the dependency-blocker protocol, **and** the operational reference along the way — estimation (`0/1/2/3/5/8`), ticket types, the 1–3-label rule, metadata conventions, the TDD + per-area testing gates and 100% coverage rule, and the `jus` CLI / API reference (sparse fieldsets, opt-out params, dependencies API, state machine).
- **hard-rules** — non-negotiable behavioral guardrails (commit-immediately, no lint suppression, append-only descriptions, no false deliveries, no `git push`, etc.).

When working on a Juscribe ticket, expect both `ticket-workflow` and `hard-rules` to fire up front. (Earlier `testing-gates`, `juscribe-api`, and `estimation-labels` skills were retired in #1856 — they never reliably auto-invoked; their content now lives inside `ticket-workflow`.)

## What's not bundled here

- **Enforcement hooks** (`hooks/`) ship for Claude Code today. Codex and Kimi Code expose compatible hook systems — per-tool adapters are tracked under #1818. Until your harness runs them, the `hard-rules` skill carries the same rules at the prompt level.
- **`allowed-tools`** in skill frontmatter is a Claude Code allowlist hint — every other tool ignores it.
- **Codex note:** Codex's older "custom prompts" mechanism is deprecated upstream in favor of skills; this bundle does not ship any.
