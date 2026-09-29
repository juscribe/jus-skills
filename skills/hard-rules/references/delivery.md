# Delivery rules — the full text

Read before the `finished` transition. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Delivery Rules — Did You Actually Do What the Ticket Asks?

- **NEVER deliver work that defers, skips, or deviates from what the ticket prescribes.** If the ticket says to do X and you didn't do X (or did a partial version of X), do **NOT** mark the ticket finished/delivered. Delivering incomplete or deviated work forces a rejection cycle that wastes everyone's time. When in doubt, ask — don't deliver.
- **Re-read the ticket description before finishing.** Did you implement what was prescribed? If you deferred something, skipped a requirement, chose not to do something the ticket specifies, or deviated from the described scope — leave the ticket in `started` and post a comment.
- **"Comprehensive" / "100%" / "thorough" mean exactly that.** No "good enough" exits. And where a project ships **more than one client**, code plus passing tests is not sufficient on its own: work verified entirely against the primary surface can deliver completely broken on the other. The four checks are in `ticket-workflow/references/second-client.md`.
- **TICK THE BOXES BEFORE YOU DELIVER — state is not decoration.** Any `- [ ]` left in a description, and any untoggled subtask, is a live claim about what has **not** happened yet. Delivering while the acceptance criteria still read unchecked tells the stakeholder the opposite of what the delivery comment says, and the description is what they re-read at acceptance. **Sweep every checkbox and every subtask as the last action before the `finished` transition.**

  Measured: seven delivered tickets carrying **47** unchecked boxes between them — every criterion actually satisfied and documented in the delivery comments, while the descriptions said none of it was done. It reads as seven abandoned tickets.

  ⚠️ **Tick a subtask the turn its step completes, not in a sweep at delivery.** That is the whole point of it being data; a ten-step ticket left untouched for days is the board lying for days.

- ⚠️ **AND THE INVERSE, WHICH BOTH GATES ABOVE PASS BY CONSTRUCTION.** Ticking a criterion you have **not** met is the same lie the other way round, and it is the worse one: an unticked box is visible and gets asked about, while a wrongly ticked one looks exactly like success, so nobody goes back. The sweep finds no unticked box, and the pre-delivery re-read confirms criteria you have already marked satisfied.

  **The check is one question: what evidence would I cite?** A command, a query, an output, a file, a commit. A criterion you cannot answer that for is not met, whatever the diff shows — and "it will be true once this ships" is a forecast, not evidence.

- **Every delivery comment includes verification steps** (the "To verify" section) AND git information (commit SHA + `git show` for direct commits on main; nothing for dispatched work — the dispatch UI appends branch info; explicit "no code changes" for research/docs tickets). Even in batch work — never skip or batch delivery comments to save time.
