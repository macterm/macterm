#!/usr/bin/env python3
"""Session-layer benchmark.

Measures what the session layer (zmx, and ssh for remote panes) adds to
typing, reattach, memory and idle cost, for v1's and v2's panes side by side.
It runs no app: a pty driver plays the part of v1's terminal, and a socket
client plays the part of v2's app, so it runs on any CI runner, macOS or
Linux.

v1 is a frozen build (--v1-zmx): zmx 0.8.1, as v1.33.2 ran it. v2 is the
build of this commit (--zmx). Each layer is measured on the path that its
app used:

  v1         `zmx attach <s> <command>` on a pty: a v1 session daemon and an
             attach client for each pane.
  v2         a channel on one connection to the server's socket
             (LocalSessions, PaneSession): the session is made with
             `session.create`, and the app reads the channel itself.

Arms:

  bare       /bin/cat on a pty in line mode: kernel echo only. The floor.
  v1, v2     /bin/cat in a local pane.
  ssh        `ssh -tt <host> /bin/cat`. The floor for a remote pane.
  remote-v1  `ssh -tt <host> zmx attach <s> /bin/cat`: a remote pane of v1,
             one ssh login for each pane.
  remote-v2  a channel of `ssh -S <master> <host> zmx proxy`: every pane of
             the host on one stream over the host's one ssh connection
             (RemoteServers.Link, relay.zig).

Echo latency: write one key, time until the echo arrives, for --keys keys.
New remote pane: time to the first echo after the session prints its ready
marker. v1 logs in for each pane, from the start of its ssh. v2 makes the
session and opens a channel on the host's stream, from the request; the
report gives the login and the start of the stream on their own.
Relay flood: one channel of the relay prints as fast as it can while the
run times the keys of a second channel, channel 0's pings, and an interrupt
of the flood until its prompt shows. These are what the relay's skip-ahead
(relay.skip_ms, design/003 section 6) is for.
Reattach: fill a session with --reattach-lines lines of 200 columns, detach,
then time a new client until the echo of a marker line that is sent after the
client attaches. The echo comes after the replay. v1 starts an attach client;
v2 opens a channel.
Idle (macOS): open --idle-panes panes of /bin/cat in each layer, then read the
phys_footprint and the interrupt wakeups of the session side (v1: the daemons; v2: the
server and the sessions) and of the clients (v1: the attach clients; v2: none,
because the app reads the channels itself). The programs in the panes are not
counted: they are the same in both layers.

Every v1/v2 pair runs in one run on one runner, alternated: the echo keys go
in rounds to v1 and v2 in turn, the reattaches alternate, and the idle panes
of both layers are measured in the same window. A shared runner changes
speed over minutes, so a pair is compared only within one run.

Load decides latency on a shared runner, so each measurement first waits for
the 1-minute load average to drop below --max-load and records the load.

Subcommands:
  run     measure every arm, write a results JSON
  report  render one or more results JSONs as markdown
  limits  write the gate's limits from the spread of --min-runs runs
  check   exit 1 when v2 is worse than v1 beyond the limits (the CI gate)
"""

import argparse
import fcntl
import json
import math
import os
import select
import shlex
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time
import uuid

from _harness import phys_footprint, runner_info, wait_for_load, wakeups

# The protocol helpers of the server's own tests.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server", "test"))
from v2client import CONTROL, MSG, RelayClient, hello, unpack  # noqa: E402

COLUMNS = 200
ROWS = 50
DETACH_KEY = b"\x1c"  # ctrl+\: zmx detaches the current client.
LAYERS = ("v1", "v2")


class BenchError(Exception):
    pass


# ── The pty driver ───────────────────────────────────────────────────────


