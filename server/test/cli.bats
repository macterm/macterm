#!/usr/bin/env bats
# The command line of zmx (src/main.zig) and the macterm CLI in it
# (src/cli/). The Zig tests check the CLI's text against src/cli/golden/.

load test_helper

@test "unknown command is a usage error" {
  run "$ZMX" foo
  [ "$status" -eq 64 ]
  [[ "$output" == *"Unexpected argument 'foo'"* ]]
}

@test "zmx v1 commands are unknown" {
  for cmd in attach a list ls get set clear history send kill __daemon run wait tail print detach; do
    run "$ZMX" "$cmd" dummy_session
    [ "$status" -eq 64 ]
    [[ "$output" == *"Unexpected argument '$cmd'"* ]]
  done
}

@test "connect with no session name exits non-zero" {
  run "$ZMX" connect
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "help and no command exit zero with the usage" {
  for args in help -h --help ""; do
    run "$ZMX" $args
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE: macterm <subcommand>"* ]]
  done
}

@test "help of a command" {
  for args in "help status" "status --help" "status -h"; do
    run "$ZMX" $args
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE: macterm status [--socket <socket>] [--json]"* ]]
  done
}

@test "status with no server exits 2 and does not start one" {
  run "$ZMX" status
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not reach the Macterm server"* ]]
  [[ "$output" == *"$MACTERM_RUNTIME_DIR/.server: no socket file"* ]]
  [ ! -S "$MACTERM_RUNTIME_DIR/.server" ]
}

@test "status names the server's build and pid" {
  "$ZMX" server
  pid=$(python3 "$BATS_TEST_DIRNAME/v2client.py" server-pid)
  build=$("$ZMX" version | head -1 | cut -f3)
  run "$ZMX" status
  [ "$status" -eq 0 ]
  [ "$output" = "Macterm $build (pid $pid)" ]
  run "$ZMX" status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["pid"])')" = "$pid" ]
  run "$ZMX" status --socket "$MACTERM_RUNTIME_DIR/.server"
  [ "$status" -eq 0 ]
}

@test "version names the build" {
  run "$ZMX" version
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == zmx* ]]
}
