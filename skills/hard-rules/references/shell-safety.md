# Shell safety — the full text

Read before sending prose through a shell command, or handing a person a command to run. `SKILL.md` states the rule; this file is the whole of it, with the reasons and the traps.

## Shell Safety — Prose and Commands

- **NEVER build a shell command by inlining prose you wrote.** Ticket comments, descriptions and commit bodies go through a **file plus a quoted heredoc** (`<<'EOF'`), then get passed as `"$(cat file)"` or piped in. This is not a formatting preference; it is an **arbitrary-command-execution** risk, because agent prose is full of the two characters that break shell quoting.

  Measured: an apostrophe in a possessive (`the hook's`) terminated a single-quoted argument, which left the rest of the sentence unquoted, which meant the **backticks around a command name in the prose were evaluated** — and the command ran. Nothing shipped only because a preflight refused on an unset variable. **One apostrophe ends a single-quoted string**; never assume prose is safe to interpolate.

- **NEVER hand a person a command long enough to wrap.** If it does not fit comfortably on one line, put it in a script that takes one short argument. A wrapped paste is not a cosmetic problem: a shell continues a line that _ends_ with `&&` and rejects one that _begins_ with it, so wrapping alone turns a working chain into a parse error — one that names neither the real cause nor the thing that failed to happen.

  Secret entry is the usual offender. **Never print a token file to check it is set** — `cat .jus/config/api_token.txt` puts a live secret in the transcript, and `jus whoami` answers the same question. **Never ask for a token to be pasted into a chat**; hand over a one-argument script that reads it without echoing. ⚠️ The hidden-input read is shell-specific and the forms are not interchangeable — check which shell the line will actually run under, since a script runs under its shebang and not the person's login shell.

- **zsh does not word-split an unquoted variable.** `lint $files` passes the whole list as one argument, so a scoped lint or test run can check nothing and still exit 0. Use an array, or inline the command that produces the list. zsh's `echo` also expands `\n` and other escapes, which corrupts a JSON body written through it. Use `printf '%s'` or a quoted heredoc.

- **A command handed to a person must not trap their terminal, and must say what it prints.** `gh` and `git` open a pager whenever their output is a terminal. A command an agent runs never has one, so the pager appears only for the person. Prefix `GH_PAGER=cat`, and put `--no-pager` before a `git` subcommand. Say what it prints, such as "prints the deployment JSON" or "prints nothing on success", so they can tell a result from a hang. A handed-over command may write the clipboard, but must **never read the clipboard**: copying the command overwrites it before the command runs.
