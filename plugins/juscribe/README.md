# Juscribe for Claude

Read and change your Juscribe board from a Claude chat window. One install brings the Juscribe connector and three skills that carry the board's rules, so Claude files, moves and reviews tickets the way your team does.

## Use it

1. In Claude, open **Customize > Plugins > Add > Add marketplace** and enter `juscribe/jus-skills`.
2. Install **Juscribe**.
3. On the plugin's **Connectors** tab, connect Juscribe and sign in. On a Team or Enterprise plan, an Owner adds the connector first.

Then ask Claude about your board: what is in the backlog, file a bug, start a ticket, review the last iteration.

The skills are `ticket-workflow`, `hard-rules` and `retrospective`. They are the same skills as the `jus` plugin for Claude Code, which also carries hooks that need a shell. Use `jus` in a coding agent and this plugin in chat.

## Data

The connector sends your requests to `mcp.juscribe.ai`, which reads and writes your Juscribe workspaces as you, after you sign in. The plugin stores nothing itself.
