---
name: macterm-subagents
description: Run other coding agents (Claude Code, Codex, Gemini CLI, OpenCode and the like) as sub-agents in their own Macterm tabs or split panes with the macterm CLI. Start one with a command, wait for its input prompt, type a task into it, follow its progress through pane list states and pane dump, answer its questions, and close it when it is done. Use when asked to run work in parallel with sub-agents, to hand a task to another agent in a terminal the user can watch, to check on or reply to an agent that runs in a Macterm pane, or to clean up agents that you started.
---

# Sub-agents in Macterm panes

An agent CLI that starts in its own tab or pane works where the user can watch it. It keeps running if
Macterm quits, because its zmx session keeps running. You can drive it fully with the `macterm` CLI:
`pane run` and `pane key` to type, `pane dump` to read the screen, `pane list` to follow its state.

## Ground rules

- **Reaching the CLI.** Inside a Macterm pane, `macterm` is in `PATH`, and `$MACTERM_SESSION` names that
  pane. A pane command with no target acts on the pane that it runs in. In any other place, run
  `/Applications/Macterm.app/Contents/Resources/bin/macterm`. Macterm must be running.
- **Targeting.** `--session <name>` is the stable address. Session names come from `macterm pane list`.
  They stay the same after the user quits and starts Macterm again. The CLI finds a session in the project
  that holds it. `--pane pane:2` is the second pane of the active tab (add `--tab` for another tab). It
  changes when splits change. An explicit target always wins over the fallback. Inside Macterm, the
  fallback is your own pane. Outside Macterm, it is the focused pane of the user.
- **Text after `--`.** In `pane run`, put the text after `--`. Macterm types it exactly as you wrote it:
  `macterm pane run --session macterm-api-8f327ce4a3f8 -- "ls -la"`. Before `--`, `pane run` reads its own
  flags at any place. It refuses a word that starts with `-` and types nothing.
- **One argument.** `pane run` joins its arguments with spaces after your shell removes their quotes.
  Pass the command line as one quoted string. The quotes inside it then stay.
- **The user's shell.** Macterm types the text into the login shell of the user. This can be nushell or
  fish. Put redirects, pipes, `&&`, variables and globs in `/bin/sh -c '…'`. Or write a script file and
  type `/bin/sh /path/to/script.sh`.
- **No terminal yet.** A pane in a tab that was never on the screen has no terminal. `pane run`, `key`,
  `dump` and `inspect` answer `no_surface`, and its `--run` command did not start. `macterm tab select`
  shows the tab. It also changes what the user sees.
- **`read_only` means ask.** The user can make a pane read-only. Then `pane run` and `pane key` answer
  `read_only` and type nothing. `macterm pane inspect` shows `read-only`. Do not try to turn it off. Ask
  the user.
- **Wait for a sentinel, not for a fixed time.** Make the command create a file when it ends, or print a
  marker that you assemble at run time: `printf done-%s 4f1c` prints `done-4f1c`. The echoed command line
  never contains it. Use a new random token each time. Give each wait loop a deadline.
- **`busy` means ask.** Closing a pane, a tab or a project answers `busy` while a program runs there.
  `layout apply` answers `busy` each time that it would close a pane. Nothing changed at that point. Ask
  the user before you try again with `--force`. That flag closes them anyway and kills the programs that
  run in them.
- **Results.** Exit 0 is success. Exit 1 means that Macterm refused the command (stderr says why). Exit 2
  means that no Macterm is reachable. Exit 64 means that the command line is malformed. stdout has output
  only on success. Every command except `macterm ssh` accepts `--json`.

## 1. Start it

Use a background tab. The view and the focus of the user do not change:

```sh
macterm project list --json
macterm tab new --project api --no-focus --run "claude" --json
macterm pane list --project api --tab 4 --json
```

Choose a project whose `path` holds the work. `--no-focus` starts the terminal also if that
project is not on the screen. Without it, a tab in another project can wait until someone views it. If
the app is too old for `--no-focus`, the command fails (exit 1) before it creates anything. It does not
take the focus in silence. `tab new` uses the active project by default. It does not use the project
of the caller, so pass `--project`. Its reply gives the `index` and the `id` of the new tab. With
either one, `pane list --tab` gives the `session` of its pane. To start the agent next to you, split
your own pane and do not take the focus. The reply is the new pane itself:

```sh
macterm pane split --direction right --no-focus --run "codex" --json
```

Outside Macterm, add `--session` with the name of the pane to split. Without it, you split the pane
that the user has focused. Keep the session name. Every later command targets it with `--session`. It
keeps working after Macterm restarts, and while the user looks at another project.

## 2. Wait for its prompt, then type the task

An agent needs a few seconds to start. It can ask something first, for example if it can trust the
folder. Read the screen until the input prompt of the agent shows:

```sh
macterm pane dump --session macterm-api-2a6f7e69fb6e
```

Poll it every second or two, with a deadline. Never type before the prompt is there. The keystrokes for
the task would answer a startup question. If a startup question is on the screen, ask the user, unless
the user already told you the answer. Then type the task and submit it:

```sh
macterm pane run --session macterm-api-2a6f7e69fb6e --no-submit -- "Fix the failing test in parser_test.go."
macterm pane key --session macterm-api-2a6f7e69fb6e return
```

`--no-submit` leaves the text in the input box of the agent. `pane key return` presses a real Return,
and an agent takes that as submit. A newline that you type can only add a line to the box. Read the
dump again to see that the agent started to work.

For a long prompt, or a prompt with several lines, write it to a file with your own tools. Then type
one line: `Read /tmp/task-4f1c.md and do what it says.` This keeps quoting, length and line breaks out
of the terminal. Also ask for a definite signal in the prompt. For example: "When you have finished,
create the file /tmp/task-4f1c.done". Wait for that file.

## 3. Follow it

```sh
macterm pane list --project api --json
macterm pane dump --session macterm-api-2a6f7e69fb6e | tail -40
```

Find the session of the agent in the list and read its `state`. `running` means that it produces
output. About 3 seconds after its output stops, the state changes to `done`. If the user looks at that
tab, it changes to `idle`. This means that the agent finished, or that it waits for you. It can wait for
a question, a choice or a permission prompt. The dump shows which. Check every 10 to 30 seconds. Do not
use a tight loop.

Answer it in the same way as you prompted it. Use text with `--no-submit`, then `pane key return`. For
a menu, use single keys (`pane key 1`, `pane key down`, `pane key return`, `pane key escape`). A
permission prompt is the decision of the user, unless the user gave you that authority.
`pane key ctrl+c` interrupts the agent.

## 4. Clean up

When you close a pane, its session ends and its scrollback is gone. Copy what you still need from
`pane dump --scrollback` first. Quit the agent with its own command (often `/exit` or `/quit`, if not,
`ctrl+c`). Check that the pane is back at a shell prompt. Then close it:

```sh
macterm pane run --session macterm-api-2a6f7e69fb6e --no-submit -- "/exit"
macterm pane key --session macterm-api-2a6f7e69fb6e return
macterm pane close --session macterm-api-2a6f7e69fb6e
```

When you close the only pane of a tab, the tab closes. `macterm tab close --project api 4` closes a
whole tab at once. Both commands answer `busy` while the agent, or anything else, still runs there.
Ask the user before you run the command again with `--force`. That flag kills the agent in the middle
of its work.

## Keeping this skill current

This file came from `macterm skills macterm-subagents`. If Macterm rejects a command shown here, the CLI changed
after you installed the skill. Install the skill again from the output of that command.
