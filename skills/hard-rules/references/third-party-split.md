# Blocked on a third party — the full text

Read when a ticket's remaining criteria depend on someone outside the team, or on time passing after your own deploy. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Blocked on a Third Party — Split at the Boundary, Deliver Your Half

⚠️ **A ticket whose remaining acceptance criteria depend on an outside party must never sit in `started`.** Marketplace acceptance, vendor approval, an upstream release, a support ticket, a domain transfer — none of it moves because someone is assigned. `started` claims a person is working on it, which is precisely what hides that the ball is entirely elsewhere.

**This is distinct from the External Blocker Rule in `SKILL.md`.** That one is for work _you own_ and cannot continue — you stay `started` because you resume the moment the answer arrives. This one is for a ticket whose completion is **not yours to reach**.

⚠️ **"Third party" is this section's title, not its test.** The test is at the end, and reading the title as the test is how the section gets skipped: **waiting on your own deploy plus elapsed time fails it too**, and nothing about that reads as an outside party.

**The procedure, in order:**

1. **Re-scope the original to what you actually own.** Move the dependent criteria out of its acceptance list and say where they went. Do not delete them.
2. **Deliver the original** against that re-scoped list, naming the commit that shipped it. ⚠️ **Do not cancel it** — the work was done, and cancelling erases that.
3. **Create a successor** carrying the moved criteria, in the **icebox**: it cannot be scheduled, so it must not sit in a backlog that implies it can.
4. **Add an External dependency to the successor** naming the awaited event specifically, not "waiting on vendor".
5. **Cross-reference both ways** — the original says where the rest went, the successor says what already shipped and under which commit.
6. **Give the successor a closing condition.** "If they reject, or never answer: close this too, record why, and keep the artefact." A successor with no way to end is the original's problem with a new number.

**The test:** _could anyone here complete this ticket today, given unlimited effort?_ If no, and the reason is someone else's decision or the passage of time, split it. If yes but you need an answer first, that is the External Blocker Rule and you stay `started`.
