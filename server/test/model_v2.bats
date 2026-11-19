#!/usr/bin/env bats
# The model on the server's socket (src/model_ipc.zig, design/010 §2, §3):
# `state.subscribe`, the model requests and their events, `cause`, the ring
# of request ids, and `model.json` across a new server. test/v2client.py is
# the client.

load test_helper

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
}

# The helper's setup, and a state folder for `model.json`.
setup() {
  ZMX="${ZMX:-$REPO_DIR/zig-out/bin/zmx}"
  if [[ ! -x "$ZMX" ]]; then
    (cd "$REPO_DIR" && zig build)
  fi
  RT="$(mktemp -d "${TMPDIR:-/tmp}/rt.XXXXXX")"
  export MACTERM_RUNTIME_DIR="$RT/run"
  export MACTERM_STATE_DIR="$RT/state"
  export ZMX RT
}

@test "model: a server with no state folder has no model" {
  unset MACTERM_STATE_DIR
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient(level=3)
st = c.call("state.subscribe")
assert st.get("model") is None, st
assert st["sessions"] == []
res = c.request("project.create", id="p1", name="One", path="/tmp")
assert res["err"]["code"] == "unavailable", res
PY
  [ ! -e "$RT/state" ]
}

@test "model: requests make one batch each, with cause on the requester's connection" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient, CONTROL
c = ServerClient(level=3)
other = ServerClient(level=3)
st = c.call("state.subscribe")
assert st["model"]["projects"] == [] and st["readonly"] is False, st
seq = st["seq"]

def batch_of(client, rid):
    """The batch with `cause` rid on the requester's side, and the reply
    after it."""
    msgs = [v for v in client.control() if isinstance(v, dict)]
    at = next(i for i, v in enumerate(msgs) if v.get("cause") == rid)
    reply = next(i for i, v in enumerate(msgs) if v.get("re") == rid)
    assert at < reply, "the batch goes before the reply"
    return msgs[at]

rid = c.next_id
assert c.call("project.create", id="p1", name="One", path="/tmp/one") == {}
b = batch_of(c, rid)
assert b["seq"] == seq + 1
names = [e["e"] for e in b["ev"]]
assert names == ["project.set", "project.order", "tab.order"], names
assert b["ev"][0]["a"]["project"]["name"] == "One"
# The other client gets the same batch with no cause.
ob = other.wait(lambda: [v for v in other.control() if isinstance(v, dict) and v.get("seq") == seq + 1], what="the batch")
ob = [v for v in other.control() if isinstance(v, dict) and v.get("seq") == seq + 1][0]
assert ob.get("cause") is None and [e["e"] for e in ob["ev"]] == names

pane = lambda pid: {"t": "pane", "a": {"id": pid, "session": "macterm-x-" + pid}}
tree = {"t": "split", "a": {"id": "s1", "dir": "horizontal", "ratio": 0.5, "first": pane("a"), "second": pane("b")}}
rid = c.next_id
c.call("tab.create", workspace="p1", id="t1", root=tree)
b = batch_of(c, rid)
tab = next(e["a"] for e in b["ev"] if e["e"] == "tab.set")
assert tab["workspace"] == "p1" and tab["tab"]["focused"] == "a", tab
order = next(e["a"] for e in b["ev"] if e["e"] == "tab.order")
assert order == {"workspace": "p1", "kind": "project", "ids": ["t1"], "active_tab": "t1"}, order

rid = c.next_id
c.call("pane.split", tab="t1", target="b", new={"id": "c", "session": "macterm-x-c"}, split_id="s2", dir="vertical")
tab = next(e["a"] for e in batch_of(c, rid)["ev"] if e["e"] == "tab.set")
assert tab["tab"]["focused"] == "c", tab
assert tab["tab"]["root"]["a"]["second"]["a"]["id"] == "s2"

rid = c.next_id
c.call("split.ratio", id="s1", ratio=0.3)
tab = next(e["a"] for e in batch_of(c, rid)["ev"] if e["e"] == "tab.set")
assert abs(tab["tab"]["root"]["a"]["ratio"] - 0.3) < 1e-9

