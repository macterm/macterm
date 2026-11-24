#!/usr/bin/env bats
# `macterm mcp` (src/cli/mcp.zig): JSON-RPC on stdin and stdout, one message
# on each line, against a test server.

load test_helper

# The teardown of test_helper, and the end of a background mcp process that
# a failed test left.
eval "helper_$(declare -f teardown)"
teardown() {
  [ -n "${mcp_pid:-}" ] && kill "$mcp_pid" 2>/dev/null
  helper_teardown
}

# Sends each argument as one message to a new `macterm mcp` and prints the
# replies, one on each line.
mcp() {
  printf '%s\n' "$@" | "$ZMX" mcp
}

# Prints the value at the Python expression $1 of the JSON on stdin (`r` is
# the reply).
jq_py() {
  python3 -c "import json, sys; r = json.loads(sys.stdin.readline()); print($1)"
}

# Waits until $RT/out has $1 lines.
wait_lines() {
  local i
  for i in $(seq 100); do
    [ "$(wc -l <"$RT/out")" -ge "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

call() {
  printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2"
}

@test "initialize gives the instructions, and a notification gets no reply" {
  run mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bats","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"ping"}'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(printf '%s\n' "${lines[0]}" | jq_py 'r["result"]["protocolVersion"]')" = "2025-06-18" ]
  [ "$(printf '%s\n' "${lines[0]}" | jq_py 'r["result"]["instructions"] == open("'"$REPO_DIR"'/src/cli/mcp_instructions.txt").read()')" = "True" ]
  [ "$(printf '%s\n' "${lines[1]}" | jq_py 'r["id"]')" = "2" ]
}

@test "tools/list is the golden list" {
  run mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"] == json.load(open("'"$REPO_DIR"'/src/cli/golden/mcp-tools.json"))')" = "True" ]
}

@test "a tool call while Macterm is not running is a tool error, and starts no server" {
  run mcp "$(call session_list '{}')"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["isError"]')" = "True" ]
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["content"][0]["text"]')" = "Macterm is not running. Start Macterm and try again." ]
  [ ! -S "$MACTERM_RUNTIME_DIR/.server" ]
}

@test "one mcp process finds the server that starts after it" {
  # The first call finds no server; the second call connects again.
  mkfifo "$RT/in"
  "$ZMX" mcp <"$RT/in" >"$RT/out" &
  mcp_pid=$!
  exec 7>"$RT/in"
  printf '%s\n' "$(call session_list '{}')" >&7
  wait_lines 1
  first=$(sed -n 1p "$RT/out")
  [ "$(printf '%s\n' "$first" | jq_py 'r["result"]["isError"]')" = "True" ]
  "$ZMX" __create-session mcp0 -- /bin/sh
  printf '%s\n' "$(call session_list '{}')" >&7
  wait_lines 2
  exec 7>&-
  wait "$mcp_pid"
  second=$(sed -n 2p "$RT/out")
  [ "$(printf '%s\n' "$second" | jq_py 'r["result"]["isError"]')" = "False" ]
  [ "$(printf '%s\n' "$second" | jq_py '[s["id"] for s in r["result"]["structuredContent"]["sessions"]]')" = "['mcp0']" ]
}

@test "tools/call types into a session and reads its text" {
  "$ZMX" __create-session mcp1 -- /bin/sh
  run mcp "$(call session_send '{"id":"mcp1","text":"echo via-$((6*7))"}')"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["isError"]')" = "False" ]
  for i in $(seq 100); do
    out=$(mcp "$(call session_history '{"id":"mcp1"}')" | jq_py 'r["result"]["structuredContent"]["text"]')
    printf '%s\n' "$out" | grep -qxF via-42 && break
    sleep 0.1
  done
  printf '%s\n' "$out" | grep -qxF via-42
  # The text content is the same object as JSON.
  run mcp "$(call session_inspect '{"id":"mcp1"}')"
  [ "$(printf '%s\n' "$output" | jq_py 'json.loads(r["result"]["content"][0]["text"]) == r["result"]["structuredContent"]')" = "True" ]
}

@test "the server's error and bad arguments are tool errors; an unknown tool is a protocol error" {
  "$ZMX" __create-session mcp2 -- /bin/sh
  run mcp "$(call session_info '{"id":"nope"}')"
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["isError"]')" = "True" ]
  [[ "$(printf '%s\n' "$output" | jq_py 'r["result"]["content"][0]["text"]')" == *"(not_found)" ]] || false
  run mcp "$(call session_send '{"id":"mcp2"}')"
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["content"][0]["text"]')" = "arguments.text: expected a value: the key is required" ]
  run mcp "$(call server_exit '{}')"
  [ "$(printf '%s\n' "$output" | jq_py 'r["error"]["code"]')" = "-32602" ]
  run "$ZMX" session info mcp2
  [ "$status" -eq 0 ]
}

@test "an mcp client may not type into a pane that reads a password; the CLI may" {
  "$ZMX" __create-session mcp3 -- /bin/sh
  run mcp "$(call session_send '{"id":"mcp3","text":"stty -echo; echo rea''dy; read x; stty echo; echo x=$x"}')"
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["isError"]')" = "False" ]
  # `ready` shows after `stty -echo`: the pty reads a password.
  for i in $(seq 100); do
    out=$(mcp "$(call session_history '{"id":"mcp3"}')" | jq_py 'r["result"]["structuredContent"]["text"]')
    printf '%s\n' "$out" | grep -qxF ready && break
    sleep 0.1
  done
  printf '%s\n' "$out" | grep -qxF ready
  refusal="The pane reads a password. Ask the user to type it. (forbidden)"
  run mcp "$(call session_send '{"id":"mcp3","text":"hunter2"}')"
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["content"][0]["text"]')" = "$refusal" ]
  run mcp "$(call session_key '{"id":"mcp3","chord":"enter"}')"
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["content"][0]["text"]')" = "$refusal" ]
  # The CLI keeps v1's behavior: it types into the password read.
  run "$ZMX" api call session.send --args '{"id":"mcp3","text":"typed-by-the-user"}'
  [ "$status" -eq 0 ]
  for i in $(seq 100); do
    out=$(mcp "$(call session_history '{"id":"mcp3"}')" | jq_py 'r["result"]["structuredContent"]["text"]')
    printf '%s\n' "$out" | grep -q '^x=' && break
    sleep 0.1
  done
  # `read` got only the CLI's text: no refused text reached the pty.
  printf '%s\n' "$out" | grep -qxF x=typed-by-the-user
  # With echo on again, the mcp client types.
  run mcp "$(call session_send '{"id":"mcp3","text":"echo after"}')"
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["isError"]')" = "False" ]
}

@test "resources/list gives the two formats, and resources/read gives each schema of assets/" {
  run mcp '{"jsonrpc":"2.0","id":1,"method":"resources/list"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq_py '[x["uri"] for x in r["result"]["resources"]]')" = "['macterm://formats/palette', 'macterm://formats/layout']" ]
  for pair in palette:palette layout:project; do
    uri="macterm://formats/${pair%%:*}"
    file="$REPO_DIR/../assets/${pair#*:}.schema.json"
    run mcp "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":\"$uri\"}}"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["contents"][0]["text"] == open("'"$file"'").read()')" = "True" ]
    [ "$(printf '%s\n' "$output" | jq_py 'len(json.loads(r["result"]["contents"][0]["text"])["examples"])')" = "1" ]
  done
  run mcp '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"macterm://formats/nope"}}'
  [ "$(printf '%s\n' "$output" | jq_py 'r["error"]["code"]')" = "-32002" ]
}
