---
name: retrospective
description: How to run a retrospective on an iteration and hand it over as a self-contained HTML report with charts, then record it back on the board. Covers what to gather (the first-hand accounts first — the iteration's thread and the ticket comments that hold most of them — then the tickets and their activity), the sections a retrospective owes, hand-authored inline-SVG charts that need no library and no network, verifying derived numbers before you publish, sending the report's own HTML to the board so the iteration's details pane can show it, and writing the record back as an iteration comment. Auto-invoke on "retrospective", "retro", "sprint review", "review the iteration", or any request to review or summarize what an iteration delivered.
allowed-tools: Bash(jus *), Bash(git *), Read, Grep, Glob, Write
license: MIT
---

# Retrospective — Review an Iteration and Publish the Report

> Read this when asked to retrospect on an iteration, sprint or cycle. It covers gathering, analysis, charts, verification, delivery and the write-back. The companion `ticket-workflow` skill covers the ticket lifecycle and the `jus` API; this skill assumes it and does not repeat it.

## What you produce: a report and a record

**Two artefacts, and they are not the same document.**

|  |  |
| --- | --- |
| **The report** | One self-contained HTML file. Charts, tables, the full analysis. This is what a person reads, and you send it to the board, which stores and serves it. |
| **The record** | A comment on the iteration carrying `context: "retrospective"` — a short lede, where the report is, and the follow-up tickets you filed. This is what the board keeps. |

**The record is short on purpose.** Its job is that the iteration carries a durable trace and something to reply to. If you find yourself restating the analysis in it, stop — you are writing the report twice, and the second copy is the one that goes stale.

⚠️ **NEVER deliver only the record.** A retrospective that fits in a comment is one you did not actually do. The board renders comments as plain markdown with no embedded HTML, so every chart you drew is lost the moment you paste it there.

## Step 1 — Read the first-hand accounts FIRST, and look on the TICKETS

```
jus api GET '/workspaces/{ws}/iterations/{iteration}/comments'
```

That is the iteration's own thread. On most boards it is **empty, or holds only the records of previous retrospectives** — measured on one board, one comment across 196 iterations, and it was a retrospective record. Read it, then keep going. The testimony is real; it is written one level down.

```
jus api GET '/workspaces/{ws}/tickets?iteration_id={iteration}&per_page=200&include_markers=true&include_comments=true&include_label_objects=false'
```

⚠️ **`include_comments=true` IS WHAT TURNS THE TICKET LIST INTO THE LOG.** Without it the same request returns comment *counts*, which is a measure of back-and-forth and not a word of what anyone said. Where a workflow asks for a comment when work starts and another when it is delivered, every ticket carries a first-hand account of itself — the plan, what it assumed, what turned out to be wrong. Measured on a 112-ticket iteration: **252 comments on 102 of the 112 tickets**, median 2,940 characters, **78 tickets carrying language about a retry, a wrong assumption or a reversal.**

⚠️ **DO NOT READ THE WHOLE CORPUS.** That same fetch was **793,576 characters — roughly 198,000 tokens**, arriving as one 1.03 MB payload in 0.75 s. One request is cheap; reading all of it is not, and a retrospective that tries will run out of room before it reaches the charts. Fetch once, then slice.

**Two slices pay for themselves:**

| Slice | What it gives you | Cost, measured |
| --- | --- | --- |
| Comments **not written by a bot** — `select(.user.bot \| not)` | On an agent-run board this is the whole human record: bug reports from a real device, scope corrections, "we don't need that here" | **7 comments, 1,814 characters** |
| The tickets the report will actually discuss — every `rejections_count > 0`, the longest cycle times, the re-estimates | Where "it was the third attempt" is actually written. Section 7 already requires these | a handful |

```
jq '[.tickets[] | {id, title, comments: [.comments[] | select(.user.bot | not) | {created_at, body}]}] | map(select(.comments | length > 0))'
```

**Weigh testimony above anything you infer.** Where the two disagree, say so explicitly and give both. "The board shows this accepted on the first pass; the comments record two days lost to a wrong assumption before the ticket was opened" is the most valuable sentence a retrospective can contain, and no metric produces it.

⚠️ **THE ITERATION BOUNDARY DOES NOT BOUND THE CONVERSATION.** A ticket belongs to the iteration it was **accepted** in, not the one it was worked in, so its comments spill either side of the dates. Measured on a one-day iteration: 4 comments written before it, 178 on the day, and **70 the day after**. Do not date-filter the comments to the iteration's own dates — you would discard 28% of the record, and the discarded part is the end of every story.

⚠️ **AN EMPTY ITERATION THREAD IS THE NORMAL CASE, NOT A FINDING.** Say in one line which source the testimony came from, and report testimony as *missing* only when the tickets are silent too. **Do not file a ticket saying nobody writes iteration notes** — that was filed, measured and decided against: with one-day iterations and up to ten tickets in flight inside half an hour across concurrent sessions, nobody has the vantage point to write "how the iteration went", so per-ticket is the granularity and the iteration thread is for the record.

## Step 2 — Gather the iteration

```
jus api GET '/workspaces/{ws}/iterations/{iteration}'
jus api GET '/workspaces/{ws}/tickets?iteration_id={iteration}&per_page=200&include_markers=true'
```

The iteration row carries the committed and accepted point totals. The ticket list carries everything else — state, type, points, labels, project, requester, stakeholder, assignees, `rejections_count`, and the timestamps the board exposes.

⚠️ **`include_markers=true` IS LOAD-BEARING.** The ticket index drops release, milestone and deadline markers by default, and `pagination.count` reports the reduced number — it describes the rows the filter let through, so it is internally consistent with the thinned page you were handed and every check you can run on the list passes. Measured on a real iteration: **102 without the flag, 112 with it.**

**The ten it dropped were the release markers**, which is precisely the population section 8 exists to examine — so the query is blind in the one place the analysis has to look. A retrospective run without the flag is not slightly incomplete; it is confidently wrong about what shipped.

⚠️ **`.meta.excluded_markers` answers this directly, WHERE THE SERVER HAS IT.** Newer Juscribe returns it on every ticket index — always present, `0` when nothing was withheld, so a zero is an answer rather than a silence. Read it and you know at once:

```
jus api GET '/workspaces/{ws}/tickets?iteration_id={iteration}&per_page=200' | jq '.meta.excluded_markers'
```

**An older server has no `meta` key at all**, and `jq` answers `null` — which reads exactly like "nothing was withheld" and is not. So do not treat its absence as reassurance; that is what check 5 in step 5 is for, and that check works against every version.

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

0. **The first-hand accounts**, from step 1. Testimony, read first, weighted above inference — and say which source it came from, because on most boards it is the ticket comments rather than the iteration thread.
1. **Stats and metrics** — committed vs accepted points, velocity against the rolling average, type distribution, cycle and lead time, rejection rate. ⚠️ **The rejection rate is not ready until section 7 has been written** — see there. Report the raw event count here only if you say it is raw.
2. **Who participated, and to what extent** — per person: requested, worked, reviewed, accepted. Include agents as participants; they are most of the throughput on some boards.
3. **A recap of what was performed, in logical groupings** — read the tickets, their lifecycles and their back-and-forths, and group by **theme**, not by ticket number. This is the section a reader most wants and the one most often replaced by a list.
4. **Difficulties faced, new issues surfaced, improvements made.**
5. **Where the effort actually went, by kind of work** — user-facing features, bug fixing, performance, internal tooling and plumbing, research, documentation. **In points, not ticket counts**, so it reads as effort rather than volume.
6. **Scope churn and estimate drift** — what entered and left mid-flight, and where the first estimate and the final one diverged.
7. **Rejection anatomy** — not the count, which is section 1, but what the rejections were actually *about*.

   ⚠️ **CLASSIFY THE EVENTS BEFORE ANY RATE IS REPORTED, AND FIX SECTION 1 AFTERWARDS.** A rejection count is not a rejection rate: `rejections_count` tallies transitions, and several of them are not the thing the number is read as meaning. **Read each one** — the ticket's comments and its activity feed — and split them:

   | Looks like a rejection | Is it? |
   | --- | --- |
   | Work sent back because it was wrong or incomplete | **Yes.** This is the population a rate is about |
   | A reject-and-redeliver minutes apart, to exercise the fix under test | No. That is a verification step wearing a state change |
   | An agent re-opening its own work before anyone reviewed it | No. Nobody rejected anything |

   Measured on a real iteration: **5 events across 4 tickets, of which 3 were real and sat on 2 tickets.** Reported raw, the rate is nearly double. Give the classified figure, say how many events you excluded and why, and name the tickets — the reader can then disagree with your calls, which they cannot do with a bare number.
8. **Committed vs shipped** — work that is merged but not yet released is not delivered value. If the board tracks releases, say what is sitting behind an unrun one.

   ⚠️ **Split that figure by state before you report it.** A release's list of pending work mixes accepted tickets with ones merely delivered or since cancelled, so a single point total silently overstates what the iteration actually accepted and has not shipped. Give the accepted number as the headline and the rest beside it. Measured on the first real run: 37 points on the marker, of which **25** were accepted — the draft led with 37 and called them accepted.

### ⚠️ A RANK CLAIM IS COMPUTED OVER EVERY ITERATION, NOT THE ONES YOU FETCHED

**"The second-best iteration on the board" is a claim about the whole series**, and the reflex is to rank against whatever window happened to be in front of you — the rolling velocity average, the last dozen columns of your own chart, the page the API returned. That window is chosen for a chart's legibility, and it is not the population the sentence describes.

```
jus api GET '/workspaces/{ws}/iterations'
```

**Rank over all of it, and name the ones above.** Measured on a real run: an iteration called "the second-highest on the board" was **4th of 196**, and the three above it were nowhere near the fetched window. Nothing about the wrong claim looked wrong, and a superlative is the sentence a reader is most likely to repeat.

⚠️ **Say which metric the rank is over.** Accepted points, tickets done and committed points give different orders, and a rank with no named metric cannot be checked by anyone.

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

**Check these six, every time. They are the ones that go wrong:**

1. **The parts sum to the whole.** Effort by kind of work must total the iteration's points. If it does not, some tickets fell out of your classification — find them and add an "unclassified" row rather than letting the shortfall hide.
2. **Percentages total 100**, allowing for rounding, and say which way you rounded.
3. **Every bar's width is proportional to its value, on the SAME scale as its own axis.** Recompute one by hand from the rendered `width` and compare — then check that the axis labels use that scale too. The failure that actually happens is a chart whose bars were sized from the largest value and whose axis was labelled from a round number: every bar is proportional to every other bar, so it looks right, and every one is in the wrong place against the gridline.
4. **Counts agree with the source.** Your ticket total must equal what the API reported in `pagination.count`. A mismatch means you missed a page.
5. **The list agrees with the ITERATION ROW, which is a second source.** ⚠️ Check 4 alone cannot catch a filtered list — `pagination.count` describes the rows the filter let through, so it agrees with itself no matter what was withheld. The iteration's own `done_tickets_count` counts accepted and cancelled tickets **including markers**, and is computed by a different query, so compare the two: **your list must not be smaller than it.** A list of 102 under a `done_tickets_count` of 106 is the tell. Where the server returns `.meta.excluded_markers` (step 2) that says it outright, but this check needs no particular server version, so run it either way. If your list is smaller, re-fetch with `include_markers=true` before going any further.
6. **Excluded rows are declared.** Nulls, cancelled tickets, tickets that moved out mid-iteration — every exclusion appears in the report with its count.

**Do it by re-deriving, not by re-reading.** Recompute a figure from the raw list in a scratch calculation and compare it to what the page says. Two independent paths to the same number is the check; reading the number twice is not.

## Step 6 — Deliver the report to the board

**Send the file's contents. The board stores the document and serves it back**, which is what lets the iteration's details pane show the report instead of merely linking to it.

```
jq -Rs '{retrospective:{html:.}}' <report.html> | jus api PATCH '/workspaces/{ws}/iterations/{iteration}/retrospective'
```

⚠️ **Do not try to inline the document into the command.** It is an HTML file full of quotes, backticks and apostrophes — the two characters that break shell quoting — and tens of kilobytes long. `jq -Rs` reads the file as one JSON string and `jus api` takes the object on stdin, so there is nothing to escape by hand.

**The body is bounded and the endpoint says so.** Over the limit is a `422` naming the size; nothing is truncated and nothing is stored. If a report is genuinely that big, the charts are carrying embedded images they should not be.

### Publishing a hosted copy is optional, and it is not the record

**Where your harness can publish a hosted page** — Claude Code can, through its Artifact tool — publishing gives a reader a nicer viewer, and you record its address alongside the body:

```
jq -Rs --arg url '<address>' '{retrospective:{html:.,url:$url}}' <report.html> | jus api PATCH '/workspaces/{ws}/iterations/{iteration}/retrospective'
```

**Where it cannot** — Codex, Cursor, Zed, Windsurf and Antigravity today — send the body alone. Nothing is missing: the board holds the report either way.

⚠️ **A hosted page is not a substitute for the body, and this is the trap the step exists for.** Hosted documents are commonly private to whoever they were shared with, and commonly refuse to be embedded — Claude's artifacts answer `frame-ancestors 'self'`, so a link to one opens nothing for a colleague and frames nowhere at all. Sending only a `url` leaves the board with an address it cannot show and most readers cannot open.

⚠️ **Never improvise an address you did not publish.** If you cannot publish, say so in one clause and send the body.

⚠️ **Publishing sends the iteration's contents to a hosted page.** Ticket titles, participant names, and anything you quoted from the testimony — which since step 1 includes ticket comments, and the human-authored ones are the likeliest to name a person, a device or an opinion. **Say so before you publish, not after** — and never publish a board you were not asked to retrospect.

### The report is served under a strict policy — write it accordingly

The board serves your document from its own origin, in a sandbox that permits its own `<style>`, one Google Fonts stylesheet and `data:` images, and nothing else. **Script never runs.** So:

- Inline SVG charts, as step 4 already says. Nothing to load, nothing to execute.
- No `<script>`, no interactivity, no analytics.
- No remote images or stylesheets beyond the font link. Embed anything you need as a `data:` URI.

A report that ignores this is not rejected — it renders with the offending parts silently inert, which is the worse outcome. Write it self-contained and the question does not arise.

## Step 7 — Write the record back

```
jus api POST '/workspaces/{ws}/iterations/{iteration}/comments' '{"comment":{"body":"…","context":"retrospective"}}'
```

`context` is what marks this comment as the retrospective rather than a note, and the board uses it to render the entry differently. **Set it. Nothing else will.**

**The body is short, and it is exactly four things:**

1. One paragraph: what the iteration delivered and the single thing most worth knowing.
2. Where the report is — the board serves it from the iteration's details pane, so say that, and give the hosted address too if you published one.
3. The follow-up tickets you filed, by id.
4. Anything you could not compute, and why.

### Re-running replaces; it does not append

**A second retrospective comment on the same iteration is wrong.** Find the existing one and update it:

```
jus api PATCH '/workspaces/{ws}/iterations/{iteration}/comments/{comment}' '{"comment":{"body":"…"}}'
```

The body is versioned, so the previous text survives. **Re-sending the report replaces it too** — the board keeps one per iteration — so the record stays correct without being touched.

## Step 8 — File the follow-ups

A retrospective that surfaces nothing to do is a summary. **File the tickets** — documentation gaps, refactors, tech debt, process fixes — under the normal rules in `ticket-workflow`: a description and an estimate on each, at the bottom of the backlog unless one is genuinely urgent.

**Name them by id in both the report and the record.** A finding with no ticket is a finding nobody acts on, and a ticket the report does not name is one nobody connects back to why it exists.

⚠️ **Do not file a ticket per observation.** Group them. Five tickets that all say "this doc was out of date" is noise; one that says "the reference and the code have no guard holding them together" is the finding.

## Reflexes

| If | Then |
| --- | --- |
| The iteration thread is empty | Normal. Take the testimony from the ticket comments and say in section 0 that you did |
| The ticket comments are empty too | *Now* it is a finding. Say the report is reconstruction only |
| The comment corpus is enormous | Expected — slice it. Human-authored first, then the tickets the report discusses |
| Your ticket list is smaller than `done_tickets_count` | You are missing the markers. Re-fetch with `include_markers=true` |
| `.meta.excluded_markers` came back `null` | The server predates it. That is not a zero — run check 5 |
| You are about to write "best", "second-highest", "worst" | Rank over every iteration, name the metric, name the ones above |
| You have a `rejections_count` | Read each event and classify it before reporting a rate |
| A timestamp is missing from the payload | Fall back to the activity feed, and say what it cost |
| A metric needs a null-heavy column | Count the nulls, exclude them, report the count |
| The classification is ambiguous | Show the judgement and name the tickets |
| A chart needs a library | Make it a table |
| You cannot publish a hosted page | Send the body anyway — the board serves it. Say you did not publish |
| You already ran this iteration | Update the existing comment, never post a second |
| The iteration is tiny | Write a short report and say it is short |

## Related skills

- **`ticket-workflow`** — the lifecycle, estimation, labels and the `jus` CLI / API reference. Filing the follow-ups in step 8 follows it.
- **`hard-rules`** — the non-negotiable guardrails, including the rule that every piece of work has a ticket.
