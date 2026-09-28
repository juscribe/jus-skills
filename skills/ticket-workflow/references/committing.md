# Committing

Read before your first `git commit` on the ticket.

## Commit conventions — THE MOST IMPORTANT STEP

**Commit the moment code and lint are done** — before self-review, before a comment or a transition, before replying to anyone. Sequence: code → lint → **COMMIT** → everything else. Never move on with a dirty working tree. One commit per ticket, tests included; a self-review fix is a second commit naming the same ticket.

The subject format is yours. End the message with the ticket trailer, as its **last paragraph** alongside any `Co-Authored-By:` — git reads only the final block, so a trailer anywhere else links nothing:

```text
Jus-Ticket: <n>
```

⚠️ **A breaking change is `BREAKING-CHANGE:`, never `BREAKING CHANGE:`.** The spaced key disqualifies the whole final paragraph, so the commit succeeds and the ticket silently never links. Bracket references that move a ticket, and why the reference stays out of the subject on a code host, are in [`hard-rules`](../SKILL.md#related-skills) → Commit Rules. **Never `git push`** — the stakeholder pushes.

⚠️ **A hook refuses a force-push and a `--no-verify`** on harnesses that run the jus hooks. It is silent where it cannot establish the rule, so its silence is not permission.
