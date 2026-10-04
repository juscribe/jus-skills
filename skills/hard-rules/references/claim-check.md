# The ticket is a claim, not a contract — the full text

Read at pickup, before the start comment. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## The Ticket Is a Claim, Not a Contract

Every other gate here asks whether you **obeyed** the ticket. None asks whether the ticket is **right** — so a wrong prescription gets implemented faithfully and the process reports success.

**Before you start, check the ticket's own statements, and say what the prescribed approach assumes.** Both go in the start comment. This is a sentence, not a review pass.

- **Stated measurements** — re-run them if they are cheap. A ticket citing a file mode, a rate, or a volume is citing someone's reading from some earlier day.
- **What the prescribed approach depends on being true** — the expensive one. A ticket prescribing "add it as an eighth entry to that file" assumes the file exists at the moment the code runs. If the tool that creates it runs later, the append silently does nothing, and you find out after the spec, the commit and the documentation have all been built against it.

**Raising it early is cheaper than raising it late, and that is the whole point.** Flagging a deviation is not the same as asking — but a prescription questioned **before** implementation costs one message, and the same prescription questioned **after** costs the rebuild. Ask at the moment the doubt forms.
