---
name: retrospective
description: How to run a retrospective on an iteration and hand it over as a self-contained HTML report with charts, then record it back on the board. Covers what to gather (the iteration's own comment log first, then its tickets and their activity), the sections a retrospective owes, hand-authored inline-SVG charts that need no library and no network, verifying derived numbers before you publish, the two ways to deliver the report depending on whether your harness can publish a hosted page, and writing the record back as an iteration comment. Auto-invoke on "retrospective", "retro", "sprint review", "review the iteration", or any request to review or summarize what an iteration delivered.
allowed-tools: Bash(jus *), Bash(git *), Read, Grep, Glob, Write
license: MIT
---

# Retrospective — Review an Iteration and Publish the Report

> Read this when asked to retrospect on an iteration, sprint or cycle. It covers gathering, analysis, charts, verification, delivery and the write-back. The companion `ticket-workflow` skill covers the ticket lifecycle and the `jus` API; this skill assumes it and does not repeat it.

## What you produce: a report and a record

**Two artefacts, and they are not the same document.**

|  |  |
| --- | --- |
| **The report** | One self-contained HTML file. Charts, tables, the full analysis. This is what a person reads. |
| **The record** | A comment on the iteration carrying `context: "retrospective"` — a short lede, the report's address, and the follow-up tickets you filed. This is what the board keeps. |

**The record is short on purpose.** Its job is that the iteration carries a durable trace and something to reply to. If you find yourself restating the analysis in it, stop — you are writing the report twice, and the second copy is the one that goes stale.

⚠️ **NEVER deliver only the record.** A retrospective that fits in a comment is one you did not actually do. The board renders comments as plain markdown with no embedded HTML, so every chart you drew is lost the moment you paste it there.

## Step 1 — Read the iteration's own log FIRST

```
jus api GET '/workspaces/{ws}/iterations/{iteration}/comments'
```

**These are the only first-hand accounts you will get.** Everything else in this skill is reconstruction from timestamps and state changes — what the board recorded. The log is what the people and agents doing the work wrote *while* they were doing it: what was confusing, what was abandoned, what turned out harder than it looked.

**Weigh the log above anything you infer.** Where the two disagree, say so explicitly and give both. "The board shows this accepted on the first pass; the log records two days lost to a wrong assumption before the ticket was opened" is the most valuable sentence a retrospective can contain, and no metric produces it.

⚠️ **AN EMPTY LOG IS NOT A CLEAN ITERATION, AND SAYING SO IS PART OF THE REPORT.** Most boards have never written one. If the log is empty, write one line saying the retrospective is reconstruction only and that testimony was unavailable — then continue. Do **not** quietly omit the section, and never let silence read as "nothing went wrong."

## Step 2 — Gather the iteration

```
jus api GET '/workspaces/{ws}/iterations/{iteration}'
jus api GET '/workspaces/{ws}/tickets?iteration_id={iteration}&per_page=200'
```

The iteration row carries the committed and accepted point totals. The ticket list carries everything else — state, type, points, labels, project, requester, stakeholder, assignees, `rejections_count`, and the timestamps the board exposes.

**Page it.** An iteration can hold a hundred tickets or more; read `pagination.pages` and keep going. A retrospective computed over page 1 is wrong in a way that looks entirely normal.

### Timing comes from the activity feed, not the ticket

**A ticket payload carries very little about when anything happened** — typically its creation and, if the board has one, a single done timestamp. Check what you actually got back before planning around it; boards differ, and a column existing is not the same as a client being able to read it.

**Everything else is in the per-ticket activity feed, and it is richer than it looks:**

```
jus api GET '/workspaces/{ws}/tickets/{ticket}/activities?per_page=100'
```

| Entry | Carries | Gives you |
| --- | --- | --- |
| `state_change` | `{from, to}` + `occurred_at` | every transition in order — cycle time, lead time, dwell in each state, when a rejection happened |
| `create` | the opening `title`, `ticket_type`, `points` | the **first estimate**, which is what estimate drift is measured against |
| `update` | the changed field as `{from, to}` | re-estimates (`points`), retypes, project moves, ownership changes |
| `comment`, `dependency_*`, `attachment_*` | ids and names | how much back-and-forth a ticket took |

⚠️ **`create` plus `update` is how you get estimate drift**, and it is easy to conclude wrongly that it is unavailable. Nothing is named "original points" anywhere in the feed — the opening estimate is a key inside the `create` entry, and every change to it is a separate `update`. Measured on a real iteration: 75 of 102 tickets carried an opening `points` value and 31 re-estimates followed.

⚠️ **A ticket created without an estimate has no opening value to drift from.** That is a real state, not missing data — count those tickets and say how many rather than treating the first later estimate as the original.

⚠️ **It is one request per ticket, so decide before you start.** On a hundred-ticket iteration that is a hundred round trips — measured at about 40 seconds, which is usually worth paying. Either spend them deliberately, or say in the report that timing was computed over a named subset and which one. **Do not silently sample.**

⚠️ **BUCKET DATES IN THE BOARD'S TIMEZONE, NOT THE TIMESTAMP'S.** Timestamps come back in UTC and an
iteration's start and end are local dates, so a ticket filed in the evening lands on the following day if
you compare the raw strings. Measured on the first real run of this skill: 19 of 102 tickets moved to the
next day, turning "90% of this iteration was filed the day it was worked" into a much weaker claim. Nothing
about the wrong answer looks wrong.

⚠️ **A null timestamp means unknown, never zero.** Columns added partway through a board's life are null on every row that predates them. Averaging over them silently pulls the number toward zero and produces a figure that is wrong and plausible — the worst kind. Count the nulls, exclude them, and report how many you excluded.

## Step 3 — What the retrospective owes

Nine sections. **Scale the depth to the iteration, not to this list** — a one-day iteration with four tickets gets a short report, and saying "there is not enough here to retrospect on" is a legitimate finding. A hundred-ticket iteration gets all nine.

0. **The iteration's own notes**, from step 1. Testimony, read first, weighted above inference.
1. **Stats and metrics** — committed vs accepted points, velocity against the rolling average, type distribution, cycle and lead time, rejection rate.
2. **Who participated, and to what extent** — per person: requested, worked, reviewed, accepted. Include agents as participants; they are most of the throughput on some boards.
3. **A recap of what was performed, in logical groupings** — read the tickets, their lifecycles and their back-and-forths, and group by **theme**, not by ticket number. This is the section a reader most wants and the one most often replaced by a list.
4. **Difficulties faced, new issues surfaced, improvements made.**
5. **Where the effort actually went, by kind of work** — user-facing features, bug fixing, performance, internal tooling and plumbing, research, documentation. **In points, not ticket counts**, so it reads as effort rather than volume.
6. **Scope churn and estimate drift** — what entered and left mid-flight, and where the first estimate and the final one diverged.
7. **Rejection anatomy** — not the count, which is section 1, but what the rejections were actually *about*.
8. **Committed vs shipped** — work that is merged but not yet released is not delivered value. If the board tracks releases, say what is sitting behind an unrun one.

   ⚠️ **Split that figure by state before you report it.** A release's list of pending work mixes accepted tickets with ones merely delivered or since cancelled, so a single point total silently overstates what the iteration actually accepted and has not shipped. Give the accepted number as the headline and the rest beside it. Measured on the first real run: 37 points on the marker, of which **25** were accepted — the draft led with 37 and called them accepted.

### ⚠️ Section 5 is the one that gets faked

**Ticket type alone does not answer "where did the effort go", and using it as the answer is the trap.** A feature can be a user-facing capability or an internal developer tool. A chore can be a performance fix, a dependency bump or deployment plumbing.

**Cross three signals:** the ticket type, the labels, and the project the ticket sits under — the project usually carries the intent outright. Where they disagree, the classification is a **judgement**, and the report should show it rather than bury it: name the tickets you were unsure about and say which way you called them.

This is the cut that answers *did we spend the month on what we meant to*, which the type distribution in section 1 cannot.

## Step 4 — Draw the charts

**Hand-authored inline SVG. No chart library, no CDN, no network.**

This is not a stylistic preference. The report has to work as a hosted page **and** as a file opened from disk — a hosted page restricts which hosts it may load from, and a file on a laptop may have no network at all. A library that works in one and fails silently in the other gives you a report with blank rectangles where the analysis was, and nothing warns you.

**If a chart needs a library to be worth drawing, make it a table instead.** A retrospective's charts are bars, columns and a distribution; all three are a dozen lines of SVG.

### Which cuts earn a chart

| Chart | For |
| --- | --- |
| Horizontal bars | Effort by kind of work (section 5), participation (section 2) |
| Column series | Velocity against the preceding iterations |
| Strip or dot plot | Cycle-time distribution — where the tail is, which a mean hides |
| Nothing | Everything else |

**A chart of four values is a table with extra steps.** Committed vs accepted is two numbers; write them large and move on.

### A bar row, complete

```html
<svg viewBox="0 0 600 24" role="img" aria-label="Bug fixing: 34 points, 27% of the iteration">
  <rect x="0" y="4" width="600" height="16" rx="3" fill="var(--track)" />
  <rect x="0" y="4" width="162" height="16" rx="3" fill="var(--accent)" />
  <text x="170" y="16" font-size="12" fill="var(--ink)">Bug fixing — 34 pts (27%)</text>
</svg>
```

**Compute the width yourself** — `width = 600 * value / max` — and round to one decimal. Nothing in the page does arithmetic at render time, which is what makes the numbers checkable in step 5.

⚠️ **Every chart carries its numbers in text as well.** A bar whose value appears only as a length is unreadable when printed, screenshotted small, or read aloud. The `aria-label` is not optional either.

### Colour that survives both themes

Define the palette once as custom properties, then override it for dark. Do not put a colour's only definition inside the media query.

```css
:root {
  --bg: #fbfbf9; --ink: #1c1c1a; --muted: #6b6b66;
  --track: #e7e7e2; --accent: #3b6ea5; --rule: #dcdcd6;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14140f; --ink: #ebebe5; --muted: #9a9a92;
    --track: #2a2a24; --accent: #7aa7d4; --rule: #33332c;
  }
}
body { background: var(--bg); color: var(--ink); }
```

⚠️ **Give `body` an explicit background.** A transparent one borrows whatever is behind the page, and a light report on a dark ground is unreadable in exactly the place you will not test it.

## Step 5 — Verify the numbers before you hand it over

⚠️ **A RETROSPECTIVE COMPUTES, SO LOOKING AT IT IS NOT CHECKING IT.** A wrong figure in a report is worse than no report: it is quotable, it gets carried into the next planning conversation, and nothing downstream will ever re-derive it.

**Check these five, every time. They are the ones that go wrong:**

1. **The parts sum to the whole.** Effort by kind of work must total the iteration's points. If it does not, some tickets fell out of your classification — find them and add an "unclassified" row rather than letting the shortfall hide.
2. **Percentages total 100**, allowing for rounding, and say which way you rounded.
3. **Every bar's width is proportional to its value, on the SAME scale as its own axis.** Recompute one by hand from the rendered `width` and compare — then check that the axis labels use that scale too. The failure that actually happens is a chart whose bars were sized from the largest value and whose axis was labelled from a round number: every bar is proportional to every other bar, so it looks right, and every one is in the wrong place against the gridline.
4. **Counts agree with the source.** Your ticket total must equal what the API reported in `pagination.count`. A mismatch means you missed a page.
5. **Excluded rows are declared.** Nulls, cancelled tickets, tickets that moved out mid-iteration — every exclusion appears in the report with its count.

**Do it by re-deriving, not by re-reading.** Recompute a figure from the raw list in a scratch calculation and compare it to what the page says. Two independent paths to the same number is the check; reading the number twice is not.

## Step 6 — Deliver the report

**One document, two possible addresses.** Which one you use depends on your harness, not on the report.

**Where the harness can publish a hosted page** — Claude Code can, through its Artifact tool — publish it and use that URL as the report's address.

**Where it cannot** — most installs, including Codex, Cursor, Zed, Windsurf and Antigravity today — **write the file into the project and hand over its path.** Put it somewhere the project keeps generated documents; if the project has no such convention, ask rather than inventing a directory. Say plainly in the handover that it is a local file.

⚠️ **Never fake the first with the second.** If you cannot publish, say so in one clause and give the path. An agent that improvises a link is worse than one that hands over a file.

⚠️ **Publishing sends the iteration's contents to a hosted page.** Ticket titles, participant names, whatever the log says about how the work went. **Say so before you publish, not after** — and never publish a board you were not asked to retrospect.

## Step 7 — Write the record back

```
jus api POST '/workspaces/{ws}/iterations/{iteration}/comments' '{"comment":{"body":"…","context":"retrospective"}}'
```

`context` is what marks this comment as the retrospective rather than a note, and the board uses it to render the entry differently. **Set it. Nothing else will.**

**The body is short, and it is exactly four things:**

1. One paragraph: what the iteration delivered and the single thing most worth knowing.
2. The report's address.
3. The follow-up tickets you filed, by id.
4. Anything you could not compute, and why.

### Re-running replaces; it does not append

**A second retrospective comment on the same iteration is wrong.** Find the existing one and update it:

```
jus api PATCH '/workspaces/{ws}/iterations/{iteration}/comments/{comment}' '{"comment":{"body":"…"}}'
```

The body is versioned, so the previous text survives. If you publish the report to the same location, its address does not change either, and the record stays correct without being touched.

## Step 8 — File the follow-ups

A retrospective that surfaces nothing to do is a summary. **File the tickets** — documentation gaps, refactors, tech debt, process fixes — under the normal rules in `ticket-workflow`: a description and an estimate on each, at the bottom of the backlog unless one is genuinely urgent.

**Name them by id in both the report and the record.** A finding with no ticket is a finding nobody acts on, and a ticket the report does not name is one nobody connects back to why it exists.

⚠️ **Do not file a ticket per observation.** Group them. Five tickets that all say "the log was empty" is noise; one that says "nothing prompts anyone to write iteration notes" is the finding.

## Reflexes

| If | Then |
| --- | --- |
| The log is empty | Say so in the report. Do not omit section 0 |
| A timestamp is missing from the payload | Fall back to the activity feed, and say what it cost |
| A metric needs a null-heavy column | Count the nulls, exclude them, report the count |
| The classification is ambiguous | Show the judgement and name the tickets |
| A chart needs a library | Make it a table |
| You cannot publish a hosted page | Write the file, hand over the path, say which it is |
| You already ran this iteration | Update the existing comment, never post a second |
| The iteration is tiny | Write a short report and say it is short |

## Related skills

- **`ticket-workflow`** — the lifecycle, estimation, labels and the `jus` CLI / API reference. Filing the follow-ups in step 8 follows it.
- **`hard-rules`** — the non-negotiable guardrails, including the rule that every piece of work has a ticket.
