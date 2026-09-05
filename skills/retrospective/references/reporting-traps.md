# Reporting traps — the five ways a retrospective's prose goes wrong

Read while writing the ten sections in step 3. Each of these has produced a wrong or
hollow report, and none is caught by step 5's arithmetic check — they are claims that
are *shaped* right and wrong anyway.

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

⚠️ **AN AGENT'S NAME COLLIDES WITH ITS PRINCIPAL'S, AND THE REPORT MUST NOT MERGE THEM.** A board's agent user usually carries a display name chosen to read well in a comment thread — "Claude" — and belongs to a human whose own name sits beside it in every payload. Two humans can share a first name just as easily.

**The disambiguation is already in the data you fetched.** Every serialized user carries `username`; a bot additionally carries `bot: true` and `operated_by`, the display name of the human it belongs to.

- **On first mention, add the handle whenever the display name is not unique on that board**: `Claude (caleon-claude)`, `Caleon Chun (caleon)`. Afterwards the display name alone is fine, unless a sentence carries both.
- **Say whose agent it is** where the report attributes work: `Claude (Caleon's agent)`. Without it a reader cannot tell two tools apart from two people's tools.

⚠️ **Never merge an agent's activity into its principal's in a cut that counts.** They are separate actors with different working patterns — that difference is often the most interesting thing in the timing section — and collapsing them is exactly the anonymisation this rule forbids, applied to the half a reader cannot recover.

**The one exception is a report you are about to publish outside the board**, which is a different decision and covered in step 6. That is a reason to ask before publishing, not a reason to write the report anonymously.

### ⚠️ A SOURCE YOU CANNOT REACH IS A CLAUSE, NOT A SILENCE

Some of what sections 6 and 7 want lives behind credentials, a VPN, or a machine you are not on. **A retrospective run from a sandbox routinely cannot reach the APM** — a token held in an operating system keychain does not exist on a Linux runner, and a local check-run log is on somebody's laptop.

**Three ways to handle that, and only one is acceptable:**

|  |  |
| --- | --- |
| Leave the section out | ✗ The reader cannot tell an absent signal from a healthy one |
| Substitute something reachable that resembles it | ✗ Worse — it is quotable and wrong |
| Say which source you could not reach, and what it would have answered | ✓ |

**Never fabricate a figure, and never round one you did not measure.** A sentence naming the gap costs the reader nothing and tells the next run exactly what to fix.

⚠️ **THE CLAUSE IS A CLAUSE. A SECTION THAT MEASURED NOTHING GETS NO HEADING, NO TABLE AND NO PARAGRAPHS.** "Not a silence" is a floor, and a run that reads it as a licence produces the opposite failure — the section written out in full to say that nothing in it was read.

**What to write depends on how much you reached:**

| Reached | Write |
| --- | --- |
| All of it | The section |
| Some of it | The section, with each missing figure named as unmeasured where it would have stood |
| **None of it** | **One line, in the report's closing "What this could not measure" list. No heading, no table, no query** |

That line names the signal, then why it was out of reach, then what would fix it — in one sentence:

> Production error rate, latency and throughput — not read. The APM token lives in a macOS keychain and this run was in a Linux container; a run from the host would have it.

**Measured on a real report:** the production section came back as a heading, a three-row table of signals that could not be read, two paragraphs about the query that was not run, and a note on deploy boundaries. Every word was true, and the whole of it said that nothing was measured — a page of the report, between two sections that had findings in them. The stakeholder's verdict was _"isn't very helpful… might as well remove sections if they're not insightful."_
