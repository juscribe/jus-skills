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

## Linking a pull request, where the GitHub integration is on

- **A pull request links from `[#N]` or `jus-N` in its title or body, or from a branch named `<N>-slug`.** Not from the `Jus-Ticket:` trailer, which is read on commits only, and not from `Closes #N`: a bare or parenthesised `#N` is ignored, because GitHub numbers pull requests from 1 as well.
- **The links follow the text.** Edit the reference out of the title or body and the link goes with it.
- **Commits pushed before the repository was linked never link**, even after it is.
- **Keywords that move a ticket (`[finishes #N]` and the rest) work only inside brackets, and only when the workspace has that setting on.** A pull request itself changes no ticket state.
