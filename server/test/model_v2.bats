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
assert names == ["project.set", "project.order"], names
assert b["ev"][0]["a"]["project"]["name"] == "One"
# The other client gets the same batch with no cause.
ob = other.wait(lambda: [v for v in other.control() if isinstance(v, dict) and v.get("seq") == seq + 1], what="the batch")
ob = [v for v in other.control() if isinstance(v, dict) and v.get("seq") == seq + 1][0]
assert ob.get("cause") is None and [e["e"] for e in ob["ev"]] == names

pane = lambda pid: {"t": "pane", "a": {"id": pid, "session": "macterm-x-" + pid}}
tree = {"t": "split", "a": {"id": "s1", "dir": "horizontal", "ratio": 0.5, "first": pane("a"), "second": pane("b")}}
rid = c.next_id
c.call("tab.create", project="p1", id="t1", root=tree)
b = batch_of(c, rid)
tab = next(e["a"] for e in b["ev"] if e["e"] == "tab.set")
assert tab["project"] == "p1" and tab["tab"]["focused"] == "a", tab
order = next(e["a"] for e in b["ev"] if e["e"] == "tab.order")
assert order == {"project": "p1", "ids": ["t1"], "active_tab": "t1"}, order

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

# A project with tabs holds a project too. A project that holds one is not removed.
rid = c.next_id
assert c.call("project.create", id="p2", name="Two", path="/tmp/two", parent="p1") == {}
orders = [e["a"] for e in batch_of(c, rid)["ev"] if e["e"] == "project.order"]
assert orders == [{"parent": "p1", "ids": ["p2"]}], orders
assert c.request("project.remove", id="p1")["err"]["code"] == "invalid_args"
assert c.call("project.reorder", parent="p1", ids=["p2"]) == {}
assert c.call("project.remove", id="p2").get("panes", []) == []

# Errors: an id in use, an unknown id, a request that the model refuses.
assert c.request("tab.create", project="p1", id="t2", root=pane("a"))["err"]["code"] == "duplicate_id"
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
assert [e["a"] for e in b["ev"] if e["e"] == "tab.remove"] == [{"project": "p1", "id": "t1"}]
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
c.send_msg(CONTROL, {"id": 50, "m": "tab.create", "a": {"project": "p1", "id": "t1", "root": pane}})
c.wait(lambda: [v for v in c.control() if isinstance(v, dict) and v.get("re") == 50], what="the reply")
batches = lambda cl: [v for v in cl.control() if isinstance(v, dict) and "seq" in v]
n = len(batches(c))
c.send_msg(CONTROL, {"id": 50, "m": "tab.create", "a": {"project": "p1", "id": "t1", "root": pane}})
c.wait(lambda: len([v for v in c.control() if isinstance(v, dict) and v.get("re") == 50]) == 2, what="the second reply")
replies = [v for v in c.control() if isinstance(v, dict) and v.get("re") == 50]
assert replies[0] == replies[1] and "ok" in replies[1], replies
assert len(batches(c)) == n, "no second batch"

# A new connection: the same request id is a new request.
d = ServerClient(level=3)
d.send_msg(CONTROL, {"id": 50, "m": "tab.create", "a": {"project": "p1", "id": "t1", "root": pane}})
d.wait(lambda: [v for v in d.control() if isinstance(v, dict) and v.get("re") == 50], what="the reply")
assert [v for v in d.control() if isinstance(v, dict) and v.get("re") == 50][0]["err"]["code"] == "duplicate_id"

# A connection that resumes as the first client gets the first reply.
e = ServerClient(level=3)
e.call("control.resume", epoch=st["epoch"], seq=st["seq"], client=st["client"])
e.send_msg(CONTROL, {"id": 50, "m": "tab.create", "a": {"project": "p1", "id": "t1", "root": pane}})
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
c.call("tab.create", project="p1", id="t1", root={"t": "pane", "a": {"id": "a", "session": "macterm-x-a"}})
deadline = time.time() + 5
while not os.path.exists(path):
    assert time.time() < deadline, "no model.json"
    time.sleep(0.02)
