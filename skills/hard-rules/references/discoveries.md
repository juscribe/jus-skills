# Document discoveries — the full text

Read when you hit an error, find a workaround or learn something non-obvious. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Document Discoveries

> When you encounter a gotcha, workaround, error, or non-obvious learning during development — document it IMMEDIATELY, don't wait to be asked. Undocumented learnings are lost learnings.

The triggers are: any time you hit an error, find a workaround, or learn something non-obvious about a tool/system/convention. Treat documentation with the same urgency as committing code.

Where to write it (use all that apply):

- **In ticket comments** — capture troubleshooting steps, errors, and fixes in the ticket thread AS THEY HAPPEN. Don't accumulate; document each problem and its solution as you go.
- **In `.jus/docs/`** — for patterns, errors, and fixes that will recur across tickets. If a relevant doc exists, update it. If not, create a new one and add it to `.jus/docs/INDEX.md`.
- **In code comments** — when you decode how a system works (animation flow, state pattern, WebSocket dance), leave explanatory comments in the source. Focus on "why" and "how the pieces connect", not obvious "what". The code is the best place for institutional knowledge.
- **In your agent's context file** (`CLAUDE.md`, `AGENTS.md`, or your tool's equivalent) — for patterns that span multiple files or sessions and inform future agent behavior.

A discovery missed once is a learning lost; a discovery missed across a session is a recurring failure.

**Read before you re-derive.** The docs directory is only worth writing to if it gets read: before debugging or extending a subsystem, check `.jus/docs/INDEX.md` for a doc whose "when to read" hint matches your task — a documented gotcha you re-derive from scratch is time somebody already spent for you, and that failure has been measured (a deployment trap re-diagnosed from zero fifteen hours after being written up). Projects can automate the reminder: the `jus-docs-nudge.sh` hook surfaces the right doc at ticket pickup (for `label:`/`kw:` rows matching the started ticket's labels or title — the moment the information can still change the plan) and on the first edit under any path mapped in the project's `.jus/docs-nudges.tsv`.

**Route shared-relevance knowledge to the shared docs, not private memory.** Per-user auto-memory is invisible to every other agent and every dispatched/sandboxed session — a gotcha recorded only there converts into a future re-discovery by someone else. Memory is for _personal workflow_; anything another agent could trip over belongs in `.jus/docs/` with an `INDEX.md` line.
