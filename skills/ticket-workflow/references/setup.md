# Setup — installing, authenticating and checking the `jus` CLI

Read when a `jus` command fails before it reaches the board, or the skills seem not to have loaded. The obligation is in `SKILL.md` → Phase 0; this is the detail behind it.

This SOP drives the Juscribe board through the **`jus` CLI**. The bundle ships the **skills and hooks only — not the CLI binary**, so before anything in this skill will work the user needs:

1. **The CLI** — `brew install juscribe/tap/jus`. No Homebrew? It installs from [brew.sh](https://brew.sh) first, on macOS, Linux, or Windows under WSL 2. Homebrew is the CLI's only channel.
2. **Auth + workspace** — `jus login` (API token) or `jus init` (token + workspace + `bin/jus` symlink). `jus init` also sets the `{ws}` used throughout this skill.

**Preflight.** If you're about to run `jus` and aren't sure it's configured, run `jus whoami` first and read the failure:

- `jus: command not found` → the CLI isn't installed. Tell the user to `brew install juscribe/tap/jus` — and, if `brew` is missing too, to install Homebrew from [brew.sh](https://brew.sh) first — then stop.
- `Error: No token available. Run 'jus login'…` → installed but unauthenticated. Tell the user to run `jus login` or `jus init`, then stop.
- `Error: Stored token is invalid or expired.` — or any `HTTP 401` from `jus api` — → the token was real and is now **retired**. API tokens expire: agent tokens 90 days after creation or last rotation, mobile sessions 60 days after last use. The 401 body names the remedy. Relay it and stop.
  - An **agent** token needs a **rotate** (Settings → Security → Agent Tokens), _not_ another `jus login` — re-authenticating hands back the same dead secret.
  - Tell the user which, then stop.
- `Error: Could not reach the Juscribe server at <base URL>` → **nothing is known about the token.** The request never got a reply, so this is a network problem: no connectivity, a sandbox denying outbound connections, or a wrong `JUSCRIBE_BASE_URL`. Curl's own line above it names which. Inside Codex's network-off sandbox the error says so and prints the setting to add (`network_access = true` under `[sandbox_workspace_write]`); relay that, and `jus doctor` flags the same. ⚠️ **Do not rotate anything** — a fresh token fails identically. Relay the base URL it tried, and stop.

⚠️ **`jus whoami` says nothing about whether THESE SKILLS loaded, and that is a separate failure.** A wizard can finish clean and leave the bundle absent — at which point an agent reads an SOP telling it the skills cover the workflow in more depth, goes looking, and finds nothing. `jus doctor` is the check:

```sh
jus doctor
```

Non-interactive, exit-coded, prompts for nothing. It reports the token, the workspace, the git repository and the skills surface — the plugin and its scope for Claude Code, the clone and the `.agents/skills/` links for every other tool — and prints the exact fix for whatever failed.

⚠️ **And a clone pull does NOT update an installed hook manifest.** Skills are symlinks, and every registration is now `jus hook <name>` with the bundle resolved at run time, so both move with a `git -C ~/.jus-skills pull`. Every manifest is a **copy**, so a change to which events an adapter registers reaches nobody who already installed. `jus doctor` names the missing registrations; `jus refresh-hooks` adds them, additively, so a hand edit survives — and migrates a manifest still naming `~/.jus-skills` before it merges, rather than leaving both commands live.

⚠️ **A passing verdict still names the reload, and that is not noise.** "Installed, but this session started before the install" leaves no trace on disk, so a clean registry is the only moment that case can be raised. It is the third of three states and the one people hit.

**Do not loop `jus` commands against an unconfigured CLI, or against a 401.** A 401 never heals by retrying; it is a credential the user must replace. Surface the single setup step the error points to and stop — one clear instruction beats a wall of repeated errors. Everything else in the skill assumes this preflight passed.
