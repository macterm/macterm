---
name: macterm-panes
description: Run commands in Macterm terminal panes and read what they display, with the macterm CLI. Type into a pane with pane run, press keys with pane key, read the screen and scrollback with pane dump, check the foreground process with pane inspect, and follow the idle, running and done states in pane list. Use when asked to run something in a Macterm pane or tab, to look at what a Macterm terminal shows (an error, a log, a full-screen program), to wait for a command in a pane to finish, or to drive an interactive program there (a REPL, debugger, pager, editor or installer) that a pipe cannot reach.
---

# Running commands in Macterm panes

`macterm pane dump` reads the own cells of a terminal. You can therefore see what any pane shows, also
full-screen programs. `pane run` and `pane key` type into the pane. With these three commands you can
work in a terminal that you are not running in. Run a command where the user can watch it. Read the
result. Drive programs that never write to a pipe.

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

Type only into panes that you created or that the user pointed you to. Keystrokes that go to a pane in
which the user types land in the middle of their work.

## Find the pane

```sh
macterm pane list
```

```text
tab:1  pane:1  *  macterm-api-8f327ce4a3f8  nu      ~/dev/api      idle
tab:1  pane:2     macterm-api-1a2b3c4d5e6f  bash    ~/dev/api      running
tab:2  pane:1     macterm-api-9be4cfc35119  Python  ~/dev/api/web  done
```

The columns are these: the tab, the number of the pane in that tab, `*` on the focused pane, the session
name, the foreground process (the name of the shell itself at a shell prompt), the working directory
and the state. The list covers the active project. Add `--project <name>` for another project
(`macterm project list` shows the names). Add `--tab` for one tab. `--json` adds the `id` of each pane
and the `tabID` of its tab.

The state:

- `running`: Macterm sees work. A command that starts at the shell prompt counts until it exits. A
  full-screen program or a known agent CLI (claude, codex, gemini, opencode and others) counts while
  it keeps producing output.
- `done`: it stopped while nobody looked at that tab. When you type into the pane, or the user opens
  the tab, the state returns to `idle`. `pane dump` and `pane inspect` do not change it.
- `idle`: at a shell prompt, or finished and already seen.

Work that comes from output ends about 3 seconds after the output stops. A program that Macterm does
not know can read `idle` while it works. A REPL that computes in silence is an example. Treat the state
as a quick hint. Confirm it with a sentinel or with `pane dump`.

## Run a command and wait for it

```sh
macterm pane run --session macterm-api-8f327ce4a3f8 -- "/bin/sh -c 'make test; echo \$? > /tmp/make-4f1c.status'"
for i in $(seq 1 600); do [ -e /tmp/make-4f1c.status ] && break; sleep 0.5; done
cat /tmp/make-4f1c.status
macterm pane dump --session macterm-api-8f327ce4a3f8 --scrollback | tail -40
```

The output stays in the pane, where the user can see it. The status file receives the exit code. `\$?`
stops your own shell from expanding it, so the `/bin/sh` of the pane does. `pane run` prints the row of
the pane when the text arrived. This says nothing about the command itself.

In a remote project, the command runs on the remote host, so a local file never appears. Wait for a
marker in the text of the pane instead:

```sh
macterm pane run --session macterm-api-8f327ce4a3f8 -- "/bin/sh -c 'make test; printf done-%s 7d2e; echo'"
for i in $(seq 1 600); do
  macterm pane dump --session macterm-api-8f327ce4a3f8 --scrollback | grep -q done-7d2e && break
  sleep 1
done
```

Put anything that is longer than a line, or that has its own quotes, in a script file. Write it with
your own tools, then type `/bin/sh /tmp/job-4f1c.sh`.

## Read what a pane shows

- `macterm pane dump --session …` prints the visible screen as text, with the shell prompt and the
  echoed command lines. `--scrollback` prints everything that the pane still holds, oldest first.
  Filter it with `tail` or `grep`. Do not read thousands of lines. If the user scrolled the pane up,
  the visible screen is not the newest output. Search `--scrollback` for sentinels.
- `macterm pane inspect --session …` shows the grid size, the scrollback counts, and the process id and
  command line of the foreground process (the shell itself when nothing else runs). It also shows
  `needs confirm quit`. This is true while a program runs, and it makes closing that pane answer
  `busy`. The `alt-screen` value is only a guess. It reads true at a fresh shell prompt.

## Drive an interactive program

A REPL, debugger, pager, editor or installer reads keys, not a pipe. Start it. Wait until `pane dump`
shows that it is ready. Then send one step at a time and read the screen after each step:

```sh
macterm pane run --session macterm-api-8f327ce4a3f8 -- "python3 -q"
for i in $(seq 1 40); do
  macterm pane dump --session macterm-api-8f327ce4a3f8 | grep -q '^>>>' && break
  sleep 0.5
done
macterm pane run --session macterm-api-8f327ce4a3f8 --no-submit -- "print(sum(range(10)))"
macterm pane key --session macterm-api-8f327ce4a3f8 return
macterm pane dump --session macterm-api-8f327ce4a3f8 | tail -2
macterm pane key --session macterm-api-8f327ce4a3f8 ctrl+d
```

- `pane run --no-submit` types text and does not press Return. `pane key return` presses a real Return
  key. Use this pair for anything that is not a shell prompt. Plain `pane run` ends the text with a
  newline character. Shells and line-based REPLs take it as Enter, but a full-screen program can
  ignore it.
- `pane key` sends one key in each call: `return`, `escape`, `tab`, `space`, `up`, `down`, `left`,
  `right`, a letter or a digit, punctuation such as `;` or `/`, and key combinations such as `ctrl+c`,
  `ctrl+d`, `shift+a` (for `A`) or `shift+;` (for `:`). Letters are lowercase unless you add `shift+`.
  There are no names for backspace, delete, home, end or the function keys. Use the own keybinds of
  the program instead (`ctrl+u`, `ctrl+a`, `ctrl+e`, `ctrl+h`).
- `pane key ctrl+c` interrupts what runs.

A full-screen program redraws the whole screen. Plain `pane dump` therefore shows what it shows now,
and `--scrollback` adds nothing that it drew. This example edits a file in vim:

```sh
macterm pane run --session macterm-api-8f327ce4a3f8 -- "vim notes.txt"
macterm pane key --session macterm-api-8f327ce4a3f8 i
macterm pane run --session macterm-api-8f327ce4a3f8 --no-submit -- "a new first line"
macterm pane key --session macterm-api-8f327ce4a3f8 escape
macterm pane run --session macterm-api-8f327ce4a3f8 --no-submit -- ":wq"
macterm pane key --session macterm-api-8f327ce4a3f8 return
```

In a pager (`less`, `man`, `git log`), `pane key space` pages forward and `pane key q` quits.

## Showing the user

`macterm pane focus --session …` selects the tab of the pane, brings its window to the front and gives
it the keyboard. `macterm tab select` switches tabs. Both commands change what the user looks at. Use
them when the user asked to see something. Do not use them only to read or type. Every command above
works on a background pane after its tab was shown.

## Keeping this skill current

This file came from `macterm skills macterm-panes`. If Macterm rejects a command shown here, the CLI changed
after you installed the skill. Install the skill again from the output of that command.