time.sleep(0.3)
saved = json.load(open(path))
assert saved["version"] == 2 and "workspaces" not in saved, saved
assert saved["projects"][0]["tabs"][0]["id"] == "t1"

# A change, then server.exit at once: the old server writes before it
# answers, and the new one reads it.
c.call("tab.set", id="t1", title="kept")
assert c.call("server.exit") == {}
assert os.system(os.environ["ZMX"] + " server") == 0
n = ServerClient(level=3)
model = n.call("state.subscribe")["model"]
assert model["projects"][0]["id"] == "p1"
assert model["projects"][0]["tabs"][0]["custom_title"] == "kept", model
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
bad = {"projects": [{"id": "p1", "name": "One", "path": "/a", "active_tab": "zz"}]}
res = c.request("model.import", model=bad, source="test")
assert res["err"]["code"] == "invalid_args" and "projects[0].active_tab" in res["err"]["message"], res
good = {
    "projects": [{"id": "p1", "name": "One", "path": "/a", "tabs": [
        {"id": "t1", "root": {"t": "pane", "a": {"id": "a", "session": "macterm-x-a"}}, "focused": "a"}], "active_tab": "t1"}],
    "selection": {"active_project": "p1"},
}
c.call("model.import", model=good, source="test")
st = c.call("state.subscribe")
assert st["model"]["imported_v1"] is True and st["model"]["projects"][0]["tabs"][0]["id"] == "t1", st
assert c.request("model.import", model=good, source="test")["err"]["code"] == "refused"
PY
}

@test "model: model.replace replaces the model each time, and ends no session" {
  "$ZMX" server
  "$ZMX" __create-session macterm-x-a -- /bin/sh
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient(level=3)
c.call("state.subscribe")
bad = {"projects": [{"id": "p1", "name": "One", "path": "/a", "active_tab": "zz"}]}
assert c.request("model.replace", model=bad)["err"]["code"] == "invalid_args"
def model(tab):
    return {
        "projects": [{"id": "p1", "name": "One", "path": "/a", "tabs": [
            {"id": tab, "root": {"t": "pane", "a": {"id": "a", "session": "macterm-x-a"}}, "focused": "a"}], "active_tab": tab}],
    }
c.call("model.replace", model=model("t1"))
c.call("model.replace", model=model("t2"))
st = c.call("state.subscribe")
assert st["model"]["imported_v1"] is False and st["model"]["projects"][0]["tabs"][0]["id"] == "t2", st
# The pane of t1 left with its tab, and its session stays.
assert c.call("model.replace", model={}) == {}
assert any(s["id"] == "macterm-x-a" for s in c.call("session.list")["sessions"])
# After an import, the model is the server's: a replace is refused.
c.call("model.import", model=model("t3"), source="test")
assert c.request("model.replace", model=model("t4"))["err"]["code"] == "refused"
PY
}

@test "model: a pane that leaves the model ends its local session" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient, wait_dead
c = ServerClient(level=3)
s = c.call("session.create", id="macterm-x-a", command=[b"/bin/sh"])["session"]
c.call("project.create", id="p1", name="One", path="/tmp/one")
c.call("tab.create", project="p1", id="t1", root={"t": "pane", "a": {"id": "a", "session": "macterm-x-a"}})
c.call("pane.close", id="a")
c.wait_event("session.exit", lambda a: a["id"] == "macterm-x-a")
wait_dead(s["pid"])
PY
}

