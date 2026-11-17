# How this fork differs from upstream zmx

This folder is the session daemon of [Macterm](https://github.com/macterm/macterm).
It came from the fork `thdxg/zmx` (main at `2d98540`). The history of the fork
stays in that repository, which is archived. It no longer syncs with [upstream zmx](https://github.com/neurosnap/zmx).

- **Base:** upstream `v1.0.1` (`a35f00a`, in upstream and in `thdxg/zmx`).
- **Upstream fixes** are copied by hand, with their tests, when one is worth
  it. To see what upstream did since the base, in a clone of upstream:
  `git log a35f00a..main`.
- **Each change below was a patch** (`.github/downstream/00NN-*.patch`) that a
  daily sync applied again on top of upstream. The code now holds the changes
  directly. The numbers stay as names, because Macterm's history cites them.
  `77fc677` in `thdxg/zmx` is the last commit that has the patch files:
  in a clone of it, `git show 77fc677:.github/downstream/<name>` prints one.

## Changes

v1's verbs and daemon are deleted (macterm 0254, design/007 §6). A change
below that lived only in v1's code says so; its patch in `thdxg/zmx` keeps it.

### 0003: a client claims leadership without input

zmx gives leadership (the size of the pty) to the client that sends user
input. A GUI that shows one session in two panes needs to move it on a click,
without a keystroke reaching the program.

- Deleted with v1. A v2 client sends the `claim` message on its pane
  channel (`src/session.zig`, `test/session_v2.bats`).

### 0004: the daemon is its own responsible process on macOS

macOS gives privacy permissions (Local Network, TCC) to a process's
responsible process, which is fixed at spawn. A session that outlived the app
that started it belonged to nothing, and its programs got `EHOSTUNREACH` on
the local network with no prompt (macterm#419).

- Since issue 0269, the server spawns `zmx __session` with one `posix_spawn`
  that has `responsibility_spawnattrs_setdisclaim`. Before, the session
  started itself again with `POSIX_SPAWN_SETEXEC`, and its state rode
  `ZMX_DAEMON_*` variables.
- No process that keeps running calls `unsetenv`: zig 0.17's `std.Io` caches
  the environment block and panics on a shortened one.
- Code: `src/server.zig` (`spawnSession`), `src/main.zig`, `src/session.zig`.
- Test: `test/daemon_responsibility.bats` (Darwin only).

### 0005: attach creates a session quietly

`zmx attach` printed `session "<name>" created` and then cleared the screen.
In a pane one or two rows tall, the line scrolled into scrollback and came
back when the pane grew (macterm#487). With `run` gone, nothing prints the
line.

- Deleted with v1's `attach`. A v2 session prints nothing of its own.

### 0006: reattach replays the mouse mode set last

The terminal formatter replays the mouse format and event modes in numeric
order, not in the order the program set them. crossterm sets `?1015h` and
then `?1006h`, so a reattached client got urxvt reports and right click
stopped working. `serializeTerminalState` sets the effective modes again after
the replay. Remove this when the formatter replays the terminal's flags
itself.

- Code: `src/terminal.zig`.

### 0007, 0008, 0009: reattach replays logical lines

On reattach the daemon resizes its terminal to the client and serializes a
snapshot. A client that attaches before its window has its real size (a
placeholder grid, or Macterm's incubator) got rows cut at that width for good.

- 0007: the scrollback phase joins soft-wrapped rows, so the client reflows
  them at its own width.
- 0009: the visible-screen phase does the same. The client has the width the
  terminal was resized to, so the cursor lands on the same row.
- 0008: upstream adopted the linefeeds before the `ED 2` clear that keep the
  last scrollback rows (186393f). Only its tests stayed.
- Code and tests: `src/terminal.zig`.

### 0010: the daemon reports the foreground process

A frontend names a tab after the foreground program, warns before it closes a
busy pane, and shows an agent's logo. Over ssh it had to ask the host every
few seconds, and the answer was a round trip old (macterm#695).

- v2 sends the report as a `foreground` message on the pane channel, to a
  client that attached with `foreground: true` (`src/session.zig`). The rest
  of this section is the v1 form, which `zmx connect` still writes.
- A client started with `ZMX_FOREGROUND_EVENTS` subscribes. The daemon reads
  the pty's foreground process group before it forwards each chunk of output,
  and every 500 ms, and sends a `Foreground` message (tag 193) when it changes.
  The client writes it into stdout as an APC sequence, in front of the output
  it precedes.
- The report is `zmx;foreground;<idle>;<shell>;<comm>;<args>`. The variable
  and the prefix are a wire contract with Macterm.
- The daemon removes the variable in the child that execs the shell, so a
  nested `zmx connect` does not subscribe.
- Code: `src/foreground.zig`, `src/session.zig`, `src/attach.zig`,
  `src/pty.zig`.
- Tests: `src/foreground.zig`, `src/test.zig`.

### The daemon frees only what it allocated

Upstream's `Daemon.deinit` frees `socket_path`, but the caller of
`Daemon.init` allocated it with another allocator. In a ReleaseSafe build of
zig 0.17, `main`'s allocator is zig's `SafeAllocator` and the daemon's is
`c_allocator`, so each daemon that exited aborted with "pointer being freed
was not allocated" (macterm#720, Smoke on macOS 26). The caller now frees the
path.

- Deleted with v1's daemon.

### Removed: the commands Macterm never calls

Macterm calls `attach`, `list`, `kill`, `set` and `version`, and the macOS
daemon runs `__daemon`. These went, with their code and tests:

- `run`, `wait`, `-d` and the task tracking (the bash wrapper and the exit
  marker). `Info` keeps its `task_*` fields for the wire, at zero.
- `write`, `print`, `print-env` and the environment tracking behind it
  (`ZMX_TRACK_ENV`), `tail`, `detach` and `completions`.
- The Zig package (`src/lib.zig`, `-Ddaemon`) and `examples/`.
- The repository parts of zmx: the zmx.sh site, Docker, Nix and Homebrew
  files, its changelog and its workflows.

### Removed: v1 (macterm 0254)

The app runs no v1 verb. `attach`, `list`, `get`, `set`, `clear`, `history`,
`send`, `kill`, `__daemon` and their IPC (`ipc.zig`, `loop.zig`,
`client.zig`, `label.zig`, `cfg.zig`) are gone. A v1 session daemon that
still runs is v1.33.2's own build, which the app ends by its argv
(`V1Sessions`).

### ENXIO from `/dev/tty` is `NoDevice`

`posix.open` gave `Unexpected` for `ENXIO`, which printed `unexpected errno:
6` and a stack trace each time a process with no controlling terminal (the
daemon, a CI job) looked for the terminal size. It is `NoDevice` now
(thdxg/zmx#22).

- Code and test: `src/posix.zig`.

### Retired

- 0001 (cast `log_mode`) and 0002 (portable signal type): upstream fixed both.
- 0011 (the Linux guard of 0004): folded into 0004.

## CI

- `.github/workflows/server.yml` (at the repository root) builds the server
  and runs the Zig tests and the bats tests on macOS, Linux x86_64 and Linux
  aarch64, for each change to `server/`. A skipped test fails the job. Linux
  leaves out `daemon_responsibility.bats` (macOS only).
- The app bundles the build of this folder at the same commit
  (`scripts/build-server.sh`).
