---
name: retrospective
description: How to run a retrospective on an iteration and hand it over as a self-contained HTML report with charts, then record it back on the board. Covers what to gather (the first-hand accounts first — the ticket comments that hold most of them — then the tickets, their activity and the board's timezone), the sections a retrospective owes and the ones it must stop writing, when in the day work actually happened, production health and standing technical debt, drawing conclusions rather than counting metrics, hand-authored inline-SVG charts that need no library and no network, verifying derived numbers before you publish, sending the report's own HTML to the board so the iteration's details pane can show it, and writing the record back as an iteration comment. Auto-invoke on "retrospective", "retro", "sprint review", "review the iteration", or any request to review or summarize what an iteration delivered.
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
| **The record** | A comment on the iteration carrying `context: "retrospective"` — a short lede, where the report is, and the follow-ups you are **suggesting**. This is what the board keeps, and what someone replies to. |

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
| Comments **not written by a bot** — `select(.user.bot \| not)` | On an agent-run board this is the whole human record: bug reports from a real device, scope corrections, "we don't need that here". ⚠️ A way to **find** the testimony, never a statistic to publish — see **What NOT to report** | **7 comments, 1,814 characters** |
| The tickets the report will actually discuss — every `rejections_count > 0`, the longest cycle times, the re-estimates | Where "it was the third attempt" is actually written. Section 7 needs these | a handful |

```
jq '[.tickets[] | {id, title, comments: [.comments[] | select(.user.bot | not) | {created_at, body}]}] | map(select(.comments | length > 0))'
```

**Weigh testimony above anything you infer.** Where the two disagree, say so explicitly and give both. "The board shows this accepted on the first pass; the comments record two days lost to a wrong assumption before the ticket was opened" is the most valuable sentence a retrospective can contain, and no metric produces it.

⚠️ **THE ITERATION BOUNDARY DOES NOT BOUND THE CONVERSATION.** A ticket belongs to the iteration it was **accepted** in, not the one it was worked in, so its comments spill either side of the dates. Measured on a one-day iteration: 4 comments written before it, 178 on the day, and **70 the day after**. Do not date-filter the comments to the iteration's own dates — you would discard 28% of the record, and the discarded part is the end of every story.

⚠️ **AN EMPTY ITERATION THREAD IS THE NORMAL CASE, AND THE REPORT SAYS NOTHING ABOUT IT.** Take the testimony from the ticket comments and write it up without provenance — where you found it is your problem, not the reader's. Report testimony as *missing* only when the tickets are silent too, which is the case where the absence really is the finding. **Do not file a ticket saying nobody writes iteration notes** — that was filed, measured and decided against: with one-day iterations and up to ten tickets in flight inside half an hour across concurrent sessions, nobody has the vantage point to write "how the iteration went", so per-ticket is the granularity and the iteration thread is for the record.

## Step 2 — Gather the iteration

```
jus api GET '/workspaces/{ws}/summary' | jq -r '.workspace.timezone'
jus api GET '/workspaces/{ws}/iterations/{iteration}'
jus api GET '/workspaces/{ws}/tickets?iteration_id={iteration}&per_page=200&include_markers=true'
```

**Fetch the zone first and hold it**, because every date you bucket and every time you render depends on it — see **EVERY TIMESTAMP** in step 3 for why the summary endpoint is the one to ask and the workspace row is not.

The iteration row carries the committed and accepted point totals. The ticket list carries everything else — state, type, points, labels, project, requester, stakeholder, assignees, `rejections_count`, and the timestamps the board exposes.

⚠️ **`include_markers=true` IS LOAD-BEARING.** The ticket index drops release, milestone and deadline markers by default, and `pagination.count` reports the reduced number — it describes the rows the filter let through, so it is internally consistent with the thinned page you were handed and every check you can run on the list passes. Measured on a real iteration: **102 without the flag, 112 with it.**

**The ten it dropped were the release markers**, which is precisely the population section 9 exists to examine — so the query is blind in the one place the analysis has to look. A retrospective run without the flag is not slightly incomplete; it is confidently wrong about what shipped.

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

**A headline and nine sections. Scale the depth to the iteration, not to this list** — a one-day iteration with four tickets gets a short report, and saying "there is not enough here to retrospect on" is a legitimate finding. A hundred-ticket iteration gets all nine.

### The headline is three to five numbers, and no more

Points closed, tickets closed, the rank against the whole series, and at most two others. **Every other number in the report appears inside a sentence that says what it means.** A figure standing on its own is one the reader has to interpret on your behalf, and most figures do not survive the attempt — which is how a report ends up long, dense and unread.

⚠️ **The test for a number is not "is it true", it is "would the reader act differently".** Type distribution, comment counts, per-actor event tallies and events-per-hour are all true and none of them changes a decision. Cut them unless one of them moved.

1. **What happened** — grouped by **theme**, never by ticket. This is the section a reader most wants and the one most often replaced by a list. A ticket id belongs in it as **evidence for a claim** — "the third attempt at this (#812) is where the parser was finally replaced" — never as the subject of its own row. ⚠️ **If a table's rows are tickets, it is the wrong table**: rewrite it so the rows are the findings and the ticket ids sit in a cell.

2. **What people said** — the testimony gathered in step 1, quoted, and weighted above anything you inferred. Where testimony and timestamps disagree, say so and give both; that is the most valuable sentence a retrospective can contain and no metric produces it.

3. **Where the effort went** — by kind of work: user-facing features, bug fixing, performance, internal tooling and plumbing, research, documentation. **In points, not ticket counts**, so it reads as effort rather than volume.

4. **When the work happened** — the hours of the day work was actually being done, per day of the iteration, in the board's zone. **Distinct active hours, the span from first to last, and where the gaps fall.** This is the section that answers "what did the week actually look like", and it is invisible in every other cut.

   The cheapest complete source is the commit log, which needs no API and covers every day at once:

   ```sh
   TZ=<board zone> git log --since='<start> 00:00' --until='<end+1> 00:00' \
     --date=iso-local --format='%ad' | awk '{print substr($2,1,2)}' | sort | uniq -c
   ```

   ⚠️ **`TZ=` plus `--date=iso-local` is what makes this correct, and `%aI` is the trap.** `%aI` prints each commit's own recorded offset, so slicing it by character position buckets a commit by whatever zone its author's machine was in. Measured on one repository: **35 of 5,232 commits are recorded at `+00:00`** because they were made from a container, against 5,197 at the local offset — enough to move a bar and never enough to look wrong. `--date=iso-local` re-renders every commit in one zone, and `TZ=` chooses which.

   **Cross it with the board.** Commits miss the tickets that produced no code — research, review, anything the stakeholder did — and the per-ticket activity feeds from step 2 carry those. Where the two disagree about when the day started, that difference is itself worth a sentence.

   **What to actually report:** how many of the 24 hours carried work, the span, the longest gap inside it, and whether any of that changed from the previous iteration. Not a count of events per hour, which is throughput wearing a clock.

5. **How production behaved** — the iteration's effect on the running system, from whatever the project already has: an APM, an error tracker, a log store, an uptime check.

   | Ask | Because |
   | --- | --- |
   | **Error rate** over the window, against the preceding one | the one number that says whether the iteration made things worse |
   | **Latency** — p50, p95 and p99, not a mean | a mean hides the tail, and the tail is what people feel |
   | **Throughput** | the denominator. A halved error rate on a tenth of the traffic is not an improvement |
   | **The error classes that actually fired**, faceted and counted | a rate says something changed; the classes say what |

   ⚠️ **A deploy inside the window means the figures straddle two versions.** Say where the deploys fell before comparing anything across them, or bound the query to one side.

   ⚠️ **Bound the window from the board's local dates, converted.** A query language's time literal is machine input and is usually UTC — that is the one place UTC is correct, and the report says so where it shows the query.

   ⚠️ **If the project has no such tooling, that is one clause and no section.** Do not substitute something that looks like it — CI duration, test counts, a log line count — for a production signal.

6. **What debt stands** — the standing cost the iteration inherited, and whether it moved.

   | Ask | Typical source |
   | --- | --- |
   | How far behind are the direct dependencies, and for how long | `bundle outdated`, `pnpm outdated`, `go list -m -u all` |
   | What is known-vulnerable right now | `bundler-audit`, `pnpm audit`, `govulncheck`, the platform's own advisories |
   | What upgrades are pending and blocked, and on what | the board, plus whatever the project already records |

   ⚠️ **"Is what we have vulnerable?" and "how far behind are we?" are different questions, and a clean scan is not evidence of currency.** A library can sit six releases behind for four months and emit no vulnerability signal at all, because none of those releases fixed a CVE. Report both, and never let one stand in for the other.

   **The interesting figure is the direction, not the level.** Debt that is flat is a fact about the project; debt that grew or shrank this iteration is a fact about the iteration, which is what a retrospective is for.

7. **What went wrong** — difficulties, reversals, work that shipped and was then found wrong, and the rejections.

   ⚠️ **CLASSIFY THE REJECTIONS BEFORE ANY RATE IS REPORTED.** A rejection count is not a rejection rate: the counter tallies transitions, and several of them are not the thing the number is read as meaning. **Read each one** — the ticket's comments and its activity feed — and split them:

   | Looks like a rejection | Is it? |
   | --- | --- |
   | Work sent back because it was wrong or incomplete | **Yes.** This is the population a rate is about |
   | A reject-and-redeliver minutes apart, to exercise the fix under test | No. That is a verification step wearing a state change |
   | An author re-opening their own work before anyone reviewed it | No. Nobody rejected anything |

   Measured on a real iteration: **5 events across 4 tickets, of which 3 were real and sat on 2 tickets.** Reported raw, the rate is nearly double. Give the classified figure, say how many events you excluded and why, and name the tickets — the reader can then disagree with your calls, which they cannot do with a bare number.

   **Scope churn and estimate drift live here too, and only when they moved.** What entered and left mid-flight, and where the first estimate and the final one diverged. ⚠️ **A ticket created without an estimate has no opening value to drift from** — that is a real state, not missing data. Count those and say how many rather than treating the first later estimate as the original. If drift was a point or two across the whole iteration, that is one sentence, not a table.

8. **What the data says that nobody asked for** — the section the rest of the report exists to make possible, and the one most likely to come out as filler.

   **A finding here is a claim someone could disagree with.** "Velocity was 82 points" is not one. "Every ticket that took more than a day had its estimate raised, and none that took less did" is.

   **Four rules keep it honest:**
   - **Name the two things you compared, and the window.** A trend with no baseline is an observation about one number.
   - **Try once to explain it away, and say what you tried.** A finding that survives a stated attempt is worth reading; one that was never challenged is a coincidence with a sentence around it.
   - **Distinguish a trend from a step change.** A gradual drift and a clean jump at one instant have different causes, and a jump that lands exactly on a boundary — a deploy, a month, a schema change — is a measurement artefact until proven otherwise. ⚠️ **Check the population before believing the number**: an instrument working perfectly can be counting something other than what you think it is counting.
   - **"Nothing unusual this iteration" is a legitimate finding.** Say it in a line. It is far better than four manufactured ones, and a reader who has seen you say it will believe the next section that is not empty.

9. **What shipped, and what has not** — work that is merged but not yet released is not delivered value. If the board tracks releases, say what is sitting behind an unrun one.

   ⚠️ **Split that figure by state before you report it.** A release's list of pending work mixes accepted tickets with ones merely delivered or since cancelled, so a single point total silently overstates what the iteration actually accepted and has not shipped. Give the accepted number as the headline and the rest beside it. Measured on a real run: 37 points on the marker, of which **25** were accepted — the draft led with 37 and called them accepted.

### ⚠️ A RANK CLAIM IS COMPUTED OVER EVERY ITERATION, NOT THE ONES YOU FETCHED

**"The second-best iteration on the board" is a claim about the whole series**, and the reflex is to rank against whatever window happened to be in front of you — the rolling velocity average, the last dozen columns of your own chart, the page the API returned. That window is chosen for a chart's legibility, and it is not the population the sentence describes.

```
jus api GET '/workspaces/{ws}/iterations'
```

**Rank over all of it, and name the ones above.** Measured on a real run: an iteration called "the second-highest on the board" was **4th of 196**, and the three above it were nowhere near the fetched window. Nothing about the wrong claim looked wrong, and a superlative is the sentence a reader is most likely to repeat.

⚠️ **Say which metric the rank is over.** Accepted points, tickets done and committed points give different orders, and a rank with no named metric cannot be checked by anyone.

### ⚠️ Section 3 is the one that gets faked

**Ticket type alone does not answer "where did the effort go", and using it as the answer is the trap.** A feature can be a user-facing capability or an internal developer tool. A chore can be a performance fix, a dependency bump or deployment plumbing.

**Cross three signals:** the ticket type, the labels, and the project the ticket sits under — the project usually carries the intent outright. Where they disagree, the classification is a **judgement**, and the report should show it rather than bury it: name the tickets you were unsure about and say which way you called them.

This is the cut that answers *did we spend the month on what we meant to*, which a type distribution cannot.

### ⚠️ EVERY TIMESTAMP THE REPORT RENDERS IS IN THE BOARD'S ZONE, AND CARRIES IT

**Not UTC. Not a bare number.** `14:05 PDT`, not `21:05 UTC` and not `14:05`. Times are read by people who work in one zone, and a report full of UTC asks every one of them to do arithmetic before they can picture the day.

**Get the zone from the board, not from the machine you are running on** — and not from the field that looks like it:

```sh
jus api GET '/workspaces/{ws}/summary' | jq -r '.workspace.timezone'
```

⚠️ **The workspace's own row can carry a null there and the summary never does.** One serialises the stored column, the other the **effective** zone — the stored one falls back to a default that only the server knows. Measured on a real board: `GET /workspaces/1` answered `"timezone": null` while `/summary` answered `America/Los_Angeles` at the same moment. A report built from the first one falls back to UTC and looks entirely correct.

**Two places UTC is still right, and both are machine input rather than prose:**

- A query language's time literal — an APM's `SINCE`, a SQL `AT TIME ZONE`. Convert the board's local dates into it, show the query as you ran it, and say in one clause that the literal is UTC.
- A raw identifier you are quoting verbatim from a log or an API payload. Quote it as it came, and give the local time beside it.

⚠️ **Bucketing is the same rule and it is the one that silently moves work between days.** An iteration's start and end are local dates; comparing raw UTC strings against them puts an evening's work on the following day. Measured on one run: **19 of 102 tickets moved**, turning "90% of this iteration was filed the day it was worked" into a much weaker claim, with nothing about the wrong answer looking wrong.

### ⚠️ NAME PEOPLE. DO NOT WRITE "the stakeholder"

A retrospective is read by the people it is about — a handful of them, all of whom are named in the data you just fetched. Writing `"the stakeholder"`, "a teammate", "the agent" or "the author" where a name is available is anonymisation with no beneficiary: it makes the report harder to read and signals a caution that nobody asked for.

Measured on a real run: the report carried a section headed *"What the stakeholder wrote, in their own hand"* about a board with exactly one human member, whose name appeared in every payload it had read.

**Use the display name the board gives you**, and the handle beside it on first mention if the two differ. The same applies to agents — an agent with a name is a participant with a name.

**The one exception is a report you are about to publish outside the board**, which is a different decision and covered in step 6. That is a reason to ask before publishing, not a reason to write the report anonymously.

### ⚠️ A SOURCE YOU CANNOT REACH IS A CLAUSE, NOT A SILENCE

Some of what sections 5 and 6 want lives behind credentials, a VPN, or a machine you are not on. **A retrospective run from a sandbox routinely cannot reach the APM** — a token held in an operating system keychain does not exist on a Linux runner, and a local check-run log is on somebody's laptop.

**Three ways to handle that, and only one is acceptable:**

|  |  |
| --- | --- |
| Leave the section out | ✗ The reader cannot tell an absent signal from a healthy one |
| Substitute something reachable that resembles it | ✗ Worse — it is quotable and wrong |
| Say which source you could not reach, and what it would have answered | ✓ |

**Never fabricate a figure, and never round one you did not measure.** A sentence naming the gap costs the reader nothing and tells the next run exactly what to fix.

## ⚠️ What NOT to report

**This list exists because every item on it is true, easy to compute, and worth nothing to the reader.** That combination is what makes them come back: each one looks like diligence, each one passes every check in step 5, and a skill that only says what to *include* re-acquires the whole set one run at a time.

They were named by the person the reports are written for, after reading one that contained all of them.

| Do not report | Why it is not a finding |
| --- | --- |
| **Who is a bot and who is not** — that most tickets were created, worked or accepted by an agent | It is the board's operating model, not something that happened this iteration. State the model in one clause the first time and never again. **Report it only when it changed** — a shift in who does what IS a finding |
| **That one person does all of the accepting** | Same. It is the review structure, and it was the same last iteration |
| **The human-versus-bot comment ratio** | A constant of how the board is run. "Only 2 of 140 comments are human-authored" measures the workflow, not the work |
| **That most chat happens outside the board** | True on nearly every board, unactionable, and it reads as a complaint about the reader. Quote what was said; do not audit where it was said |
| **That the iteration thread had no comments** | The normal case. Take the testimony from the ticket comments and say nothing about it. It becomes a finding only when the tickets are silent too |
| **Which source the testimony came from** | Provenance the reader did not ask for. Quote the person and cite the ticket |
| **Ticket-by-ticket detail** — a table whose rows are tickets, a paragraph per ticket, a walk through one ticket's lifecycle | The reader has the board for that. A ticket id is evidence inside a claim, not a subject |
| **Metrics that did not move** | Type distribution, per-actor event counts, comment counts, events per hour. If the number is the same as last time, the sentence is "unchanged" or it is nothing |

⚠️ **The failure mode is subtler than including them: it is letting one become a section heading.** A heading is a promise that what follows matters, so a section named after a constant makes the whole report read as padding — and the sections that do matter get skimmed at the same rate.

**What replaces them is not silence.** Sections 4, 5, 6 and 8 are all things nobody was reporting, and every one of them costs about what the list above cost. The budget moves; it does not shrink.

### Anonymising is on this list too

See **NAME PEOPLE** in step 3. It appears here as well because it is the same instinct — writing around the specific because the general feels safer — and because it was the first thing noticed in the report that produced this list.

## Step 4 — Draw the charts

**Hand-authored inline SVG. No chart library, no CDN, no network.**

This is not a stylistic preference. The report has to work as a hosted page **and** as a file opened from disk — a hosted page restricts which hosts it may load from, and a file on a laptop may have no network at all. A library that works in one and fails silently in the other gives you a report with blank rectangles where the analysis was, and nothing warns you.

**If a chart needs a library to be worth drawing, make it a table instead.** A retrospective's charts are bars, columns and a distribution; all three are a dozen lines of SVG.

### Which cuts earn a chart

| Chart | For |
| --- | --- |
| Horizontal bars | Effort by kind of work (section 3) |
| Column series | Velocity against the preceding iterations; **hours of the day carrying work** (section 4), one column per hour |
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

**Check these eight, every time. They are the ones that go wrong:**

1. **The parts sum to the whole.** Effort by kind of work must total the iteration's points. If it does not, some tickets fell out of your classification — find them and add an "unclassified" row rather than letting the shortfall hide.
2. **Percentages total 100**, allowing for rounding, and say which way you rounded.
3. **Every bar's width is proportional to its value, on the SAME scale as its own axis.** Recompute one by hand from the rendered `width` and compare — then check that the axis labels use that scale too. The failure that actually happens is a chart whose bars were sized from the largest value and whose axis was labelled from a round number: every bar is proportional to every other bar, so it looks right, and every one is in the wrong place against the gridline.
4. **Counts agree with the source.** Your ticket total must equal what the API reported in `pagination.count`. A mismatch means you missed a page.
5. **The list agrees with the ITERATION ROW, which is a second source.** ⚠️ Check 4 alone cannot catch a filtered list — `pagination.count` describes the rows the filter let through, so it agrees with itself no matter what was withheld. The iteration's own `done_tickets_count` counts accepted and cancelled tickets **including markers**, and is computed by a different query, so compare the two: **your list must not be smaller than it.** A list of 102 under a `done_tickets_count` of 106 is the tell. Where the server returns `.meta.excluded_markers` (step 2) that says it outright, but this check needs no particular server version, so run it either way. If your list is smaller, re-fetch with `include_markers=true` before going any further.
6. **Excluded rows are declared.** Nulls, cancelled tickets, tickets that moved out mid-iteration — every exclusion appears in the report with its count.
7. **Every rendered timestamp carries a zone, and it is the board's.** Grep the finished HTML for `UTC` and for a bare `\d\d:\d\d` with no zone beside it. Each hit is either a machine-input literal you are deliberately showing — an APM `SINCE`, a quoted log line — or a defect. This is the cheapest check in the list and it caught nothing for as long as it did not exist.
8. **Every figure you could not measure is named as unmeasured.** Walk the sections that depend on an outside source — production health, standing debt — and confirm each either carries a number you actually ran, or a clause saying which source you could not reach. A section that is simply absent fails this check.

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
3. The follow-ups you are suggesting — numbered, and nothing filed. See step 8.
4. Anything you could not compute, and why.

### Re-running replaces; it does not append

**A second retrospective comment on the same iteration is wrong.** Find the existing one and update it:

```
jus api PATCH '/workspaces/{ws}/iterations/{iteration}/comments/{comment}' '{"comment":{"body":"…"}}'
```

The body is versioned, so the previous text survives. **Re-sending the report replaces it too** — the board keeps one per iteration — so the record stays correct without being touched.

## Step 8 — Propose the follow-ups; do not file them

A retrospective that surfaces nothing to do is a summary. But **the filing decision is not the analysis's to make.** These would be the least-reviewed tickets on the board — written by an agent, at the end of a long run, about work nobody has re-read — and they arrive already prioritised, above tickets someone placed deliberately. Measured on the first real run of this skill: three landed in an empty backlog and became its first three entries, unasked for.

**So propose them, numbered, in the record.** ⚠️ **Do not file them.** Not "except the obvious one", not "just the urgent one". A suggestion costs a line; a ticket costs a place in someone's queue.

### The format

Under a **Suggested follow-ups** heading in the record:

| # | Suggested title | Type | Pts | Why, and what it rests on |
| --- | --- | --- | --- | --- |
| 1 | … | chore | 2 | … |

**Number them.** The approval names a subset by number, and an unnumbered list can only be answered "all" or "none". Say in the same section, plainly, that nothing has been filed.

Keep saying what you considered and rejected, and why — that judgement is the same one, and it is worth more than the list.

⚠️ **Do not suggest one per observation.** Group them. Five that all say "this doc was out of date" is noise; one that says "the reference and the code have no guard holding them together" is the finding.

### Once approved

The approval arrives as a **reply on the record comment**, which dispatches an agent with that thread as its context.

File **exactly what the reply approves** — no more, and nothing you have thought of since — under the normal rules in `ticket-workflow`: a description and an estimate on each, at the **bottom of the backlog** unless one is genuinely urgent. Then reply in the same thread naming what you created, by id, and update the record's table so each approved row carries its ticket id.

⚠️ **An ambiguous approval is a question, not a licence.** "yes, file those" against a list of six is clear. "yes, the doc ones" is not — ask in the thread rather than deciding which two you meant.

⚠️ **A suggestion with no id is one nobody can connect back to why it exists**, which is what naming them in the record is for. The same is true in reverse: a ticket the report does not explain is one nobody knows the reason for.

## Reflexes

| If | Then |
| --- | --- |
| The iteration thread is empty | Normal. Take the testimony from the ticket comments and say nothing about where it came from |
| The ticket comments are empty too | *Now* it is a finding. Say the report is reconstruction only |
| The comment corpus is enormous | Expected — slice it. Human-authored first, then the tickets the report discusses |
| Your ticket list is smaller than `done_tickets_count` | You are missing the markers. Re-fetch with `include_markers=true` |
| `.meta.excluded_markers` came back `null` | The server predates it. That is not a zero — run check 5 |
| You are about to write "best", "second-highest", "worst" | Rank over every iteration, name the metric, name the ones above |
| You have a `rejections_count` | Read each event and classify it before reporting a rate |
| A timestamp is missing from the payload | Fall back to the activity feed, and say what it cost |
| You are about to render a time | Board's zone, zone abbreviation beside it. UTC only for a machine-input literal |
| `.workspace.timezone` came back `null` | You asked the workspace row. Ask `/summary`, which serves the **effective** zone |
| You are about to write "the stakeholder" or "the agent" | Use their name. You fetched it |
| You notice most tickets are bot-authored, or that one person accepts everything | Not a finding. One clause the first time, then never again unless it changed |
| You cannot reach the APM, the error tracker or the debt tooling | Name the source you could not reach. Never omit the section, never substitute a lookalike, never guess the number |
| A section would have nothing in it | Say so in a line. An empty section honestly labelled beats a manufactured one |
| A metric needs a null-heavy column | Count the nulls, exclude them, report the count |
| The classification is ambiguous | Show the judgement and name the tickets |
| A chart needs a library | Make it a table |
| You cannot publish a hosted page | Send the body anyway — the board serves it. Say you did not publish |
| You already ran this iteration | Update the existing comment, never post a second |
| The iteration is tiny | Write a short report and say it is short |
| You found something worth doing | Suggest it, numbered, in the record. Do **not** file it |
| A reply approves some of the suggestions | File exactly those, bottom of the backlog, then say in the thread what you created |
| A reply approves them ambiguously | Ask which, in the thread. Do not pick |

## Related skills

- **`ticket-workflow`** — the lifecycle, estimation, labels and the `jus` CLI / API reference. Filing the step 8 suggestions, once a reply approves them, follows it.
- **`hard-rules`** — the non-negotiable guardrails, including the rule that every piece of work has a ticket.
