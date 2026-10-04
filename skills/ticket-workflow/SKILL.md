---
name: ticket-workflow
description: The single load-bearing Juscribe SOP skill — the full ticket lifecycle from pickup to delivery, plus estimation, ticket types, labels, metadata, testing gates, and the complete `jus` CLI / API reference in bundled files this skill points at. Use when working any ticket — picking one up, transitioning state, investigating, sizing, labeling, writing tests, running pre-commit gates, calling `jus api`, committing, self-reviewing, finishing, delivering, handling rejections, processing batches, or resolving dependency blockers. Auto-invoke whenever a ticket ID (`#N`) or "work on this ticket" / "pick up backlog" / "deliver" / "rejected" appears. In a project wired to Juscribe (a `.jus/` directory or the `jus` CLI), bare ticket language — `#42`, the board, the backlog, deliver — means Juscribe tickets by default, unless the wording names another system (a PR, a GitHub issue, another tracker's key), so this skill is the one to invoke for them.
allowed-tools: Bash(jus *), Bash(git *), Bash(make *), Bash(cd *), Read, Grep, Glob, Edit, Write
license: MIT
---

# Ticket Workflow — Juscribe Lifecycle SOP

> **This skill and `.jus/SOP.md` overlap deliberately.** `jus init` appends that file to your AI context so a project with no plugin still has an SOP. This skill covers the same lifecycle in more depth and is kept more current: where the two differ, this one wins.
>
> Read it when working any ticket. It is the **single load-bearing skill** for Juscribe work. This file is the order of the lifecycle and, at each step, the reference file to open before it. What each step requires sits in that file, and so do the `jus` API, estimation, types, dependencies, subtasks and conversion: none of it costs anything until you open it. The companion [`hard-rules`](#related-skills) skill carries the must/must-not. Harnesses that run the jus hooks enforce the worst of those deterministically; everywhere else they are prompt-level only.

The lifecycle, in one line:

```
(1) create or pick up → (2) start → (3) investigate → (3b) apply labels → (4) code → (5) commit → (6) self-review → (7) finish
```

**Finishing is your last transition.** Deliver only when a person asks for it; Phase 6 says why.

Every change goes through every phase, however small or ad-hoc. Transition at the natural moment, never in a batch, so the board shows reality. **NEVER transition to `accepted` or `rejected`** — only the stakeholder decides. The one exception is a chat app on Juscribe's hosted connector: when the person explicitly asks you to accept or reject a ticket, record their decision with `accept_ticket` or `reject_ticket`, and never on your own judgement.

## Phase 0: Prerequisites — the `jus` CLI must be installed and authenticated

This SOP drives the board through the **`jus` CLI**, which the bundle does not install: the user needs `brew install juscribe/tap/jus`, then `jus login` or `jus init` (which also sets the `{ws}` used throughout this skill). **When a `jus` command fails before it reaches the board, open [references/setup.md](references/setup.md).** A missing CLI, a missing token, a retired token and an unreachable server each have a different fix, and only one of them is a rotation. `jus doctor` checks that these skills loaded, which `jus whoami` cannot.

**Do not loop `jus` commands against an unconfigured CLI, or against a 401.** Surface the one setup step the error points to, and stop.

**No shell, but Juscribe's MCP tools are connected?** That is a chat app, or any AI tool with the Juscribe connector and no terminal. Use the tools: each recipe in these files is followed by an **MCP:** line naming the tool that does the same job, or saying none does and what to do instead. Every board rule here still applies. The commit, lint, test, branch and git steps do not, since there is no repository. **Never tell a chat user to install Homebrew or the CLI.**

## Each step, and the file to open before it

⚠️ **This file holds the order, not the steps.** What a step requires is in the file named at it, and nothing here repeats it. Open that file at the moment it names, not earlier and not from memory of another ticket.

### Phase 1–2: Pick up and start

**Before your first `jus` call on the ticket, open [references/pickup.md](references/pickup.md).** It carries the fetch, the checks before `started`, and the lock itself, which comes before you read any source file.

### Phase 3: Investigation & Labels

**Right after the `started` transition, before you read the codebase, open [references/investigating.md](references/investigating.md)** — how far to investigate, the labels that go on before any code, the start comment that must come before your first edit, the tests that ship with the change, and how every comment and description is written on the board.

### Phase 4: Coding

**Before each `git commit` on the ticket, open [references/committing.md](references/committing.md)** — when to commit, and the form that links the commit to the ticket.

### Phase 5: Self-Review

**Right after each commit, open [references/self-review.md](references/self-review.md)**, before you comment, transition or reply — the checks that run after a commit, the coverage of the diff, and a second client.

### Phase 6: Finish

**Before the `finished` transition, open [references/delivering.md](references/delivering.md)** — before you tick a box or write the delivery comment, not after. It carries the pre-delivery gate, the boxes, the delivery comment and its form, the one transition call, and what closing a project involves.

⚠️ **Delivering is the phase most often done from memory, and memory asks the wrong question.** The gate is not "is the code good" but "does this differ from what the ticket says", and only the file asks the second.

**Tick the boxes you met, before the delivery comment and the `finished` call.** Fetch the description, change `- [ ]` to `- [x]` on each acceptance criterion you met, and PATCH it back with the stakeholder's words otherwise verbatim. Tick only what you can answer one question for: **what evidence would I cite?** An unmet box means do not finish — leave it unticked and the ticket in `started`. The commands are in [Then tick the boxes you met](references/delivering.md#then-tick-the-boxes-you-met).

## At any step

| Read | Before |
| --- | --- |
| [references/api.md](references/api.md) | Constructing **any** `jus api` call. A wrong request shape hangs, no-ops or returns a bare 500 rather than an error, and the response envelope is not the JSON root. |
| [references/api-writes.md](references/api-writes.md) | Creating a ticket anywhere but the bottom of the icebox, or changing many at once. Placement belongs in the create, and a bulk call reports failure per item. |
| [references/api-queries.md](references/api-queries.md) | Listing or filtering tickets. The index refuses a filter name it does not know, and leaves markers out unless asked. |
| [references/estimation-and-types.md](references/estimation-and-types.md) | Sizing, typing or labelling a ticket, or filling in a sparse one. Also the pre-start metadata gate and the placement rules for a new ticket. |
| [references/dependencies.md](references/dependencies.md) | Recording that a ticket is blocked. One blocker per independently-clearing condition, and editing one means setting **both** `title` and `description`. |
| [references/subtasks.md](references/subtasks.md) | Writing steps someone performs. Steps are subtasks, never description checkboxes, and `completed` is not `/toggle`. |
| [references/converting.md](references/converting.md) | Converting a ticket to a project, or wondering whether a retype is what you actually want. Only a `research` ticket can be converted. |
| [references/formatting.md](references/formatting.md) | Putting a fence inside a list, or reading the reactions on a comment. The fence trap looks correct in the source. |
| [references/second-client.md](references/second-client.md) | Delivering a ticket that touches a second client — a mobile app, a CLI, a public API. Passing tests do not cover it. |
| [references/setup.md](references/setup.md) | A `jus` command failing before it reaches the board, or skills that seem not to have loaded. Each failure has a different fix. |
| [references/states.md](references/states.md) | Any transition other than `started` or `finished`, or one that was refused. A transition steps one state at a time, and cancelling needs a resolution. |

⚠️ **A pointer is not the content.** About to write a `jus api` call, a dependency, a subtask or a delivery comment? Open the file. Answering from this table is how a wrong request shape ships.

## Related Skills

- `hard-rules` — the non-negotiable must/must-not that overrides everything here (commit immediately, no lint suppression, stakeholder-verbatim descriptions, never deliver incomplete work, no `git push`, document discoveries), and which of them the enforcement hooks back deterministically. Where a plugin install prefixes skill names with `jus:`, invoke the prefixed form.
