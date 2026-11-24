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

# Polls `macterm pane dump` until a line of its text is $2.
wait_dump() {
  local i out
  for i in $(seq 100); do
    out=$("$ZMX" pane dump --session "$1" 2>/dev/null) || true
    printf '%s\n' "$out" | grep -qxF -- "$2" && return 0
    sleep 0.1
  done
  echo "dump of $1: $out" >&2
  return 1
}

@test "pane run, key, dump and inspect reach a session with no GUI" {
  "$ZMX" __create-session cli1 -- /bin/sh
  run "$ZMX" pane run --session cli1 -- echo ran-it
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  wait_dump cli1 ran-it

  # Text left at the prompt runs at the Return of pane key.
  "$ZMX" pane run --no-submit --session cli1 -- echo keyed
  "$ZMX" pane key return --session cli1
  wait_dump cli1 keyed

  run "$ZMX" pane inspect --session cli1
  [ "$status" -eq 0 ]
  [[ "$output" == *"grid                80×24"* ]]
  [[ "$output" == *"cell px             -"* ]]
  [[ "$output" == *"needs confirm quit  false"* ]]

  # A program in front: inspect names it, and ctrl+c ends it.
  "$ZMX" pane run --session cli1 -- sleep 30
  for i in $(seq 100); do
    out=$("$ZMX" pane inspect --session cli1)
    [[ "$out" == *"(sleep 30)"* ]] && break
    sleep 0.1
  done
  [[ "$out" == *"needs confirm quit  true"* ]]
  "$ZMX" pane key ctrl+c --session cli1
  for i in $(seq 100); do
    out=$("$ZMX" pane inspect --session cli1)
    [[ "$out" == *"needs confirm quit  false"* ]] && break
    sleep 0.1
  done
  [[ "$out" == *"needs confirm quit  false"* ]]

  run "$ZMX" pane dump --scrollback --json --session cli1
  [ "$status" -eq 0 ]
  [[ "$output" == *'"session" : "cli1"'* ]]
}

@test "session list, info and kill" {
  "$ZMX" __create-session cli2 -- /bin/sh
  run "$ZMX" session list
  [ "$status" -eq 0 ]
  [[ "$output" == "cli2  clients:0  pid:"*"  -" ]]
  run "$ZMX" session info cli2 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"name" : "cli2"'* ]]
  run "$ZMX" session kill cli2
  [ "$status" -eq 0 ]
  run "$ZMX" session info cli2
  [ "$status" -eq 1 ]
  [[ "$output" == *'no zmx session named "cli2"'* ]]
}

@test "pane verbs name the session that the server does not have" {
  "$ZMX" server
  run "$ZMX" pane dump --session nope
  [ "$status" -eq 1 ]
  [[ "$output" == *'no zmx session named "nope"'* ]]
  run "$ZMX" pane run --session nope -- ls
  [ "$status" -eq 1 ]
}

@test "api list and describe work with no server" {
  run "$ZMX" api list
  [ "$status" -eq 0 ]
  [[ "$output" == *"session.send"*"since 3"*"Types text into a session"* ]]
  # A message that only a session process sends is not a method.
  [[ "$output" != *"history_read"* ]]
  run "$ZMX" api describe session.send
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(d["args"]["required"]))')" = "id,text" ]
  [ ! -S "$MACTERM_RUNTIME_DIR/.server" ]
  run "$ZMX" api describe nope
  [ "$status" -eq 1 ]
  [[ "$output" == *'no method named "nope"'* ]]
}

@test "api call sends a request to the server and prints the result" {
  run "$ZMX" api call ping
  [ "$status" -eq 2 ]
  "$ZMX" __create-session api1 -- /bin/sh
  run "$ZMX" api call session.info --args '{"id": "api1"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; s=json.load(sys.stdin)["session"]; print(s["id"], s["state"])')" = "api1 running" ]

  printf '{"id": "api1", "text": "echo via-api"}' | "$ZMX" api call session.send --args -
  wait_dump api1 via-api

  # Bad args fail before the request; the server's error names its code.
  run "$ZMX" api call session.send --args '{"id": "api1"}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"args.text: expected a value: the key is required"* ]]
  run "$ZMX" api call session.kill --args '{"id": "nope"}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"(not_found)"* ]]

  run "$ZMX" api call session.kill --args '{"id": "api1"}'
  [ "$status" -eq 0 ]
  run "$ZMX" session info api1
  [ "$status" -eq 1 ]
}

