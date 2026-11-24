#!/usr/bin/env bats
# The session's foreground under login(1) (`Session.isShellGroup`). Only
# macOS starts a shell under login(1), so CI runs this file on macOS only.

load test_helper

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
}

# macOS starts a local shell under login(1) (ghostty's launch), which puts
# the shell in a process group of its own: that group is the shell's.
@test "events: a shell under login(1) is idle at its prompt" {
  "$ZMX" __create-session s1 -- /usr/bin/login -flpq "$(id -un)" /bin/sh
  python3 - <<'PY'
from v2client import Client
c = Client("s1")
c.attach(foreground=True)
def last():
    return c.messages("foreground")[-1]["a"]
c.wait(lambda: c.messages("foreground") and b"sh" in last()["comm"], what="the shell in front")
assert last()["idle"] is True, last()
def busy():
    n = len(c.messages("inspect"))
    c.pane("inspect_read")
    c.wait_msg("inspect", count=n + 1)
    return c.messages("inspect")[-1]["a"]["terminal"]["busy"]
assert busy() is False
c.type("sleep 30\r")
c.wait(lambda: b"sleep" in last()["comm"], what="the sleep foreground")
assert last()["idle"] is False, last()
assert busy() is True
c.type(b"\x03")
c.wait(lambda: last()["idle"] is True, what="the idle foreground")
assert busy() is False
PY
}
