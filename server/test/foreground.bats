#!/usr/bin/env bats
# Foreground reports (src/foreground.zig): the session sends the foreground
# process of its pty to a client that asks.

load test_helper

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
}

# On macOS, KERN_PROCARGS2 holds the environment after the arguments, and a
# buffer that is too short gets the end of that data. The foreground here is
# a program that this test compiles, because the kernel shows no environment
# for a platform binary such as /bin/sleep. Linux reads /proc/<pid>/cmdline,
# which has no environment, so there the test passes with or without the fix.
@test "foreground: a process with an environment over 8 KB reports its args" {
  command -v cc >/dev/null || skip "needs a C compiler for the foreground program"
  printf '#include <unistd.h>\nint main(void) { pause(); return 0; }\n' > "$RT/waiter.c"
  cc -o "$RT/waiter" "$RT/waiter.c"
  BIG=$(printf 'x%.0s' $(seq 16384)) "$ZMX" __create-session outer -- /bin/sh
  python3 - <<'PY'
import os
from v2client import Client
c = Client("outer")
c.attach(foreground=True)
c.wait_msg("foreground")
c.type(os.environ["RT"] + "/waiter one two\r")
want = (os.environ["RT"] + "/waiter one two").encode()
c.wait(lambda: c.messages("foreground")[-1]["a"]["args"] == want, what="the waiter's args")
PY
}
