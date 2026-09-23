# Juscribe Workflow SOP — Gemini CLI, Code Assist and Qwen Code

This extension bundles three on-demand Agent Skills that codify the Juscribe ticket-management workflow. Skills auto-invoke when their `description` field matches the user's intent; you can also call them directly. Works in both Gemini CLI sessions and Gemini Code Assist (VS Code / IntelliJ) agent-mode chat panels — the same `gemini extensions install` path covers both. Qwen Code installs it as well, with `qwen extensions install https://github.com/juscribe/jus-skills:jus`, and names the skills `jus:<name>`.

## Skills shipped

- **ticket-workflow** — the single load-bearing skill: every phase of the ticket lifecycle (pickup, investigate, code, commit, self-review, finish, deliver), batch-work rules, the dependency-blocker protocol, **and** the operational reference along the way — estimation (`0/1/2/3/5/8`), ticket types, the 1–3-label rule, metadata conventions, the testing obligations and per-area gates (with the ordering and the coverage bar left to the installing project), and the `jus` CLI / API reference (sparse fieldsets, opt-out params, dependencies API, state machine).
- **hard-rules** — non-negotiable behavioral guardrails (commit-immediately, no lint suppression, append-only descriptions, no false deliveries, no `git push`, etc.).
- **retrospective** — how to review an iteration and hand it over as a self-contained HTML report with charts: what to gather (the iteration's own comment log first), the sections a retrospective owes, inline-SVG charts that need no library and no network, verifying derived numbers before publishing, and writing the record back as an iteration comment.

When working on a Juscribe ticket, expect both `ticket-workflow` and `hard-rules` to fire up front; `retrospective` fires only when an iteration review is asked for. (Earlier `testing-gates`, `juscribe-api`, and `estimation-labels` skills were retired in #1856 — they never reliably auto-invoked; their content now lives inside `ticket-workflow`.)

## What's not bundled here

- **Hooks** ship per tool. In Qwen Code this extension registers `hooks/qwen/` itself, through `qwen-extension.json`. Gemini CLI reads an extension's hooks only from `hooks/hooks.json`, which is Claude Code's file, so there the hooks under `hooks/gemini/` install separately into `settings.json`: `jus init` offers them. Until they are installed, the skill prompts in `hard-rules` cover the same intent on a best-effort basis.
- **`allowed-tools`** in skill frontmatter is a Claude Code allowlist hint — Gemini CLI and Qwen Code ignore it.
