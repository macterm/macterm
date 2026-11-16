# The v2 protocol

This file loads when you work in `Macterm/Protocol/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## The v2 protocol (`Macterm/Protocol/`)

The frames and messages between the app, the server and the session processes (design/003). The app speaks it on `ServerConnection` (channel 0) and on every pane's channel (`PaneChannel`, `PaneSession`).

- **The Zig messages are the one source** (`server/src/protocol/messages.zig`). The generator is a program of its own (`server/tools/schema.zig`, `zig build schema`, into `server/zig-out/tools`), so the shipped server has none. It writes the Swift types (`Macterm/Protocol/MactermProtocol.generated.swift`), the metadata (`server/schema/protocol.json`) and frames that Zig encoded (`server/schema/frames.json`). `mise run protocol` writes all three. Never edit them by hand.
- **The schema reads types from `messages.zig` and the model** (`server/src/model/`, `name_spaces` in the generator). A type's schema name is its name in its file, so a name must be unique across both. Besides structs, enums, integers and strings, it carries `f64` (always a float 64 on the wire) and tagged unions: `{t: tag, a: payload}`, the shape of a pane message, with no `a` for a case with no payload. A union is an `indirect enum` in Swift, so a split can hold two nodes; `*T` on the wire is the `T`. A new union case needs an `unknown` case, as a new enum case does.
- `MessagePack.swift` and `ProtocolFrame.swift` follow the Zig codec byte for byte. The cap on array memory differs: Swift counts its stride. `ProtocolFixtureTests` decodes each Zig frame and encodes it again to the same bytes.
- **CI checks the schema** (`scripts/protocol.sh --check` in the Server workflow; `mise run protocol --check` locally):
  - The generated files are current.
  - Against the metadata on main: no message, method, type, field, enum case or union case is removed; no type, default, payload or `since` changes; each addition has the current level; a new enum or union case needs an `unknown` case.
  - No message, method, event or pane message gets or loses a sender (`senders`, the trust that may send it, design/006 §2).
  - Against the latest release that has the metadata (`--base-release`, a `v<x.y.z>` or `v<x.y.z>-beta.<n>` tag): the same rules, and an addition needs a level above the release's. Before a release has metadata, this check passes with a line that says so.
  - No method result and no event holds a `secret`.
  - No error code is removed. The codes are `ErrorCode` in `messages.zig`; the app compares `ErrorInfo.errorCode`, never the string.
- A new field in an older type names its level in `field_since`.
- Field names and enum tags are snake_case ASCII (`checkName`), so the Swift String compare is the Zig byte compare.
- `scripts/protocol.sh` needs Zig 0.17 on PATH or in `$ZIG`.
- The generator also writes `PaneMessage.decoded()` and `Event.decoded()` (`PaneMessageKind`, `EventKind`, with `unknown` for a message of a later build). Read a pane message or an event through them, not with a list of names of your own.
- **Resume (protocol level 2, design/003 §7).**
  - A session counts its output bytes and keeps the last 256 KiB in `ring.zig`. The ring grows only with output, to 320 KiB at most.
  - `snapshot.start` carries the `offset` that its screen shows.
  - `attach` can carry `resume_epoch` (the epoch in the session's `hello`) and `resume_offset`. The session answers `resumed` and the missing bytes, with no snapshot and no repaint. It sends a snapshot when the epoch differs or the ring lost the bytes.
  - The server keeps the last 256 event batches. `control.resume {epoch, seq}` replays the batches after `seq`. Otherwise it answers `replayed: false`, and the client reads `session.list`.
  - `macterm connect` tracks its offset and connects again after a lost link. The app's pane channels do not resume: the relay does not give the client the session's epoch, so a lost link draws a snapshot again.
  - The relay needs no change. It drops queued output and then a snapshot follows, so a client's count is a prefix of the stream until the snapshot resets it.
