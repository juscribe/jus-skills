# Formatting — worked examples and the reaction legend

The rules are in [Formatting descriptions and comments](../SKILL.md#formatting-descriptions-and-comments). These are the examples behind them, and how to read the reactions on a comment.

## A start comment

A start comment shaped this way:

```markdown
Starting.

**Root cause:** `RejectionAutoDispatchJob#dispatchable?` checks policy and
marker type but never station reachability, so every rejection creates a
dispatch that immediately fails when no station is running.

**Plan:** guard with `workspace.online_agents_for(user).any?` — the same
reachability check the dispatch button uses.

**Tests:** failing job specs first (no station → no dispatch; station
registered elsewhere → no dispatch; reachable → dispatch as before).
```

## A fence inside a list item

⚠️ **A fence inside ANY list item must sit at the list's CONTENT column** — two spaces under a `- ` marker, not lined up under the text. Indent it further and CommonMark reads it as a lazy paragraph continuation, because an indented code block cannot interrupt a paragraph; inline parsing then treats the fence as a triple-backtick **code span**, collapses the newline, and the language tag becomes content. A step meant to read as a copyable command renders as `sh my-command` instead, with the `sh` glued to the front.

````text
WRONG — 6 spaces. Renders as one code span: `sh my-command --flag`
- [ ] 2. Run the thing:
      ```sh
      my-command --flag
      ```

RIGHT — 2 spaces. Renders as a code block.
- [ ] 2. Run the thing:
  ```sh
  my-command --flag
  ```
````

**The source looks correct either way**, which is why this needs stating rather than trusting a re-read. Check the rendered output, not the markdown.

## Comment reactions

`include_comments=true` returns a `reactions` array per comment. Interpret them as stakeholder signals:

- 👍 agreement / "good direction"
- 👎 disagreement / "wrong approach" — multiple 👎 from the stakeholder = effective rejection of that approach
- ❤️ strong approval
- 🤔 uncertainty / "think about this more"
- 🎉 celebration / "this is great"
- 👀 "I'm watching this" / "needs attention"
- 👍 on a suggestion = "yes, do this"

Toggle your own reaction on a comment with the nested endpoint — the same call adds and removes it:

```sh
jus api POST /workspaces/{ws}/tickets/{ticket_id}/comments/{id}/reactions/toggle '{"emoji":"👍"}'
```
