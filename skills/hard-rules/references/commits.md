# Commit rules — the full text

Read before a commit whose message you are unsure of: the trailer, a breaking change, a bracket reference, or a code host's squash merge. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Commit Rules — THE MOST IMPORTANT CATEGORY

> **Commit is NOT optional, NOT deferrable, NOT something you "get to later."** The moment code changes are complete and linters pass, you commit. IMMEDIATELY. Before responding to the user. Before self-review commentary. Before anything else. An uncommitted change is invisible, unrecoverable, and a direct violation of this SOP.

- **COMMIT IMMEDIATELY after code changes.** The sequence is: code → lint → **COMMIT** → then everything else (self-review, comments, transitions, user communication). If you find yourself typing a response to the user and you haven't committed yet, **STOP and commit first.** This rule overrides any default "don't commit unless asked" behavior — for Juscribe work the user has explicitly and repeatedly asked for it.
- **Never move on with a dirty working tree** — not to answer a question, not to explain what you did, not to run additional checks. Commit first, talk second. Treat an uncommitted change with the same urgency as an unsaved file.
- **One commit per ticket**, self-contained: backend + frontend + tests together. Follow-up fixes from self-review get a second commit with the same ticket prefix.
- **The subject line format is yours to choose.** Nothing in Juscribe reads one, so use whatever your team already uses — Conventional Commits, a plain summary, anything. What matters is that the message carries a reference.
- **End the message with a `Jus-Ticket:` git trailer**, in the same block as any `Co-Authored-By:`:

  ```text
  Jus-Ticket: <n>
  ```

  Same mechanism as `Co-Authored-By:`, and it is the one reference form nothing writes by accident — not a code host, not a bot, not a markdown link. Conventional Commits defines its own footers in git-trailer format, so this is that spec's mechanism rather than merely compatible with it.

  ⚠️ **It is the LAST paragraph of the message or it is not a trailer.** Git reads only the final blank-line-separated block, every line of which has to be `Key: value`; one line of prose anywhere in that block disqualifies the whole of it, and a `Jus-Ticket:` line in the body links nothing.
  ⚠️ **A breaking change is `BREAKING-CHANGE:`, never `BREAKING CHANGE:`.** Conventional Commits spells it with a space; git requires a trailer key to be a single token, and such a line is none of the shapes git tolerates inside the block — so it disqualifies the **whole** final paragraph and takes `Jus-Ticket:` down with it. Nothing reports this: the commit succeeds and the ticket simply never links. The hyphenated form is that spec's own sanctioned synonym.
- **A bracket reference — `[#41]`, anywhere in the message — links as well**, and it is the **only** form that can move a ticket on the board: the commit automation reads `[finishes #41]` and its family, never a trailer. Use it alongside the trailer if your workspace has that turned on.
- ⚠️ **On a code host, keep the reference out of the subject line.** A squash merge on GitHub appends the pull request's own number — `Fix the thing (#41)` — under every message-format setting, and it cannot be turned off. Pull-request numbers and ticket ids are both dense integers from 1, which is why a bare or parenthesised `#41` is deliberately ignored. The trailer block and the message body are the two places the host does not write.
- **Never amend a delivered commit.** When a ticket is rejected, fix it in a NEW commit. `git commit --amend` on delivered work is forbidden.
- **NEVER `git push`.** The stakeholder pushes manually. Pushing breaks their workflow.

## A checkout another session may share

Two sessions in one repository share more than the files: the index, the stash, and the target branch.

- **In a checkout another session may share, commit only your own changes.** `git add -A` sweeps in their uncommitted work, and `git commit` takes the whole index, including whatever they have staged. Stage by path, and commit with `-- <paths>` so the pathspec, not the shared index, decides what lands:

  ```sh
  git commit -F msg.txt -- path/one path/two
  ```

  If a commit took someone else's file anyway, `git reset --soft HEAD~1` returns it to the index as they left it. Then commit again with the pathspec.
- **The stash stack is shared** by every worktree and session in the repository, so a bare `git stash pop` can apply someone else's work. Prefer a temporary commit. If you must stash, push it with a message of your own and restore that entry with `git stash apply <sha>`. ⚠️ `git stash pop` without `--index` puts every modified file back **unstaged**, so the next commit takes the new files and none of the edits, and nothing reports it. Re-stage, and read `git status --short` before committing.
- **Take a commit's SHA from the commit's own output**, never from a later `git log -1`. That answers "the newest commit", not "mine", and another session may have committed in between.
- **Before merging a branch, read what landed on the target since you branched** (`git log <base>..<target>`). Your fix may already be there under another ticket, filed by someone who described the bug in other words, and nothing on the board matches them.
