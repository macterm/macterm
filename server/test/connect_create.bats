#!/usr/bin/env bats
# `zmx connect <name> -- <command>` (src/attach.zig): with no session of the
# name, the client asks the server to make one, and starts the server when
# nothing answers. The session gets the client's folder, environment and
# terminal size. This is how a Macterm pane starts its v2 session.

load test_helper

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
}

@test "connect --: makes the session through a server it starts, with its folder, environment and size" {
  mkdir -p "$RT/work"
  (cd "$RT/work" && CREATE_MARK=from-the-pane python3 - <<'PY'
import os
from ptyrun import Pty
from v2client import ServerClient
p = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh"], cols=90, rows=20)
p.type("pwd; stty size; printf 'env-%s-%s\\n' \"$CREATE_MARK\" \"$MACTERM_SESSION\"\r")
p.wait_output("env-from-the-pane-s1")
assert (os.path.basename(os.environ["RT"]) + "/work\r\n").encode() in p.output, p.output
assert b"20 90" in p.output, p.output
c = ServerClient()
assert list(c.sessions()) == ["s1"], c.sessions()
p.type(b"\x1c")
assert p.wait_exit() == 0
PY
  )
}

@test "connect --: the runtime directory in the session is the server's" {
  python3 - <<'PY'
import os
from ptyrun import Pty
p = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh"], cols=80, rows=24)
p.type("printf 'rt-%s\\n' \"$MACTERM_RUNTIME_DIR\"\r")
p.wait_output("rt-" + os.environ["MACTERM_RUNTIME_DIR"])
p.type(b"\x1c")
assert p.wait_exit() == 0
PY
}

@test "connect --: a session that exists is attached, and the command is not run again" {
  python3 - <<'PY'
import os
from ptyrun import Pty
argv = [os.environ["ZMX"], "connect", "s1", "--", "/bin/sh"]
p = Pty(argv)
p.type("KEEP=kept-42; printf 'first-%s\\n' 1\r")
p.wait_output("first-1")
p.type(b"\x1c")
assert p.wait_exit() == 0
q = Pty(argv)
q.type("printf 'again-%s\\n' \"$KEEP\"\r")
q.wait_output("again-kept-42")
q.type(b"\x1c")
assert q.wait_exit() == 0
PY
}

@test "connect --: the shell's exit code is the client's" {
  python3 - <<'PY'
import os
from ptyrun import Pty
p = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh", "-c", "exit 7"])
assert p.wait_exit() == 7, p.output
PY
}

@test "connect with no --: a missing session is not made" {
  run "$ZMX" connect s1
  [ "$status" -ne 0 ]
  [[ "$output" == *'no session "s1"'* ]]
  [ ! -S "$MACTERM_RUNTIME_DIR/.server" ]
}

@test "session.create: an environment entry with no = is refused" {
  python3 - <<'PY'
import subprocess, os
subprocess.run([os.environ["ZMX"], "server"], check=True)
from v2client import ServerClient
c = ServerClient()
r = c.request("session.create", id="s1", env=[b"NOEQUALS"])
assert r.get("err", {}).get("code") == "invalid_args", r
PY
}

@test "connect --: a session whose shell exited is ended, and a new one starts" {
  python3 - <<'PY'
import os
from ptyrun import Pty
from v2client import Client, ServerClient, alive, wait_dead
first = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh", "-c", "exit 5"])
assert first.wait_exit() == 5, first.output
# The client read the status from the session, not through the server: the
# session keeps it. Its own socket gives its pid, and the server learns
# nothing from that.
old = Client("s1").wait_msg("state")["pid"]
assert alive(old)
# The connect asks with replace_exited: the server ends the old session.
again = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh"])
again.type("printf 'new-%s\\n' shell\r")
again.wait_output("new-shell")
wait_dead(old)
c = ServerClient()
assert c.sessions()["s1"]["state"] == "running", c.sessions()
again.type(b"\x1c")
assert again.wait_exit() == 0
PY
}

@test "session.list: clients counts the clients that show the session" {
  python3 - <<'PY'
import os, time
from ptyrun import Pty
from v2client import ServerClient
p = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh"])
p.type("printf 'up-%s\\n' 1\r")
p.wait_output("up-1")
c = ServerClient()
def wait_clients(n):
    deadline = time.time() + 5
    while c.sessions()["s1"].get("clients") != n and time.time() < deadline:
        time.sleep(0.05)
    assert c.sessions()["s1"].get("clients") == n, c.sessions()
wait_clients(1)
q = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh"])
q.wait_output("up-1")
wait_clients(2)
q.type(b"\x1c")
assert q.wait_exit() == 0
wait_clients(1)
p.type(b"\x1c")
assert p.wait_exit() == 0
PY
}
