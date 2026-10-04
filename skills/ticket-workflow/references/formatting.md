# Formatting — worked examples and the reaction legend

The rules are in `references/delivering.md` → _Formatting descriptions and comments_. These are the examples behind them, and how to read the reactions on a comment.

## A start comment

A start comment shaped this way. Each paragraph is one line, because the board turns a single newline into a line break:

```markdown
Starting.

**Root cause:** `ExportJob#perform` retries on every error, a 404 from the storage API included, so an export whose file was deleted is retried forever and backs up the queue.

**Plan:** stop retrying on a 404, the same rule the upload job already follows.

**Tests:** failing job specs first (404 → no retry; 500 → retried as before; success → unchanged).
```

## A fence inside a list item

⚠️ **A fence inside ANY list item must sit at the list's CONTENT column** — two spaces under a `- ` marker, not lined up under the text. Indent it further and CommonMark reads it as a lazy paragraph continuation, because an indented code block cannot interrupt a paragraph; inline parsing then treats the fence as a triple-backtick **code span**, collapses the newline, and the language tag becomes content. A step meant to read as a copyable command renders as `sh my-command` instead, with the `sh` glued to the front.

````text
WRONG — 6 spaces. Renders as one code span: `sh my-command --flag`
- Run the thing:
      ```sh
      my-command --flag
      ```

RIGHT — 2 spaces. Renders as a code block.
- Run the thing:
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

**MCP:** no MCP tool adds a reaction. Add it in the app.
