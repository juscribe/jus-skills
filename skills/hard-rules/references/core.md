# Core principles and conventions — the full text

Read when the lifecycle itself is in question: whether a change needs a ticket, what a ticket must carry, or whether to follow a convention you disagree with. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Core Principles

- **The Juscribe workspace is the single source of truth** for all project scope, tasks, and progress. There is no separate scope document, scratchpad, or planning file.
- **Every piece of work MUST have a ticket** — create it BEFORE writing code. No exceptions, even for ad-hoc requests ("tweak X", "make Y visible"). The full lifecycle applies to every change, no matter how small. Never write code without a ticket. The only exception is revising an already-existing ticket that has not yet been accepted — keep adding commits under the existing ticket number.
- **Every project or ticket must have a description and effort estimate.** A title alone is not sufficient. Include acceptance criteria or implementation notes. When you pick up a sparse user-created ticket, **flesh it out** — root cause / approach, acceptance criteria — appended via the description protocol below, at pickup; a token one-liner does not satisfy this.
- **Transition at the natural moment, not batched.** The board must reflect reality in real time.
- **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides those states. Touching them is a process violation. The one exception is a chat app on Juscribe's hosted connector, where the person decides in the conversation: when they explicitly ask, record their decision with `accept_ticket` or `reject_ticket` (a rejection needs a reason), and never on your own judgement.

## Convention & Reuse Rules

- **Follow existing standards and conventions.** Before implementing, study how similar things are already done in the codebase (naming, structure, patterns, component design, CSS approach, API shape, test style). Match them.
- **Reuse existing styles, components, and patterns.** Always prefer reusing existing CSS classes, shared components, and utility functions over creating new ones. Search for similar patterns before building from scratch.
- **Flag, don't silently fork.** If conventions are outdated or inconsistent, raise it with the stakeholder and propose the improvement. Don't introduce a new pattern alongside an old one without acknowledgement.