@test "model: a session that another pane names, and a remote pane's session, stay" {
  "$ZMX" server
  python3 - <<'PY'
import time
from v2client import ServerClient, alive
c = ServerClient(level=3)
s = c.call("session.create", id="shared", command=[b"/bin/sh"])["session"]
r = c.call("session.create", id="remote-name", command=[b"/bin/sh"])["session"]
c.call("project.create", id="p1", name="One", path="/tmp/one")
c.call("tab.create", project="p1", id="t1", root={"t": "pane", "a": {"id": "a", "session": "shared"}})
c.call("tab.create", project="p1", id="t2", root={"t": "pane", "a": {"id": "b", "session": "shared"}})
c.call("tab.create", project="p1", id="t3", root={"t": "pane", "a": {"id": "c", "session": "remote-name", "host": "me@host"}})
assert [p["id"] for p in c.call("pane.close", id="b")["panes"]] == ["b"]
res = c.call("tab.close", id="t3")
assert res["panes"] == [{"id": "c", "session": "remote-name", "host": "me@host"}], res
time.sleep(0.5)
assert alive(s["pid"]) and alive(r["pid"])
assert set(c.sessions()) == {"shared", "remote-name"}
PY
}

@test "model: tabs and panes move between tabs and projects with no pane lost" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient(level=3)
pane = lambda pid: {"t": "pane", "a": {"id": pid, "session": "macterm-x-" + pid}}
c.call("project.create", id="p1", name="One", path="/tmp/one")
c.call("project.create", id="pin", name="Pinned", sidebar="top", removable=False, alias="pinned")
c.call("tab.create", project="p1", id="t1", root=pane("a"))
c.call("tab.create", project="p1", id="t2", root=pane("b"))
c.call("tab.move", id="t2", to_project="pin")
c.call("pane.move", id="a", dest="b", zone="left", split_id="s1")
c.call("pane.separate", id="a", tab_id="t3")
c.call("tab.merge", src="t3", dst="t2", target_pane="b", zone="bottom", split_id="s2")
m = c.call("state.subscribe")["model"]
pin = next(p for p in m["projects"] if p["id"] == "pin")
assert [t["id"] for t in pin["tabs"]] == ["t2"] and pin["active_tab"] == "t2", pin
root = pin["tabs"][0]["root"]
assert root["t"] == "split" and root["a"]["dir"] == "vertical", root
assert next(p for p in m["projects"] if p["id"] == "p1").get("tabs", []) == []
assert "pane.removed" not in [e["e"] for e in c.events()]
PY
}

@test "model: the capability fields of a project refuse what they do not allow" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient(level=3)
pane = lambda pid: {"t": "pane", "a": {"id": pid, "session": "macterm-x-" + pid}}
c.call("project.create", id="p1", name="One", path="/tmp/one")
c.call("project.create", id="pin", name="Pinned", sidebar="top", removable=False, alias="pinned")
c.call("project.create", id="w1", name="Widget", sidebar="none", single_tab=True)
st = c.call("state.subscribe")["model"]
pin = next(p for p in st["projects"] if p["id"] == "pin")
assert pin["sidebar"] == "top" and pin["removable"] is False and pin["alias"] == "pinned", pin
# An alias is unique. A hidden project is at the top level and holds no project.
assert c.request("project.create", id="pin2", name="P", sidebar="top", alias="pinned")["err"]["code"] == "duplicate_id"
assert c.request("project.create", id="x", name="X", path="/x", parent="pin")["err"]["code"] == "invalid_args"
assert c.request("project.create", id="y", name="Y", sidebar="bottom", parent="p1")["err"]["code"] == "invalid_args"
assert c.request("project.set", id="pin", parent="p1")["err"]["code"] == "invalid_args"
# A single_tab project holds one tab.
c.call("tab.create", project="w1", id="t1", root=pane("a"))
assert c.request("tab.create", project="w1", id="t2", root=pane("b"))["err"]["code"] == "refused"
c.call("tab.create", project="p1", id="t3", root=pane("c"))
assert c.request("tab.move", id="t3", to_project="w1")["err"]["code"] == "refused"
# No window selects a project that no window draws.
assert c.request("select.set", project="w1")["err"]["code"] == "refused"
assert c.request("select.set", tab="t1")["err"]["code"] == "refused"
assert c.call("select.set", project="pin") == {}
# A project that is not removable stays; a widget goes with its tab.
assert c.request("project.remove", id="pin")["err"]["code"] == "refused"
res = c.call("project.remove", id="w1")
assert [p["id"] for p in res["panes"]] == ["a"], res
c.wait_event("project.remove", lambda a: a["id"] == "w1")
# The order of the top level has the tree projects only.
assert c.call("project.reorder", ids=["p1"]) == {}
assert c.request("project.reorder", ids=["p1", "pin"])["err"]["code"] == "invalid_args"
PY
}

