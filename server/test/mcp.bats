#!/usr/bin/env bats
# `macterm mcp` (src/cli/mcp.zig): JSON-RPC on stdin and stdout, one message
# on each line, against a test server.

load test_helper

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
  pid=$!
  exec 7>"$RT/in"
  printf '%s\n' "$(call session_list '{}')" >&7
  wait_lines 1
  first=$(sed -n 1p "$RT/out")
  [ "$(printf '%s\n' "$first" | jq_py 'r["result"]["isError"]')" = "True" ]
  "$ZMX" __create-session mcp0 -- /bin/sh
  printf '%s\n' "$(call session_list '{}')" >&7
  wait_lines 2
  exec 7>&-
  wait "$pid"
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
  [[ "$(printf '%s\n' "$output" | jq_py 'r["result"]["content"][0]["text"]')" == *"(not_found)" ]]
  run mcp "$(call session_send '{"id":"mcp2"}')"
  [ "$(printf '%s\n' "$output" | jq_py 'r["result"]["content"][0]["text"]')" = "arguments.text: expected a value: the key is required" ]
  run mcp "$(call server_exit '{}')"
  [ "$(printf '%s\n' "$output" | jq_py 'r["error"]["code"]')" = "-32602" ]
  run "$ZMX" session info mcp2
  [ "$status" -eq 0 ]
}