rid = c.next_id
c.call("pane.zoom", tab="t1", pane="a")
tab = next(e["a"] for e in batch_of(c, rid)["ev"] if e["e"] == "tab.set")
assert tab["zoomed"] == "a" and tab["tab"]["focused"] == "a", tab
assert c.call("state.subscribe")["zoomed"] == [{"tab": "t1", "pane": "a"}]

# Errors: an id in use, an unknown id, a request that the model refuses.
assert c.request("tab.create", workspace="p1", id="t2", root=pane("a"))["err"]["code"] == "duplicate_id"
assert c.request("pane.focus", id="nope")["err"]["code"] == "not_found"
assert c.request("project.reorder", ids=["p1", "p1"])["err"]["code"] == "invalid_args"
assert c.request("pane.split", tab="t1", target="b", new={"id": "d", "session": "x"}, split_id="s3", dir="sideways")["err"]["code"] == "invalid_args"
# A refused request sends no batch.
before = len([v for v in c.control() if isinstance(v, dict) and "seq" in v])
assert c.request("tab.close", id="nope")["err"]["code"] == "not_found"
assert len([v for v in c.control() if isinstance(v, dict) and "seq" in v]) == before

# The selection, then a close: the panes leave the model.
rid = c.next_id
c.call("select.set", project="p1", tab="t1")
assert [e["a"] for e in batch_of(c, rid)["ev"] if e["e"] == "selection"] == [{"active_project": "p1"}]
rid = c.next_id
res = c.call("tab.close", id="t1")
assert sorted(p["id"] for p in res["panes"]) == ["a", "b", "c"], res
b = batch_of(c, rid)
gone = sorted(e["a"]["id"] for e in b["ev"] if e["e"] == "pane.removed")
assert gone == ["a", "b", "c"], b
assert [e["a"] for e in b["ev"] if e["e"] == "tab.remove"] == [{"workspace": "p1", "id": "t1"}]
PY
}

@test "model: a request sent again gets its first reply, also after a resume" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient, CONTROL
c = ServerClient(level=3)
st = c.call("state.subscribe")
c.call("project.create", id="p1", name="One", path="/tmp/one")
pane = {"t": "pane", "a": {"id": "a", "session": "macterm-x-a"}}
c.send_msg(CONTROL, {"id": 50, "m": "tab.create", "a": {"workspace": "p1", "id": "t1", "root": pane}})
c.wait(lambda: [v for v in c.control() if isinstance(v, dict) and v.get("re") == 50], what="the reply")
batches = lambda cl: [v for v in cl.control() if isinstance(v, dict) and "seq" in v]
n = len(batches(c))
c.send_msg(CONTROL, {"id": 50, "m": "tab.create", "a": {"workspace": "p1", "id": "t1", "root": pane}})
c.wait(lambda: len([v for v in c.control() if isinstance(v, dict) and v.get("re") == 50]) == 2, what="the second reply")
replies = [v for v in c.control() if isinstance(v, dict) and v.get("re") == 50]
assert replies[0] == replies[1] and "ok" in replies[1], replies
assert len(batches(c)) == n, "no second batch"

# A new connection: the same request id is a new request.
d = ServerClient(level=3)
d.send_msg(CONTROL, {"id": 50, "m": "tab.create", "a": {"workspace": "p1", "id": "t1", "root": pane}})
d.wait(lambda: [v for v in d.control() if isinstance(v, dict) and v.get("re") == 50], what="the reply")
assert [v for v in d.control() if isinstance(v, dict) and v.get("re") == 50][0]["err"]["code"] == "duplicate_id"

# A connection that resumes as the first client gets the first reply.
e = ServerClient(level=3)
e.call("control.resume", epoch=st["epoch"], seq=st["seq"], client=st["client"])
e.send_msg(CONTROL, {"id": 50, "m": "tab.create", "a": {"workspace": "p1", "id": "t1", "root": pane}})
e.wait(lambda: [v for v in e.control() if isinstance(v, dict) and v.get("re") == 50], what="the reply")
assert "ok" in [v for v in e.control() if isinstance(v, dict) and v.get("re") == 50][0]
PY
}