# Prints the value at the Python expression $1 of the JSON on stdin (`r`).
json_py() {
  python3 -c "import json, sys; r = json.load(sys.stdin); print($1)"
}

@test "api call session.history with tail_lines gives the last lines and counts the cut" {
  "$ZMX" __create-session tail1 -- /bin/sh
  "$ZMX" api call session.send --args '{"id": "tail1", "text": "for i in 1 2 3 4 5 6; do echo tail-$i; done"}'
  wait_dump tail1 tail-6
  run "$ZMX" api call session.history --args '{"id": "tail1", "scrollback": true, "tail_lines": 2}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | json_py 'len(r["text"].rstrip("\n").split("\n")) <= 2 and r["truncated"] and r["lines_cut"] > 0')" = "True" ]
  # All lines: nothing cut.
  run "$ZMX" api call session.history --args '{"id": "tail1", "scrollback": true, "tail_lines": 100000}'
  [ "$(printf '%s' "$output" | json_py '"tail-1" in r["text"] and not r["truncated"] and r["lines_cut"] == 0')" = "True" ]
  run "$ZMX" api call session.history --args '{"id": "tail1", "tail_lines": 0}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"(invalid_args)"* ]]
}

@test "api call session.wait ends at the marker, at the timeout, when the shell is quiet, and at the exit" {
  "$ZMX" __create-session wait1 -- /bin/sh
  # The typed command line holds the marker, but does not start with it.
  "$ZMX" api call session.send --args '{"id": "wait1", "text": "sleep 1; echo w-$((40+2))-done"}'
  start=$(date +%s)
  run "$ZMX" api call session.wait --args '{"id": "wait1", "text": "w-42", "timeout_ms": 10000}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | json_py 'r["end"], r["line"]')" = "matched w-42-done" ]
  [ $(($(date +%s) - start)) -ge 1 ]
  # A marker that is already in the text ends the wait at once.
  run "$ZMX" api call session.wait --args '{"id": "wait1", "text": "w-42", "timeout_ms": 10000}'
  [ "$(printf '%s' "$output" | json_py 'r["end"]')" = "matched" ]

  run "$ZMX" api call session.wait --args '{"id": "wait1", "text": "never-here", "timeout_ms": 300}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | json_py 'r["end"], r.get("line")')" = "timeout None" ]

  # With no marker: no run and 500 ms with no output. A command that prints
  # nothing is a run.
  "$ZMX" api call session.send --args '{"id": "wait1", "text": "sleep 2"}'
  start=$(date +%s)
  run "$ZMX" api call session.wait --args '{"id": "wait1", "timeout_ms": 10000}'
  [ "$(printf '%s' "$output" | json_py 'r["end"]')" = "done" ]
  [ $(($(date +%s) - start)) -ge 2 ]

  "$ZMX" api call session.send --args '{"id": "wait1", "text": "exit"}'
  run "$ZMX" api call session.wait --args '{"id": "wait1", "text": "never-here", "timeout_ms": 5000}'
  [ "$(printf '%s' "$output" | json_py 'r["end"]')" = "exited" ]
}

@test "api call session.wait refuses a bad marker or timeout before it waits" {
  "$ZMX" __create-session wait2 -- /bin/sh
  run "$ZMX" api call session.wait --args '{"id": "wait2", "timeout_ms": 600001}'
  [ "$status" -eq 1 ]
  run "$ZMX" api call session.wait --args '{"id": "wait2", "text": ""}'
  [ "$status" -eq 1 ]
  run "$ZMX" api call session.wait --args '{"id": "nope"}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"(not_found)"* ]]
}
