# The session server

This file loads when you work in `server/`. The root `AGENTS.md` has the build, the architecture and the conventions.

- **The server has no pin.** `scripts/build-server.sh` builds it for macOS universal and Linux x86_64 and aarch64 (static musl, stripped). That script holds the Zig version and the flags.
  - The build key is the git tree hash of `server/` (without `server/AGENTS.md` and `server/CLAUDE.md`) and that script, from the working tree. An edit to this file makes no new key. `zmx version` reports `1.0.1+thdxg.<key>`.
  - Setup installs the build for the key and records the key in `.server-key`. It takes, in order: `build/server` (CI puts its own build there); a Zig build when `server/` has changes that are not committed; the prebuilt `macterm-<key>-<target>.tar.gz` from the `server-prebuilt` release; a Zig build. Every tarball is checked against its `.sha256`.
  - `.github/workflows/server-build.yml` builds on `macos-15`, because zig cannot link with Xcode 26.4 or later (zig#31658). It takes the prebuilt when it exists. It uploads a new build on `main` and on pull requests from this repository, and never replaces an asset. It removes assets older than 90 days, except the build of main's key.
  - The release workflows build from the commit, never from a prebuilt.
  - `build.sh` refuses a bundle whose server is not the build of the tree.
  - **The app carries a gzip build for every host target** for an install on a host, with no download: `Contents/Resources/server/macterm-<key>-<target>.gz` for `universal-macos`, `x86_64-linux` and `aarch64-linux`. The app reads the build key from the name of the macOS file (`ServerBuilds.bundledKey`); `embed-zmx.sh` names the files with the key of `.server-key`. `setup.sh` makes the Linux files next to `zmx`; `embed-zmx.sh` makes the macOS file from the signed `zmx`, so it has the app's identifier. The app's signature seals all three. `build.sh` refuses a bundle without them or with a macOS file that is not the bundled `zmx`. `build.sh` and `BundledResourcesTests` also check that each Linux file is an ELF binary for its machine.
- **The server is the zmx fork, now in this tree.** It started from upstream zmx v1.0.1 and does not sync. Its v1 verbs (`zmx attach`, `zmx ls`, `zmx kill`) cannot talk to a session daemon from before 1.0. The app uses no v1 verb: local and remote panes are v2 sessions (see `Macterm/Server/AGENTS.md`), and the first v2 launch ends the v1 sessions that panes name. v1 sessions on a host keep running.

## The roaming link (design/009, issue 0201)

A UDP link that carries a host's frames after sleep or a network change, with no login. The ssh connection stays the way in and the standby. The link is built in three parts. Only the app part changes what a user sees.

- **The packet layer is the first part** (`server/src/link/packet.zig`, `Macterm/Link/LinkPacket.swift`). It has no cipher of ours: ChaCha20-Poly1305 from the Zig standard library and CryptoKit. A packet is `key_id u32`, `counter u64` (bit 63 is the direction), the sealed payload and the 16 byte tag. The nonce is 4 zero bytes and the counter. The 12 byte header is the associated data.
- **The roam rule:** `open` says if a counter is the newest. A caller may move the peer's address only on a packet that authenticates *and* is the newest. The replay window is 64 packets. It moves only after the tag is good.
- **A packet that does not authenticate gets no reply.** The two sides must make the same bytes: the vector in `packet.zig` is checked again in `LinkPacketTests`. `zig build fuzz-link --fuzz=…` fuzzes the parser, and CI runs it (`server.yml`).

## Session daemons and macOS attribution (#419)

macOS attributes work that needs privacy permission (Local Network, TCC) to the *responsible process* of a process. The value is fixed when the process starts, and the process inherits it from its parent.

- Because of this, the whole tree of a pane belonged to the Macterm that created its session. It belonged to nothing after that Macterm quit. Every process that survives becomes responsible for itself. A new start of Macterm that connects again over the zmx socket never attributes it again, because a connect is not a fork.
- From then on, macOS judged each pane program by its own identity. For anything that Apple did not sign, this meant `EHOSTUNREACH` on the local subnet, with no prompt.
- The fix is in the zmx fork (change 0004, `daemonize.zig`). On macOS, the session daemon starts itself again with `POSIX_SPAWN_SETEXEC` and `responsibility_spawnattrs_setdisclaim`. It is its own responsible process from the first instant. Every program in the session belongs to **it** for the whole life of the session, whatever happens to the app.

- **The daemon has the signature of the app itself** (`scripts/embed-zmx.sh`). It uses the certificate of the app *and* the bundle identifier of the app. The certificate is the release certificate in CI, and it is ad-hoc on your Mac.
  - macOS identifies a responsible process by the identifier in its code signature. With the identifier of Macterm, the daemon resolves to the name of Macterm, its usage descriptions and its existing grants for Local Network and TCC. One grant covers the app and every pane.
  - Any other identifier names a second thing and needs a second grant. Examples: the `zmx` of the release download, which the linker signed, and a separate "Macterm Sessions". We tried the second one. The prompt only said "zmx", because a bare binary has no LaunchServices record that gives it a name.
  - Xcode never signs a Mach-O again when it copies it into `Resources/`. An ad-hoc daemon would be a new identity at every update.
  - `build.sh` refuses a release bundle whose zmx is ad-hoc or is not `com.thdxg.macterm`. `BundledResourcesTests` pins the identifier on the zmx of the built bundle. A change in a build phase therefore cannot turn every pane prompt into a prompt for "zmx" in silence.
- Full Disk Access follows the same attribution. The programs of the daemon satisfy the own TCC requirement of the app (identifier and certificate). They inherit its FDA grant, and this stays true after the first new start.
- You cannot change responsibility afterwards (`responsibility_set_*` needs a private entitlement). The disclaim exists only as a spawn attribute. This is why the daemon starts itself again in place, and why the fork has no flag for it. The responsible root must *stay* a zmx process. A trampoline that ran the shell with exec would keep the pid, but the identity that macOS evaluates would become the identity of the shell.
- A session that an older build created keeps its old attribution until you create it again. The fix takes effect for each session.
- To measure, use `responsibility_get_pid_responsible_for_pid` (a probe in C of ten lines). A Local Network prompt that nobody *answered* denies everything under that responsible process, also platform binaries. A subnet that looks dead can be a dialog that waits.