class PtyProgram:
    """One program on a new pty, as a terminal would run it."""

    def __init__(self, argv, env=None):
        self.argv = argv
        self.started = time.monotonic()
        pid, fd = os.forkpty()
        if pid == 0:
            try:
                winsize = struct.pack("HHHH", ROWS, COLUMNS, 0, 0)
                fcntl.ioctl(0, termios.TIOCSWINSZ, winsize)
                os.execvpe(argv[0], argv, env or os.environ)
            finally:
                os._exit(127)
        self.pid = pid
        self.fd = fd
        self.output = bytearray()

    def write(self, data):
        os.write(self.fd, data)

    def read_available(self, timeout):
        """Read what arrives within timeout. Returns the new bytes."""
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return b""
        try:
            data = os.read(self.fd, 65536)
        except OSError:  # EIO: the program closed the pty.
            raise BenchError(f"{self.argv[0]} closed its terminal: {self.tail()}")
        if not data:
            raise BenchError(f"{self.argv[0]} closed its terminal: {self.tail()}")
        self.output += data
        return data

    def read_until(self, needle, timeout, since=None):
        """Read until needle is in the output after offset `since`. Returns
        the time it arrived."""
        position = len(self.output) if since is None else since
        deadline = time.monotonic() + timeout
        while self.output.find(needle, position) < 0:
            # Search only the new bytes next time. A needle can arrive split
            # across reads, so look back by its length less one.
            position = max(position, len(self.output) - len(needle) + 1)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BenchError(
                    f"timed out after {timeout:.0f}s waiting for {needle!r} from "
                    f"{self.argv[0]}: {self.tail()}"
                )
            self.read_available(remaining)
        return time.monotonic()

    def drain(self, quiet=0.2, limit=5.0):
        """Read until the program is quiet for `quiet` seconds."""
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            if not self.read_available(quiet):
                return

    def is_raw(self):
        """Whether the program has taken the terminal (echo and line mode
        off). Before that, the pty's own line discipline echoes, and a key
        written then would time the kernel and not the program."""
        lflag = termios.tcgetattr(self.fd)[3]
        return not lflag & (termios.ECHO | termios.ICANON)

    def wait_raw(self, timeout):
        deadline = time.monotonic() + timeout
        while not self.is_raw():
            if time.monotonic() >= deadline:
                raise BenchError(f"{self.argv[0]} did not take the terminal: {self.tail()}")
            # Keep the pty drained, so a client that writes first never blocks.
            self.read_available(0.001)
        return time.monotonic()

    def wait_exit(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.pid = None
                return True
            try:
                self.read_available(0.05)
            except BenchError:
                pass
        return False

    def close(self):
        if self.pid is not None:
            try:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            self.pid = None
        try:
            os.close(self.fd)
        except OSError:
            pass

    def tail(self):
        return bytes(self.output[-300:]).decode("utf-8", "replace")


class RelayStream(RelayClient):
    """The app's end of a connection to a server (v2client.RelayClient),
    with these changes for a benchmark: each channel keeps only the tail of
    its output, so a flood costs no memory, and every wait has a monotonic
    deadline. With `argv`, the stream is the stdio of that command (`ssh …
    zmx proxy`); with `path`, it is a connection to the server's socket, as
    the app's own to the local server."""

    TAIL = 64 * 1024

    def __init__(self, argv=None, path=None):
        # Before the hello that RelayClient's init sends.
        self.tail, self.received, self.messages_of = {}, {}, {}
        if argv:
            super().__init__(argv=argv)
            return
        self.proc = None
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buf = bytearray()
        self.closed = False
        self.skip_to = None
        self.next_id = 1
        self.control = []
        self.send_msg(CONTROL, hello())

    def pump(self, timeout=0.05):
        ready, _, _ = select.select([self.sock], [], [], timeout)
        if not ready:
            return False
        data = self.sock.recv(1 << 20)
        if not data:
            exit_status = f" (proxy exit {self.proc.poll()})" if self.proc else ""
            raise BenchError(f"the stream to the server closed{exit_status}")
        self.buf += data
        i = 0
        while len(self.buf) - i >= 9:
            n, channel, kind = struct.unpack_from("<IIB", self.buf, i)
            if len(self.buf) - i < 9 + n:
                break
            body = bytes(self.buf[i + 9:i + 9 + n])
            i += 9 + n
            if channel == CONTROL:
                self.control.append(unpack(body)[0])
            elif kind == MSG:
                self.messages_of.setdefault(channel, []).append(unpack(body)[0])
            else:
                self.tail[channel] = (self.tail.get(channel, b"") + body)[-self.TAIL:]
                self.received[channel] = self.received.get(channel, 0) + n
        del self.buf[:i]
        return True

    def wait(self, pred, timeout=10, what="condition"):
        deadline = time.monotonic() + timeout
        while not pred():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BenchError(f"timed out after {timeout:.0f}s waiting for {what} on the relay")
            self.pump(min(remaining, 0.05))
        return time.monotonic()

    def drain(self, quiet=0.2, limit=5.0):
        """Read until the stream is quiet for `quiet` seconds."""
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline and self.pump(quiet):
            pass

    def call(self, method, timeout=30, **args):
        response = self.request(method, timeout, **args)
        if "ok" not in response:
            raise BenchError(f"{method} failed: {response}")
        return response["ok"]

    def ping(self):
        """The time of one round trip on channel 0, in ms."""
        start = time.monotonic()
        self.call("ping")
        return (time.monotonic() - start) * 1000

    def open(self, session):
        return super().open(session, cols=COLUMNS, rows=ROWS)

    def wait_output(self, channel, needle, timeout=10):
        """Wait until needle is in the channel's output that comes from now
        on. Returns the time it arrived."""
        start = self.received.get(channel, 0)

        def arrived():
            new = self.received.get(channel, 0) - start
            return new > 0 and needle in self.tail.get(channel, b"")[-(new + len(needle) - 1):]

        return self.wait(arrived, timeout, repr(needle))

    def close_channel(self, channel):
        self.call("channel.close", channel=channel)

    def snapshots(self, channel):
        return sum(1 for m in self.messages_of.get(channel, []) if m.get("t") == "snapshot.start")

    def close(self):
        self.sock.close()
        if not self.proc:
            return
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


def echo_latencies(program, keys, line_length=40):
    """Write `keys` keys one at a time; return each echo time in ms. Every
    line_length keys a newline ends the line (a canonical pty holds at most
    MAX_CANON bytes), and the line's own output is drained untimed."""
    letters = b"abcdefghijklmnopqrstuvwxyz"
    samples = []
    for i in range(keys):
        key = letters[i % len(letters):i % len(letters) + 1]
        offset = len(program.output)
        start = time.monotonic()
        program.write(key)
        end = program.read_until(key, timeout=10, since=offset)
        samples.append((end - start) * 1000)
        if (i + 1) % line_length == 0:
            program.write(b"\n")
            program.drain()
    program.write(b"\n")
    program.drain()
    return samples


def relay_echo_latencies(stream, channel, keys, line_length=40):
    """echo_latencies for a channel of the relay."""
    letters = b"abcdefghijklmnopqrstuvwxyz"
    samples = []
    for i in range(keys):
        key = letters[i % len(letters):i % len(letters) + 1]
        start = time.monotonic()
        stream.type(channel, key.decode())
        samples.append((stream.wait_output(channel, key, 10) - start) * 1000)
        if (i + 1) % line_length == 0:
            # cat prints the line back, with the letter of the next key.
            stream.type(channel, "\n")
            stream.drain()
    stream.type(channel, "\n")
    stream.drain()
    return samples


def summarize(samples):
    ordered = sorted(samples)

    def pct(p):
        index = min(len(ordered) - 1, max(0, round(p / 100 * len(ordered)) - 1))
        return round(ordered[index], 3)

    return {
        "n": len(ordered),
        "p50_ms": round(statistics.median(ordered), 3),
        "p95_ms": pct(95),
        "p99_ms": pct(99),
        "max_ms": round(ordered[-1], 3),
    }


# The interval between two presses of Return while the bench waits for a
# ready marker.
POKE_INTERVAL = 0.25


def poke_until(send, wait, timeout):
    """Press Return with `send` until `wait` sees the ready marker. The
    session's program prints the marker only after it reads a line (see
    Bench.ready_cat), so the marker always arrives at an attached client.
    A Return that a remote client gets before zmx runs can be lost, so
    the bench presses it again. Returns the time that the marker arrived."""
    deadline = time.monotonic() + timeout
    while True:
        send()
        try:
            return wait(min(POKE_INTERVAL, max(0.01, deadline - time.monotonic())))
        except BenchError:
            if time.monotonic() >= deadline:
                raise


def wait_ready(program, takes_terminal=True, marker=None, timeout=30):
    """Wait until the program has the terminal and its far end echoes. A
    program that does not take the terminal (bare cat) echoes through the
    pty's own line discipline. With a marker, wait for the session to print
    it first: an ssh client takes the terminal before the remote side runs
    zmx, and the remote pty would echo a key before zmx has it."""
    if takes_terminal:
        program.wait_raw(timeout)
    if marker:
        poke_until(lambda: program.write(b"\r"),
                   lambda t: program.read_until(marker.encode(), t, since=0), timeout)
    offset = len(program.output)
    program.write(b"@")
    first_echo = program.read_until(b"@", timeout, since=offset)
    program.write(b"\n")
    program.drain()
    return first_echo


# ── Arms ─────────────────────────────────────────────────────────────────


def alternated(index):
    """The order of the two layers in round `index`: v1 first, then v2 first."""
    return LAYERS if index % 2 == 0 else LAYERS[::-1]


class PtyPane:
    """A v1 pane: its attach client on a pty."""

    def __init__(self, program):
        self.program = program

    def echo(self, keys):
        return echo_latencies(self.program, keys)

    def close(self):
        self.program.close()


class ChannelPane:
    """A v2 pane: a channel on the app's stream to a server."""

    def __init__(self, stream, channel):
        self.stream = stream
        self.channel = channel

    def echo(self, keys):
        return relay_echo_latencies(self.stream, self.channel, keys)

    def close(self):
        try:
            self.stream.close_channel(self.channel)
        except (BenchError, AssertionError, OSError):
            pass


class Bench:
    def __init__(self, args):
        self.args = args
        self.nonce = uuid.uuid4().hex[:8]
        # /tmp, not $TMPDIR: socket paths must fit sun_path.
        self.zmx_dir = tempfile.mkdtemp(prefix="macterm-session-bench-", dir="/tmp")
        # v2's server and sessions live in the runtime directory. Without
        # this, they would be the user's own (TMPDIR/macterm).
        self.runtime_dir = os.path.join(self.zmx_dir, "run")
        self.env = dict(
            os.environ, ZMX_DIR=self.zmx_dir, MACTERM_RUNTIME_DIR=self.runtime_dir,
            TERM="xterm-256color",
        )
        # The host's runtime directory, also when the host is this machine.
        self.host_runtime_dir = os.path.join(self.zmx_dir, "host")
        self.control_path = os.path.join(self.zmx_dir, "cm")
        self.master = None
        # The app's stream to the local server, and to the host's server.
        self.local = None
        self.remote = None
        self.local_sessions = []
        self.remote_sessions = []

    def session(self, label, remote=False):
        name = f"bench-{label}-{self.nonce}"
        (self.remote_sessions if remote else self.local_sessions).append(name)
        return name

    def ready_cat(self):
        """The session's program: read a line, print a ready marker, then cat.
        Returns the command and the marker. The bench presses Return to start
        it (poke_until): v1 sends a new session's first client no output from
        before the client attached. The marker is two words in the script,
        so the echo of the command line never matches it."""
        marker = f"ready-{self.nonce}"
        script = f"read -r _; printf '%s-%s\\n' ready {self.nonce}; exec /bin/cat"
        return ["/bin/sh", "-c", script], marker

    def v1_attach(self, name, command=None):
        """The client of a local v1 pane. With a command, it makes the
        session when none has the name; without, it attaches to it."""
        return [self.args.v1_zmx, "attach", name, *(command or [])]

    def ssh(self, remote_command, master=False):
        """A remote pane's ssh. With master, a channel over the run's one
        connection, with the options of the app's (SSHConnections.ttyArguments):
        it never logs in by itself."""
        options = (
            ["-S", self.control_path, "-o", "ProxyCommand=/usr/bin/false"] if master
            else ["-o", "StrictHostKeyChecking=no"]
        )
        return ["ssh", "-tt", "-o", "BatchMode=yes", *options, self.args.ssh_host, remote_command]

    def remote_zmx(self, binary, *words):
        # The host's sessions live in directories of this run, as the local
        # ones do.
        return " ".join(
            [f"ZMX_DIR={shlex.quote(self.zmx_dir)}",
             f"MACTERM_RUNTIME_DIR={shlex.quote(self.host_runtime_dir)}", shlex.quote(binary)]
            + [shlex.quote(word) for word in words]
        )

    def start_master(self):
        """Open the host's one ssh connection, as SSHConnections does. Returns
        the time of the login in ms."""
        start = time.monotonic()
        self.master = subprocess.Popen(
            ["ssh", "-M", "-N", "-S", self.control_path, "-o", "BatchMode=yes",
             "-o", "StrictHostKeyChecking=no", self.args.ssh_host],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        # ssh makes the control socket after the login.
        deadline = start + 30
        while not os.path.exists(self.control_path):
            if self.master.poll() is not None:
                raise BenchError(f"the ssh master exited: {self.master.stderr.read().decode()}")
            if time.monotonic() > deadline:
                raise BenchError("the ssh master did not log in in 30 s")
            time.sleep(0.002)
        return (time.monotonic() - start) * 1000

    def stop_master(self):
        if not self.master:
            return
        subprocess.run(["ssh", "-S", self.control_path, "-O", "exit", self.args.ssh_host],
                       capture_output=True, timeout=10, check=False)
        try:
            self.master.wait(10)
        except subprocess.TimeoutExpired:
            self.master.kill()
            self.master.wait()
        self.master = None

    def relay(self):
        """A stream of `zmx proxy` on the host, over the host's connection.
        Its first one starts the host's server."""
        stream = RelayStream(
            ["ssh", "-S", self.control_path, "-o", "BatchMode=yes",
             "-o", "ProxyCommand=/usr/bin/false", self.args.ssh_host,
             self.remote_zmx(self.args.zmx, "proxy")]
        )
        stream.wait(lambda: stream.control, 30, "the server's hello")
        return stream

    def start_remote(self):
        """Open the app's stream to the host's server. Returns its time in ms."""
        start = time.monotonic()
        self.remote = self.relay()
        return (time.monotonic() - start) * 1000

    def local_stream(self):
        """The app's stream to the local server: it starts the server, then
        connects to its socket (LocalServer.connect)."""
        if not self.local:
            subprocess.run([self.args.zmx, "server"], env=self.env, capture_output=True,
                           timeout=30, check=True)
            self.local = RelayStream(path=os.path.join(self.runtime_dir, ".server"))
            self.local.wait(lambda: self.local.control, 30, "the server's hello")
        return self.local

    def open_pane(self, layer, name, command, marker, remote=False):
        """Make a session that runs the command, and attach a pane to it.
        Returns the pane and the time in ms from its start to its first
        echo: from the start of the client for v1, from the request for v2."""
        if layer == "v1":
            argv = (
                self.ssh(self.remote_zmx(self.args.v1_zmx, "attach", name, *command)) if remote
                else self.v1_attach(name, command)
            )
            program = PtyProgram(argv, self.env)
            first_echo = wait_ready(program, marker=marker)
            return PtyPane(program), (first_echo - program.started) * 1000
        stream = self.remote if remote else self.local_stream()
        start = time.monotonic()
        stream.call("session.create", id=name, command=[word.encode() for word in command],
                    cols=COLUMNS, rows=ROWS)
        channel = stream.open(name)
        poke_until(lambda: stream.type(channel, "\r"),
                   lambda t: stream.wait(lambda: marker.encode() in stream.tail.get(channel, b""),
                                         t, repr(marker)), 30)
        stream.type(channel, "@")
        first_echo = stream.wait_output(channel, b"@", 30)
        stream.type(channel, "\n")
        stream.drain()
        return ChannelPane(stream, channel), (first_echo - start) * 1000

    def gate(self):
        return wait_for_load(self.args.max_load, self.args.load_timeout)

    def echo_arm(self, name, argv, takes_terminal=True, marker=None):
        gate = self.gate()
        print(f"{name}: load {gate['load']}, {self.args.keys} keys", flush=True)
        program = PtyProgram(argv, self.env)
        try:
            wait_ready(program, takes_terminal, marker)
            result = summarize(echo_latencies(program, self.args.keys))
        finally:
            program.close()
        result["load_gate"] = gate
        print(f"  {result}", flush=True)
        return result

    def echo_pair(self, remote=False):
        """Echo latency of a v1 and a v2 pane, both open, the keys in rounds
        that alternate between them. Returns the arms by name: `v1` and `v2`,
        or `remote-v1` and `remote-v2`."""
        prefix = "remote-" if remote else ""
        rounds = self.args.rounds
        per_round = max(1, self.args.keys // rounds)
        gate = self.gate()
        print(f"echo {prefix}v1/v2: load {gate['load']}, {rounds} rounds of {per_round} keys",
              flush=True)
        command, marker = self.ready_cat()
        panes, samples = {}, {layer: [] for layer in LAYERS}
        try:
            for layer in LAYERS:
                name = self.session(f"{prefix}echo-{layer}", remote=remote)
                panes[layer], _ = self.open_pane(layer, name, command, marker, remote)
            for i in range(rounds):
                for layer in alternated(i):
                    samples[layer] += panes[layer].echo(per_round)
        finally:
            for pane in panes.values():
                pane.close()
        results = {}
        for layer in LAYERS:
            result = summarize(samples[layer])
            result["load_gate"] = gate
            results[prefix + layer] = result
            print(f"  {prefix}{layer}: {result}", flush=True)
        return results

    def remote_open_pair(self):
        """Time new remote panes, until the first echo: v1 logs in for each,
        v2 makes the session and opens a channel on the host's stream. The
        two alternate."""
        gate = self.gate()
        print(f"remote-open v1/v2: load {gate['load']}, {self.args.panes} panes each", flush=True)
        command, marker = self.ready_cat()
        samples = {layer: [] for layer in LAYERS}
        for i in range(self.args.panes):
            for layer in alternated(i):
                name = self.session(f"open-{layer}-{i}", remote=True)
                pane, elapsed = self.open_pane(layer, name, command, marker, remote=True)
                pane.close()
                samples[layer].append(elapsed)
        results = {}
        for layer in LAYERS:
            result = summarize(samples[layer])
            result["load_gate"] = gate
            result["sum_ms"] = round(sum(samples[layer]), 3)
            results[f"remote-open-{layer}"] = result
            print(f"  remote-open-{layer}: {result}", flush=True)
        return results

    def relay_flood(self):
        """While one channel prints as fast as it can: the keys of a second
        channel, channel 0's pings, and the time from an interrupt of the
        flood to its prompt. Returns the arms by name."""
        gate = self.gate()
        print(f"relay flood: load {gate['load']}, {self.args.floods} floods", flush=True)
        stream = self.relay()
        keys, pings, interrupts, skips, flood_bytes, flood_seconds = [], [], [], [], [], []
        try:
            names = {}
            for role in ("flood", "quiet"):
                names[role] = self.session(f"relay-{role}", remote=True)
                stream.call("session.create", id=names[role], command=[b"/bin/sh"])
            flood, quiet = stream.open(names["flood"]), stream.open(names["quiet"])
            stream.type(quiet, "stty -echo; printf '%s-%s\\n' quiet ready\r")
            stream.wait_output(quiet, b"quiet-ready", 30)
            stream.type(flood, "stty -echo; printf '%s-%s\\n' flood ready\r")
            stream.wait_output(flood, b"flood-ready", 30)
            line = "0123456789" * 19
            for i in range(self.args.floods):
                skipped, received = stream.snapshots(flood), stream.received.get(flood, 0)
                started = time.monotonic()
                stream.type(flood, f"while :; do printf '%s\\n' {line}; done\r")
                # Let the flood fill every buffer on the way.
                stream.wait(lambda: stream.received.get(flood, 0) - received > 4 << 20, 60,
                            "4 MiB of flood")
                for k in range(self.args.flood_keys):
                    pings.append(stream.ping())
                    token = f"k{i}x{k}y"
                    start = time.monotonic()
                    stream.type(quiet, f"printf '%s-%s\\n' key {token}\r")
                    keys.append((stream.wait_output(quiet, f"key-{token}".encode(), 30) - start) * 1000)
                start = time.monotonic()
                flood_seconds.append(start - started)
                stream.type(flood, "\x03")
                stream.type(flood, f"printf '%s-%s\\n' back {i}\r")
                interrupts.append((stream.wait_output(flood, f"back-{i}".encode(), 60) - start) * 1000)
                # A skip ahead comes as a snapshot: let one that is on its way land.
                stream.drain()
                skips.append(stream.snapshots(flood) - skipped)
                flood_bytes.append(stream.received.get(flood, 0) - received)
        finally:
            stream.close()
        results = {
            "relay-flood-key": summarize(keys),
            "relay-flood-ping": summarize(pings),
            "relay-flood-interrupt": summarize(interrupts),
        }
        for result in results.values():
            result["load_gate"] = gate
        results["relay-flood-interrupt"]["skips"] = skips
        # What the client got until the interrupt. With no skip, this is
        # the link's rate.
        results["relay-flood-interrupt"]["received_mb_per_s"] = [
            round(b / 1048576 / t, 1) for b, t in zip(flood_bytes, flood_seconds)
        ]
        for arm, result in results.items():
            print(f"  {arm}: {result}", flush=True)
        return results

    def fill_script(self):
        """A program that reads a line, prints --reattach-lines lines, then a
        marker, then answers each line that it reads with `got-<line>`. The
        bench presses Return to start it, as for ready_cat. Returns the
        command and the marker."""
        marker = f"fill-done-{self.nonce}"
        # 6 characters of line number and 193 dots: 199 columns, so that no
        # line wraps on the 200-column terminal.
        script = (
            "read -r _; "
            f'i=0; while [ $i -lt {self.args.reattach_lines} ]; do printf "%05d %s\\n" $i "{"." * 193}"; '
            f"i=$((i+1)); done; printf '%s\\n' {marker}; stty -echo; "
            "exec awk '{print \"got-\" $0; fflush()}'"
        )
        return ["/bin/sh", "-c", script], marker

    def fill(self, layer):
        """Make a session of the layer that has printed the fill script's
        lines, with no client. Returns its name."""
        name = self.session(f"reattach-{layer}")
        command, marker = self.fill_script()
        if layer == "v2":
            stream = self.local_stream()
            stream.call("session.create", id=name, command=[word.encode() for word in command],
                        cols=COLUMNS, rows=ROWS)
            channel = stream.open(name)
            stream.type(channel, "\r")
            stream.wait(lambda: marker.encode() in stream.tail.get(channel, b""), 120, repr(marker))
            stream.close_channel(channel)
            return name
        fill = PtyProgram(self.v1_attach(name, command), self.env)
        try:
            fill.wait_raw(30)
            fill.write(b"\r")
            fill.read_until(marker.encode(), timeout=120, since=0)
            fill.write(DETACH_KEY)
            if not fill.wait_exit(10):
                raise BenchError("the v1 client did not detach")
        finally:
            fill.close()
        return name

    def reattach(self, layer, name, token):
        """Attach to the filled session and send the token. Returns the time
        in ms until its answer, and the bytes that the client got."""
        if layer == "v2":
            stream = self.local_stream()
            start = time.monotonic()
            channel = stream.open(name)
            stream.type(channel, f"{token}\n")
            end = stream.wait_output(channel, f"got-{token}".encode(), 60)
            replay = stream.received.get(channel, 0)
            stream.close_channel(channel)
            return (end - start) * 1000, replay
        program = PtyProgram(self.v1_attach(name), self.env)
        try:
            program.wait_raw(30)
            program.write(f"{token}\n".encode())
            end = program.read_until(f"got-{token}".encode(), timeout=60, since=0)
            program.write(DETACH_KEY)
            program.wait_exit(10)
            return (end - program.started) * 1000, len(program.output)
        finally:
            program.close()

    def reattach_pair(self):
        names = {layer: self.fill(layer) for layer in LAYERS}
        gate = self.gate()
        print(f"reattach v1/v2: load {gate['load']}, {self.args.reattach_lines} lines, "
              f"{self.args.attaches} attaches each", flush=True)
        samples = {layer: [] for layer in LAYERS}
        replay_bytes = {layer: [] for layer in LAYERS}
        for i in range(self.args.attaches):
            for layer in alternated(i):
                elapsed, replay = self.reattach(layer, names[layer], f"m{self.nonce}{layer}r{i}x")
                samples[layer].append(elapsed)
                replay_bytes[layer].append(replay)
        results = {}
        for layer in LAYERS:
            result = summarize(samples[layer])
            result["lines"] = self.args.reattach_lines
            result["columns"] = COLUMNS
            result["replay_bytes"] = int(statistics.median(replay_bytes[layer]))
            result["load_gate"] = gate
            results[layer] = result
            print(f"  {layer}: {result}", flush=True)
        return results

    # ── Idle cost (macOS) ──

    def server_pid(self):
        """The pid of v2's server, from its socket (LOCAL_PEERPID)."""
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(os.path.join(self.runtime_dir, ".server"))
            return struct.unpack("i", sock.getsockopt(0, 2, 4))[0]  # SOL_LOCAL, LOCAL_PEERPID
        except OSError as exc:
            raise BenchError(f"no v2 server in {self.runtime_dir}: {exc}")
        finally:
            sock.close()

    def session_pids(self, binary, entry, names):
        """The pids of the session processes (`<binary> <entry> <name> …`)
        of these names: v1's `__daemon`, v2's `__session`."""
        listing = subprocess.run(
            ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True
        ).stdout
        pids = []
        for line in listing.splitlines():
            pid, _, command = line.strip().partition(" ")
            if not command.startswith(binary + " "):
                continue
            words = command[len(binary):].split()
            if len(words) >= 2 and words[0] == entry and words[1] in names:
                pids.append(int(pid))
        if len(pids) != len(names):
            raise BenchError(f"found {len(pids)} {entry} processes for {len(names)} sessions")
        return pids

    def idle_groups(self, panes, names):
        """The pids to measure: for each layer, its session side and its
        clients. v2 has no client process: the app reads the channels. The
        programs in the panes are left out."""
        return {
            ("v1", "session"): self.session_pids(self.args.v1_zmx, "__daemon", names["v1"]),
            ("v2", "session"): [self.server_pid(),
                                *self.session_pids(self.args.zmx, "__session", names["v2"])],
            ("v1", "client"): [pane.program.pid for pane in panes["v1"]],
            ("v2", "client"): [],
        }

    def idle_sample(self, groups):
        """The median footprint of each group over three reads, then its
        wakeups over --idle-seconds."""
        def read(measure, pids):
            values = [measure(pid) for pid in pids]
            if None in values:
                raise BenchError("a session process ended during the idle measurement")
            return sum(values)

        footprints = {group: [] for group in groups}
        for _ in range(3):
            for group, pids in groups.items():
                footprints[group].append(read(phys_footprint, pids))
            time.sleep(1)

        before = {group: read(wakeups, pids) for group, pids in groups.items()}
        start = time.monotonic()
        time.sleep(self.args.idle_seconds)
        elapsed = time.monotonic() - start
        after = {group: read(wakeups, pids) for group, pids in groups.items()}

        result = {}
        for (layer, side), pids in groups.items():
            data = result.setdefault(layer, {})
            data[f"{side}_mb"] = round(statistics.median(footprints[(layer, side)]) / 1048576, 2)
            data[f"{side}_wakeups_per_s"] = round(
                (after[(layer, side)] - before[(layer, side)]) / elapsed, 2
            )
            data[f"{side}_processes"] = len(pids)
        return result

    def idle_pair(self):
        """Footprint and wakeups of idle panes, v1 and v2 open at once, at
        each size of --idle-panes."""
        sizes = sorted(set(self.args.idle_panes))
        gate = self.gate()
        print(f"idle v1/v2: load {gate['load']}, {sizes} panes, "
              f"{self.args.idle_seconds}s windows", flush=True)
        command, marker = self.ready_cat()
        panes = {layer: [] for layer in LAYERS}
        names = {layer: [] for layer in LAYERS}
        result = {"seconds": self.args.idle_seconds, "panes": {}, "load_gate": gate}
        try:
            for size in sizes:
                for layer in LAYERS:
                    while len(panes[layer]) < size:
                        name = self.session(f"idle-{layer}-{len(names[layer])}")
                        names[layer].append(name)
                        panes[layer].append(self.open_pane(layer, name, command, marker)[0])
                time.sleep(self.args.idle_settle)
                result["panes"][str(size)] = self.idle_sample(self.idle_groups(panes, names))
                print(f"  {size} panes: {result['panes'][str(size)]}", flush=True)
        finally:
            for pane in panes["v1"] + panes["v2"]:
                pane.close()
        return result

    def end_local_sessions(self):
        """End every local session that this run made so far."""
        if not self.local_sessions:
            return
        try:
            subprocess.run(
                [self.args.v1_zmx, "kill", *self.local_sessions, "--force"],
                env=self.env, capture_output=True, timeout=30, check=False,
            )
        except subprocess.TimeoutExpired:
            pass
        if self.local:
            try:
                for entry in self.local.call("session.list")["sessions"]:
                    self.local.call("session.kill", id=entry["id"])
            except (BenchError, AssertionError, OSError):
                pass
        # A v1 daemon that `zmx kill` did not end, and a v2 session that the
        # server did not, carry a session name of this run in their argv.
        listing = subprocess.run(
            ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=False
        ).stdout
        ours = set(self.local_sessions)
        for line in listing.splitlines():
            pid, _, command = line.strip().partition(" ")
            if (command.startswith((self.args.zmx + " ", self.args.v1_zmx + " "))
                    and ours & set(command.split())):
                try:
                    os.kill(int(pid), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        self.local_sessions = []

    def cleanup(self):
        # A session with no client keeps running and drops terminal replies,
        # so every session that this run made is ended, local and remote.
        self.end_local_sessions()
        if self.local:
            try:
                self.local.call("server.exit")
            except (BenchError, AssertionError, OSError):
                pass
            self.local.close()
        if self.remote:
            self.remote.close()
        if self.remote_sessions:
            # v1's sessions on the host.
            try:
                subprocess.run(
                    ["ssh", "-o", "BatchMode=yes", self.args.ssh_host,
                     self.remote_zmx(self.args.v1_zmx, "kill", *self.remote_sessions, "--force")],
                    capture_output=True, timeout=60, check=False,
                )
            except subprocess.TimeoutExpired:
                pass
        if self.master:
            # v2's sessions and server on the host. The runtime directory is
            # this run's, so all of them are ours.
            try:
                stream = self.relay()
                try:
                    for entry in stream.call("session.list")["sessions"]:
                        stream.call("session.kill", id=entry["id"])
                    stream.call("server.exit")
                finally:
                    stream.close()
            except (BenchError, AssertionError, OSError):
                # No relay: end the server and sessions by the run's nonce,
                # which the argv of each holds.
                subprocess.run(
                    ["ssh", "-o", "BatchMode=yes", self.args.ssh_host,
                     f"pkill -TERM -f {shlex.quote(self.nonce)}"],
                    capture_output=True, timeout=60, check=False,
                )
            self.stop_master()
        shutil.rmtree(self.zmx_dir, ignore_errors=True)


def ssh_version():
    result = subprocess.run(["ssh", "-V"], capture_output=True, text=True, check=False)
    return (result.stderr or result.stdout).strip() or None


def zmx_version(binary):
    """The version on the first line of `<binary> version`."""
    result = subprocess.run([binary, "version"], capture_output=True, text=True, check=False)
    return result.stdout.split("\n", 1)[0].split()[-1] if result.stdout.strip() else None


def cmd_run(args):
    args.zmx = os.path.abspath(args.zmx)
    args.v1_zmx = os.path.abspath(args.v1_zmx)
    if args.max_load is None:
        args.max_load = max(1.0, os.cpu_count() / 2)
    bench = Bench(args)
    arms = {}
    try:
        arms["bare"] = bench.echo_arm("bare", ["/bin/cat"], takes_terminal=False)
        arms.update(bench.echo_pair())
        if args.ssh_host:
            command, marker = bench.ready_cat()
            arms["ssh"] = bench.echo_arm(
                "ssh", bench.ssh(" ".join(shlex.quote(word) for word in command)), marker=marker
            )
            arms["remote-login"] = summarize([bench.start_master()])
            # The first stream starts the host's server, as the first pane on
            # a host does.
            arms["remote-link"] = summarize([bench.start_remote()])
            arms.update(bench.remote_open_pair())
            arms.update(bench.echo_pair(remote=True))
            arms.update(bench.relay_flood())
        for layer, result in bench.reattach_pair().items():
            arms[f"reattach-{layer}"] = result
        # phys_footprint and the wakeup counts are read through libproc.
        if sys.platform == "darwin":
            # v2's server would also hold the sessions of the arms above.
            bench.end_local_sessions()
            arms["idle"] = bench.idle_pair()
    except (BenchError, AssertionError) as exc:
        sys.exit(f"error: {exc}")
    finally:
        bench.cleanup()

    payload = {
        "schema": 4,
        "commit": os.environ.get("GITHUB_SHA") or subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=False
        ).stdout.strip() or "unknown",
        "runner": runner_info(),
        "zmx": zmx_version(args.zmx),
        "zmx_v1": zmx_version(args.v1_zmx),
        "network": args.network,
        # OpenSSH 9.5 and later delays keystrokes (ObscureKeystrokeTiming), so
        # the ssh arms depend on the client's version.
        "ssh": ssh_version() if args.ssh_host else None,
        "arms": arms,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"wrote {args.out}")


ARM_LABELS = {
    "bare": "Echo, bare pty (floor)",
    "v1": "Echo, local pane, v1",
    "v2": "Echo, local pane, v2 (channel of the server)",
    "ssh": "Echo, ssh (floor)",
    "remote-v1": "Echo, remote pane, v1",
    "remote-v2": "Echo, remote pane, v2 (channel of the relay)",
    "remote-login": "Login of the host's connection (v2, one time)",
    "remote-link": "Stream to the host's server, server start included (v2, one time)",
    "remote-open-v1": "New remote pane, v1, to first echo",
    "remote-open-v2": "New remote pane, v2, to first echo",
    "relay-flood-key": "Relay flood: key of another channel",
    "relay-flood-ping": "Relay flood: channel 0 ping",
    "relay-flood-interrupt": "Relay flood: interrupt to prompt",
    "reattach-v1": "Reattach, v1, to first echo after replay",
    "reattach-v2": "Reattach, v2, to first echo after replay",
}


def ratio(v1, v2):
    return f"{v2 / v1:.2f}" if v1 else "—"


def pair_rows(arms, prefix=""):
    """The v1/v2 pairs of local panes, or with prefix `remote-`, of remote
    panes: (measurement, v1, v2, format)."""
    rows = []
    v1, v2 = arms.get(prefix + "v1"), arms.get(prefix + "v2")
    if v1 and v2:
        rows += [
            ("Echo p50 (ms)", v1["p50_ms"], v2["p50_ms"], "{:.3f}"),
            ("Echo p95 (ms)", v1["p95_ms"], v2["p95_ms"], "{:.3f}"),
        ]
    if prefix:
        v1, v2 = arms.get("remote-open-v1"), arms.get("remote-open-v2")
        if v1 and v2:
            rows.append(("New pane p50 (ms)", v1["p50_ms"], v2["p50_ms"], "{:.1f}"))
            # v2 logs in and starts its stream one time, for the first pane.
            login = sum(arms.get(arm, {}).get("p50_ms", 0) for arm in ("remote-login", "remote-link"))
            rows.append((f"Time to {v1['n']} new panes, login included (ms)", v1["sum_ms"],
                         login + v2["sum_ms"], "{:.1f}"))
        return rows
    if "reattach-v1" in arms and "reattach-v2" in arms:
        rows.append(("Reattach p50 (ms)", arms["reattach-v1"]["p50_ms"],
                     arms["reattach-v2"]["p50_ms"], "{:.1f}"))
    for size, layers in (arms.get("idle") or {}).get("panes", {}).items():
        def total(layer, key):
            return layers[layer][f"session_{key}"] + layers[layer][f"client_{key}"]
        rows += [
            (f"Memory, idle panes: {size} (MB)", total("v1", "mb"), total("v2", "mb"), "{:.1f}"),
            (f"Wakeups/s, idle panes: {size}", total("v1", "wakeups_per_s"),
             total("v2", "wakeups_per_s"), "{:.1f}"),
        ]
    return rows


# ── The gate ─────────────────────────────────────────────────────────────

LIMITS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "session_bench_limits.json")
LIMIT_RUNS = 20


# A difference below the floor passes whatever the limit says: a user cannot
# feel it (Ethan, 2026-11-10). Typing and reopen times are in ms, memory in
# MB. Wakeups have no floor.
FLOOR_MS = 1.0
FLOOR_MB = 2.0


def gate_values(arms):
    """The measurements that the gate compares, by name: (v1, v2, kind, floor).
    A `ratio` compares v2 / v1. A `difference` compares v2 - v1, for a value
    that v1 can have at 0 (idle wakeups, which are per pane)."""
    values = {}
    for prefix, where in (("", "Local"), ("remote-", "Remote")):
        v1, v2 = arms.get(prefix + "v1"), arms.get(prefix + "v2")
        if v1 and v2:
            for p in ("p50", "p95"):
                values[f"{where} echo {p}"] = (v1[f"{p}_ms"], v2[f"{p}_ms"], "ratio", FLOOR_MS)
    v1, v2 = arms.get("remote-open-v1"), arms.get("remote-open-v2")
    if v1 and v2:
        values["New remote pane p50"] = (v1["p50_ms"], v2["p50_ms"], "ratio", FLOOR_MS)
    v1, v2 = arms.get("reattach-v1"), arms.get("reattach-v2")
    if v1 and v2:
        values["Reattach p50"] = (v1["p50_ms"], v2["p50_ms"], "ratio", FLOOR_MS)
    for size, layers in (arms.get("idle") or {}).get("panes", {}).items():
        def total(layer, key):
            return layers[layer][f"session_{key}"] + layers[layer][f"client_{key}"]
        values[f"Memory, idle panes: {size}"] = (total("v1", "mb"), total("v2", "mb"), "ratio", FLOOR_MB)
        values[f"Wakeups/s per pane, idle panes: {size}"] = (
            total("v1", "wakeups_per_s") / int(size), total("v2", "wakeups_per_s") / int(size),
            "difference", 0,
        )
    return values


def gate_statistic(v1, v2, kind):
    if kind == "difference":
        return v2 - v1
    return v2 / v1 if v1 > 0 else float("inf")


def load_results(paths):
    results = []
    for path in paths:
        with open(path) as f:
            results.append(json.load(f))
    return results


def gate_base(kind, median):
    """The statistic that the gate expects: the median of the runs that made
    the limits, but never worse than no change (a ratio of 1, a difference of
    0). v2 has no client process, so some of its ratios are well under 1, and
    a limit of 1 would let v2 get slower without a failure."""
    return min(median, 1 if kind == "ratio" else 0)


def cmd_limits(args):
    """Each limit is the base (gate_base) plus the noise: the largest distance
    of one run's statistic from the base. The noise is measured from the base,
    so each run passes its own limit without the floor. The runs are of one
    commit, or of commits that do not change the session layer."""
    by_system = {}
    for result in load_results(args.results):
        by_system.setdefault(result["runner"]["system"], []).append(result)
    limits = {"runs": {}, "systems": {}}
    for system, results in sorted(by_system.items()):
        if len(results) < args.min_runs:
            sys.exit(f"error: {len(results)} runs of {system}; the limits need {args.min_runs}")
        name_sets = [set(gate_values(r["arms"])) for r in results]
        names = set.intersection(*name_sets)
        if any(n != names for n in name_sets):
            sys.exit(f"error: the runs of {system} do not all have the same measurements")
        entries = {}
        for name in sorted(names):
            kind = gate_values(results[0]["arms"])[name][2]
            stats = [gate_statistic(*gate_values(r["arms"])[name][:3]) for r in results]
            median = statistics.median(stats)
            base = gate_base(kind, median)
            noise = max(abs(s - base) for s in stats)
            entries[name] = {
                "kind": kind,
                "median": round(median, 3),
                "noise": round(noise, 3),
                # Up, so that the run that set the noise passes its own limit.
                "limit": math.ceil((base + noise) * 1000) / 1000,
            }
        limits["systems"][system] = entries
        limits["runs"][system] = {
            "count": len(results),
            "commits": sorted({r["commit"] for r in results}),
            "images": sorted({str(r["runner"].get("image_version")) for r in results}),
        }
    with open(args.out, "w") as f:
        json.dump(limits, f, indent=2)
        f.write("\n")
    print(f"wrote {args.out}")


def cmd_check(args):
    """Fail when v2 is worse than its base (gate_base) beyond the noise of
    the limits, and worse than that base by the floor or more. With more
    than one run of a system (the workflow measures on two runners), a
    measurement fails only when it fails in each run of its system. A
    system with no limits, or a measurement that a run does not have, fails
    at once."""
    with open(args.limits) as f:
        limits = json.load(f)["systems"]
    runs = {}
    misses = {}
    missing = []
    lines = ["## Session layer gate", ""]
    for path, result in zip(args.results, load_results(args.results)):
        system = result["runner"]["system"]
        runs[system] = runs.get(system, 0) + 1
        lines += [f"### {system} ({os.path.basename(path)})", ""]
        entries = limits.get(system)
        if not entries:
            lines += [f"No limits for {system}. Fail.", ""]
            missing.append(f"No limits for {system}")
            continue
        values = gate_values(result["arms"])
        lines += [
            "| Measurement | v1 | v2 | v2 / v1 or v2 − v1 | Limit | Result |",
            "|---|---:|---:|---:|---:|---|",
        ]
        for name, entry in entries.items():
            if name not in values:
                lines.append(f"| {name} | — | — | — | {entry['limit']:.3f} | Fail: not measured |")
                missing.append(f"{system}: {name} not measured")
                continue
            v1, v2, kind, floor = values[name]
            stat = gate_statistic(v1, v2, kind)
            base = gate_base(kind, entry["median"])
            expected = v1 * base if kind == "ratio" else v1 + base
            if stat <= entry["limit"]:
                verdict = "Pass"
            elif v2 - expected < floor:
                verdict = f"Pass: under {floor:g} {'MB' if 'emory' in name else 'ms'}"
            else:
                verdict = "Fail"
                misses.setdefault((system, name), []).append(
                    f"{system}: {name}: v1 {v1:.3f}, v2 {v2:.3f}, limit {entry['limit']:.3f}"
                )
            lines.append(
                f"| {name} | {v1:.3f} | {v2:.3f} | {stat:.3f} | {entry['limit']:.3f} | {verdict} |"
            )
        lines.append("")
    failures = missing + [m for (system, _), ms in misses.items() if len(ms) == runs[system] for m in ms]
    for system, count in runs.items():
        if count > 1:
            lines += [f"{count} runs of {system}: a measurement fails only when it fails in each run.", ""]
    print("\n".join(lines))
    if failures:
        print("Gate failed:", *failures, sep="\n", file=sys.stderr)
        sys.exit(1)


def cmd_report(args):
    lines = ["## Session layer", ""]
    for path in args.results:
        with open(path) as f:
            result = json.load(f)
        runner = result.get("runner", {})
        image = " ".join(
            str(v) for v in (runner.get("image_os"), runner.get("image_version")) if v
        ) or f"{runner.get('system')} {runner.get('release')}"
        title = f"### {runner.get('system')} ({image}, {runner.get('cpus')} CPUs)"
        lines += [title, ""]
        arms = result["arms"]

        for prefix, title in (("", "Local panes"), ("remote-", "Remote panes, over ssh")):
            pairs = pair_rows(arms, prefix)
            if not pairs:
                continue
            lines += [
                f"{title}, v1 and v2 in one run, alternated:",
                "",
                "| Measurement | v1 | v2 | v2 / v1 |",
                "|---|---:|---:|---:|",
            ]
            for label, v1, v2, number in pairs:
                lines.append(
                    f"| {label} | {number.format(v1)} | {number.format(v2)} | {ratio(v1, v2)} |"
                )
            lines.append("")

        if result.get("network"):
            lines += [f"Network: {result['network']}.", ""]
        if result.get("ssh"):
            lines += [f"ssh client: {result['ssh']}.", ""]
        lines += [
            "| Measurement | n | p50 ms | p95 ms | p99 ms | max ms | Load |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
        for arm, label in ARM_LABELS.items():
            data = arms.get(arm)
            if not data:
                continue
            gate = data.get("load_gate", {})
            load = f"{gate.get('load', '—')}" + ("" if gate.get("passed", True) else " ⚠️")
            # A tail percentile of a few samples is only the max.
            tail = (
                f"{data['p95_ms']:.3f} | {data['p99_ms']:.3f}" if data["n"] >= 20 else "— | —"
            )
            lines.append(
                f"| {label} | {data['n']} | {data['p50_ms']:.3f} | {tail} "
                f"| {data['max_ms']:.3f} | {load} |"
            )
        for layer in LAYERS:
            reattach = arms.get(f"reattach-{layer}")
            if reattach:
                lines += [
                    "",
                    f"Reattach, {layer}, replays {reattach['lines']} lines of "
                    f"{reattach['columns']} columns: {reattach['replay_bytes'] / 1024:.0f} KiB.",
                ]

        flood = arms.get("relay-flood-interrupt")
        if flood:
            lines += [
                "",
                f"Relay flood: {len(flood['skips'])} floods; skips ahead in each: "
                f"{', '.join(str(n) for n in flood['skips'])}; MB/s that the client got in each: "
                f"{', '.join(str(n) for n in flood['received_mb_per_s'])}. A flood with no skip "
                "was not faster than the link.",
            ]

        idle = arms.get("idle")
        if idle:
            gate = idle.get("load_gate", {})
            load = f"{gate.get('load', '—')}" + ("" if gate.get("passed", True) else " ⚠️")
            lines += [
                "",
                f"Idle panes, wakeups over {idle['seconds']} s, load {load}. The session side "
                "is v1's daemons, or v2's server and sessions:",
                "",
                "| Panes | Layer | Session side MB | Clients MB | Session side wakeups/s "
                "| Clients wakeups/s |",
                "|---:|---|---:|---:|---:|---:|",
            ]
            for size, layers in idle["panes"].items():
                for layer in LAYERS:
                    data = layers[layer]
                    lines.append(
                        f"| {size} | {layer} | {data['session_mb']:.1f} | {data['client_mb']:.1f} "
                        f"| {data['session_wakeups_per_s']:.1f} "
                        f"| {data['client_wakeups_per_s']:.1f} |"
                    )
        lines.append("")
    lines.append(
        "_Load is the 1-minute load average when the measurement started. ⚠️ means "
        "the load did not drop below the gate in time._"
    )
    print("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="measure every arm and write a results JSON")
    run.add_argument("--zmx", required=True, help="path to the zmx binary of v2")
    run.add_argument("--v1-zmx", required=True,
                     help="path to the frozen zmx binary of v1 (0.8.1, as v1.33.2 ran it)")
    run.add_argument("--out", required=True, help="path for the results JSON")
    run.add_argument("--keys", type=int, default=500, help="keys per echo arm")
    run.add_argument("--rounds", type=int, default=10,
                     help="rounds in which the echo keys alternate between v1 and v2")
    run.add_argument("--ssh-host",
                     help="also measure the ssh arms against this host, which has both "
                          "zmx binaries at the same paths as --zmx and --v1-zmx")
    run.add_argument("--network", help="a note on the network to the ssh host, for the report")
    run.add_argument("--panes", type=int, default=5, help="new remote panes to time, in each layer")
    run.add_argument("--floods", type=int, default=3, help="floods of the relay flood arm")
    run.add_argument("--flood-keys", type=int, default=10,
                     help="keys and pings to time during each flood")
    run.add_argument("--reattach-lines", type=int, default=10000,
                     help="lines of 200 columns in the reattached session")
    run.add_argument("--attaches", type=int, default=5, help="reattaches to time, in each layer")
    run.add_argument("--idle-panes", type=lambda v: [int(n) for n in v.split(",")],
                     default=[1, 9], help="pane counts at which to measure idle cost (macOS)")
    run.add_argument("--idle-seconds", type=int, default=60,
                     help="seconds over which to count the wakeups of idle panes")
    run.add_argument("--idle-settle", type=int, default=5,
                     help="seconds to wait after the panes open, before the idle reads")
    run.add_argument("--max-load", type=float,
                     help="1-minute load average to wait for before each arm "
                          "(default: half the CPU count, at least 1)")
    run.add_argument("--load-timeout", type=int, default=120,
                     help="seconds to wait for the load gate")
    run.set_defaults(func=cmd_run)

    report = sub.add_parser("report", help="render results as markdown")
    report.add_argument("results", nargs="+", help="results JSONs from `run`")
    report.set_defaults(func=cmd_report)

    limits = sub.add_parser("limits", help="write the gate's limits from the spread of many runs")
    limits.add_argument("results", nargs="+", help="results JSONs from `run`")
    limits.add_argument("--out", default=LIMITS_PATH, help="path for the limits JSON")
    limits.add_argument("--min-runs", type=int, default=LIMIT_RUNS,
                        help="runs that each system needs")
    limits.set_defaults(func=cmd_limits)

    check = sub.add_parser("check", help="exit 1 when v2 is worse than v1 beyond the limits")
    check.add_argument("results", nargs="+", help="results JSONs from `run`")
    check.add_argument("--limits", default=LIMITS_PATH, help="the limits JSON")
    check.set_defaults(func=cmd_check)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
