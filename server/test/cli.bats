#!/usr/bin/env bats
# The command line of zmx (src/main.zig).

load test_helper

@test "unknown command exits non-zero" {
  run "$ZMX" foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "v1 commands are unknown" {
  for cmd in attach a list ls get set clear history send kill __daemon run wait tail print detach; do
    run "$ZMX" "$cmd" dummy_session
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown command"* ]]
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
    [[ "$output" == *"Usage:"* ]]
  done
}

@test "version names the build" {
  run "$ZMX" version
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == zmx* ]]
}