@test "model: a model.json of version 1 with workspaces loads, and the server writes version 2" {
  mkdir -p "$RT/state"
  cat > "$RT/state/model.json" <<'JSON'
{"version": 1,
 "projects": [{"id": "p1", "name": "One", "path": "/a", "kind": "project"},
              {"id": "g1", "name": "G", "path": "", "kind": "group"}],
 "workspaces": [{"id": "p1", "kind": "project", "active_tab": "t1",
                 "tabs": [{"id": "t1", "root": {"pane": {"id": "a", "session": "macterm-x-a"}}}]},
                {"id": "pin", "kind": "pinned"},
                {"id": "q", "kind": "quick", "tabs": [{"id": "t2", "root": {"pane": {"id": "b", "session": "macterm-x-b"}}}]}],
 "selection": {"active_project": "p1"}}
JSON
  "$ZMX" server
  python3 - <<'PY'
import json, os, time
from v2client import ServerClient
c = ServerClient(level=3)
st = c.call("state.subscribe")
assert st["readonly"] is False, st
projects = {p["id"]: p for p in st["model"]["projects"]}
assert set(projects) == {"p1", "g1", "pin", "q"}, projects
assert projects["p1"]["tabs"][0]["id"] == "t1" and projects["p1"]["active_tab"] == "t1"
assert projects["pin"]["alias"] == "pinned" and projects["pin"]["sidebar"] == "top"
assert projects["q"]["alias"] == "quick" and projects["q"]["single_tab"] is True and projects["q"]["tabs"][0]["id"] == "t2"
c.call("tab.set", id="t1", title="new")
path = os.path.join(os.environ["MACTERM_STATE_DIR"], "model.json")
deadline = time.time() + 5
while json.load(open(path))["version"] != 2:
    assert time.time() < deadline, "no version 2"
    time.sleep(0.05)
saved = json.load(open(path))
assert "workspaces" not in saved and all("kind" not in p for p in saved["projects"]), saved
PY
}

@test "model: model.options sets the rebalance of a request that does not say" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient(level=3)
pane = lambda pid: {"id": pid, "session": "macterm-x-" + pid}
c.call("project.create", id="p1", name="One", path="/tmp/one")
c.call("tab.create", project="p1", id="t1", root={"t": "pane", "a": pane("a")})
c.call("pane.split", tab="t1", target="a", new=pane("b"), split_id="s1", dir="horizontal")
c.call("pane.split", tab="t1", target="b", new=pane("c"), split_id="s2", dir="horizontal")
root = c.call("state.subscribe")["model"]["projects"][0]["tabs"][0]["root"]
assert root["a"]["ratio"] == 0.5, root
c.call("model.options", auto_tiling=True)
c.call("pane.split", tab="t1", target="c", new=pane("d"), split_id="s3", dir="horizontal")
root = c.call("state.subscribe")["model"]["projects"][0]["tabs"][0]["root"]
assert abs(root["a"]["ratio"] - 0.25) < 1e-9, root
PY
}

@test "model: a file that does not parse is read-only and stays as it was" {
  mkdir -p "$RT/state"
  printf 'not json\n' > "$RT/state/model.json"
  "$ZMX" server
  python3 - <<'PY'
import os, signal
from v2client import ServerClient, wait_dead
c = ServerClient(level=3)
assert c.call("state.subscribe")["readonly"] is True
assert c.request("model.import", model={}, source="test")["err"]["code"] == "model_readonly"
assert c.call("model.options", auto_tiling=True) == {}
pid = c.peer_pid()
os.kill(pid, signal.SIGTERM)
wait_dead(pid)
PY
  [ "$(cat "$RT/state/model.json")" = "not json" ]
}