@test "model: model.json survives a new server, and is on disk 100 ms after a change" {
  "$ZMX" server
  python3 - <<'PY'
import json, os, time
from v2client import ServerClient
path = os.path.join(os.environ["MACTERM_STATE_DIR"], "model.json")
c = ServerClient(level=3)
c.call("project.create", id="p1", name="One", path="/tmp/one")
c.call("tab.create", workspace="p1", id="t1", root={"t": "pane", "a": {"id": "a", "session": "macterm-x-a"}})
deadline = time.time() + 5
while not os.path.exists(path):
    assert time.time() < deadline, "no model.json"
    time.sleep(0.02)
time.sleep(0.3)
assert json.load(open(path))["workspaces"][0]["tabs"][0]["id"] == "t1"

# A change, then server.exit at once: the old server writes before it
# answers, and the new one reads it.
c.call("tab.set", id="t1", title="kept")
assert c.call("server.exit") == {}
assert os.system(os.environ["ZMX"] + " server") == 0
n = ServerClient(level=3)
model = n.call("state.subscribe")["model"]
assert model["projects"][0]["id"] == "p1"
assert model["workspaces"][0]["tabs"][0]["custom_title"] == "kept", model
PY
}

@test "model: SIGTERM writes the model" {
  "$ZMX" server
  python3 - <<'PY'
import json, os, signal
from v2client import ServerClient, wait_dead
c = ServerClient(level=3)
c.call("project.create", id="p1", name="One", path="/tmp/one")
pid = c.peer_pid()
os.kill(pid, signal.SIGTERM)
wait_dead(pid)
path = os.path.join(os.environ["MACTERM_STATE_DIR"], "model.json")
assert json.load(open(path))["projects"][0]["id"] == "p1"
PY
}

@test "model: a file of a newer build is read-only and stays as it was" {
  mkdir -p "$RT/state"
  printf '{"version": 99, "projects": []}\n' > "$RT/state/model.json"
  cp "$RT/state/model.json" "$RT/before.json"
  "$ZMX" server
  python3 - <<'PY'
import os, signal
from v2client import ServerClient, wait_dead
c = ServerClient(level=3)
assert c.call("state.subscribe")["readonly"] is True
assert c.request("project.create", id="p1", name="One", path="/tmp")["err"]["code"] == "model_readonly"
pid = c.peer_pid()
os.kill(pid, signal.SIGTERM)
wait_dead(pid)
PY
  cmp "$RT/state/model.json" "$RT/before.json"
}

@test "model: model.import replaces the model once" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient(level=3)
c.call("state.subscribe")
bad = {"projects": [{"id": "p1", "name": "One", "path": "/a"}], "workspaces": []}
res = c.request("model.import", model=bad, source="test")
assert res["err"]["code"] == "invalid_args" and "workspaces" in res["err"]["message"], res
good = {
    "projects": [{"id": "p1", "name": "One", "path": "/a"}],
    "workspaces": [{"id": "p1", "kind": "project", "tabs": [
        {"id": "t1", "root": {"t": "pane", "a": {"id": "a", "session": "macterm-x-a"}}, "focused": "a"}], "active_tab": "t1"}],
    "selection": {"active_project": "p1"},
}
c.call("model.import", model=good, source="test")
st = c.call("state.subscribe")
assert st["model"]["imported_v1"] is True and st["model"]["workspaces"][0]["tabs"][0]["id"] == "t1", st
assert c.request("model.import", model=good, source="test")["err"]["code"] == "refused"
PY
}

@test "model: a pane that leaves the model ends its local session" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient, wait_dead
c = ServerClient(level=3)
s = c.call("session.create", id="macterm-x-a", command=[b"/bin/sh"])["session"]
c.call("project.create", id="p1", name="One", path="/tmp/one")
c.call("tab.create", workspace="p1", id="t1", root={"t": "pane", "a": {"id": "a", "session": "macterm-x-a"}})
c.call("pane.close", id="a")
c.wait_event("session.exit", lambda a: a["id"] == "macterm-x-a")
wait_dead(s["pid"])
PY
}
