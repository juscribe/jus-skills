# A project retrospective

> Read this when the retrospective is of a **project** rather than an iteration. Steps 1, 4, 5 and 8 of the skill apply unchanged. This file replaces step 2's gathering, says what each of step 3's project sections is answered from, and gives the addresses steps 6 and 7 send to.

## Contents

- [Gather the project](#gather-the-project)
- [What each project section is answered from](#what-each-project-section-is-answered-from)
- [Deliver the report and write the record](#deliver-the-report-and-write-the-record)

## Gather the project

```
jus api GET '/workspaces/{ws}/summary' | jq -r '.workspace.timezone'
jus api GET '/workspaces/{ws}/projects/{project}'
jus api GET '/workspaces/{ws}/projects/{project}/comments'
jus api GET '/workspaces/{ws}/tickets?project_id={project}&per_page=200&include_markers=true&include_comments=true&include_label_objects=false'
jus api GET '/workspaces/{ws}/projects/{project}/activities?per_page=100'
jus api GET '/workspaces/{ws}/projects/{project}/dependencies'
```

**MCP:** `get_workspace_summary` for the zone, `get_project`, `list_tickets` with `project_id` and `include_markers`, `get_ticket` for each ticket's comments, and `list_blockers`. No MCP tool reads the activity feed: use the timestamps the tickets carry, and say the history is incomplete.

The `{project}` in every path is the number in the board's `pN`, without the `p`.

**The project row** carries the name, the description, the state, the requester, the stakeholder, the assignees, and the lifecycle dates `started_at`, `delivered_at` and `accepted_at`.

⚠️ **THE PROJECT'S OWN LIFECYCLE DATES ARE NULL ON MOST OLDER PROJECTS.** A board that began recording them partway through its life has nothing for the projects before that. Null means unknown, never zero. Take the span from the tickets instead: the first ticket started, from its activity feed, to the last accepted. Say which source you used.

**The activity feed** holds every activity of the tickets now in the project, plus the project's own. A project move is an `update` whose `project_id` goes `{from, to}`. Compare its time with the project's start to tell scope that was planned from scope that was added.

⚠️ **A TICKET MOVED OUT OF THE PROJECT IS IN NEITHER LIST.** The move is recorded on that ticket, and the project no longer reaches it. Unless something else names those tickets, the plan's removals cannot be counted. Say so in a line rather than reporting zero.

**Blockers.** The dependencies call gives the project's own. A ticket's blockers are on that ticket, at `/tickets/{ticket}/dependencies`. Each one's `created_at` and `resolved_at` bound how long it held.

**Work outside the project.** For each assignee, list the tickets they started or accepted inside the project's span that are not in it:

```
jus api GET '/workspaces/{ws}/tickets?assignee_id={user}&per_page=200&include_markers=true'
```

**MCP:** `list_tickets` with `assignee_id` and `include_markers`.

Filter by date yourself, in the board's zone, and drop the project's own tickets.

## What each project section is answered from

The headline rule from step 3 holds: three to five numbers, and every other figure inside a sentence that says what it means.

| # | Section | Answered from | The trap |
| --- | --- | --- | --- |
| 1 | What got done | the tickets and their delivery comments | Group by theme. A table whose rows are tickets is the wrong table, exactly as for an iteration |
| 2 | What works differently now | delivery comments, the project description, release markers | Write it as "before, X; now, Y" for a user, an agent or an operator. A list of features is section 1 again |
| 3 | How long it took | lifecycle dates, else the tickets' feeds; the commit log for active hours | Three different figures: the calendar span, the hours actually worked inside it, and lead time from the first filing. Name which one each sentence means |
| 4 | How much we waited | `delivered` → `accepted` per ticket, blocker spans, days with no activity, filing → start | Merge overlapping blocker spans before adding them up, or one bad week counts twice |
| 5 | What took time away | the outside-work query above | In points and days, not ticket counts. Name the two biggest, and whether either was urgent |
| 6 | Which blockers hurt | the dependencies, with their spans and what each held up | Rank by what was held up, not by how long it was open. An external blocker names the party it waited on |
| 7 | What nobody knew at the outset | tickets added after work began, bugs and regressions found on the way, start comments contradicted later | Quote the sentence where someone found out. A late addition someone planned is not an unknown |
| 8 | How far the plan moved | the feed's moves, `create` against later `points` updates, cancellations with their resolution, rejections | Start against end, in tickets and in points. Classify rejections as step 3's iteration section 8 says. Never one "plan accuracy" percentage |
| 9 | Who was involved | requester, stakeholder, assignees and commenters | Names and roles, one clause on what each did. Never a ratio, and never the human/agent split as a finding |
| 10 | What shipped, and what has not | release markers holding the project's tickets | Split accepted from merely delivered, exactly as for an iteration |

**Sections 3 and 4 share a timeline, and should share one chart.** One row per ticket, from filing to acceptance, shaded by state, makes the waiting visible at a glance. Draw it the way step 4 says.

## Deliver the report and write the record

The calls are step 6's and step 7's, addressed to the project:

```
jq -Rs '{retrospective:{html:.}}' <report.html> | jus api PATCH '/workspaces/{ws}/projects/{project}/retrospective'
jus api POST '/workspaces/{ws}/projects/{project}/comments' '{"comment":{"body":"…","context":"retrospective"}}'
```

**MCP:** no MCP tool sends the report or writes a project comment. The report stays in the chat; give the person the record's text to post on the project.

**One record per project.** A second `retrospective` comment is refused. Re-running means editing the existing one at `/projects/{project}/comments/{comment}`.

⚠️ **A `403` saying "This feature is not enabled" means the board has not switched project retrospectives on.** Keep the HTML file, say in the record where it is and that the board could not take it, and stop there. Do not retry, and do not paste the report into the comment: step 6 says why.

⚠️ **The board offers the button only on a delivered or accepted project.** A run started some other way on a project still in flight is a progress report. Say so in the lede.
