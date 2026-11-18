#!/usr/bin/env bats
# macOS attributes privacy-gated operations (Local Network, TCC) to a process's
# *responsible process*, a value fixed at spawn and inherited from the parent.
# The server spawns the session disclaimed (spawnSession in registry.zig) so that
# it, and not the server or the app, is the responsible process for everything
# in the session -- and stays so after they exit. These
# tests pin that contract. The semantics are Darwin-only, so they skip elsewhere.

load test_helper

# Compiles a probe around the libSystem call that reports a pid's responsible
# pid. Prints "<pid> <responsible>" per argument.
build_probe() {
  local src="$BATS_TEST_TMPDIR/rpid.c"
  cat > "$src" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    pid_t p = atoi(argv[i]);
    printf("%d %d\n", p, responsibility_get_pid_responsible_for_pid(p));
  }
  return 0;
}
CEOF
  cc -o "$BATS_TEST_TMPDIR/rpid" "$src"
}

responsible_for() {
  "$BATS_TEST_TMPDIR/rpid" "$1" | awk '{print $2}'
}

@test "macos: the session is its own responsible process and the session's programs inherit it" {
  [[ "$(uname)" == "Darwin" ]] || skip "responsibility is a macOS concept"
  command -v cc >/dev/null || skip "needs a C compiler for the responsibility probe"
  build_probe

  # A session with no command runs $SHELL, so the session's argv ends at the
  # session name.
  "$ZMX" __create-session resp-test
  local session shell i=0
  session=$(pgrep -f "__session resp-test$")
  [[ -n "$session" ]]
  until shell=$(pgrep -P "$session"); do
    (( i++ < 50 )) || { echo "no shell under the session"; return 1; }
    sleep 0.1
  done

  # The session disclaimed the process that created it...
  [ "$(responsible_for "$session")" -eq "$session" ]
  # ...so the session's shell is attributed to the session, not to this test's own root.
  [ "$(responsible_for "$shell")" -eq "$session" ]
  [ "$(responsible_for $$)" -ne "$session" ]
}
