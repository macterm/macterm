#!/usr/bin/env bash
# Builds the session server in server/ for every target that Macterm carries,
# or prints the key that names such a build.
#
#   scripts/build-server.sh key            print the key of the working tree
#   scripts/build-server.sh key-of <rev>   print the key of a commit
#   scripts/build-server.sh dirty          exit 0 when a source has changes
#                                          that are not committed
#   scripts/build-server.sh targets        print the targets, one a line
#   scripts/build-server.sh build <dir>    build into <dir>
#   scripts/build-server.sh verify <dir> [key]
#                                          exit 0 when <dir> holds the build
#                                          of its manifest, of key <key>
#   scripts/build-server.sh file <dir> <target>
#                                          print the path of the tarball of
#                                          <target>, from the manifest
#   scripts/build-server.sh stage <dir> <tag> <out>
#                                          copy the build of <dir> to <out>,
#                                          with the tag in each file name
#   scripts/build-server.sh download <repo> <release> <key> <dir>
#                                          download the build of <key> into
#                                          <dir> and verify it
#
# The key is the git object hashes of the sources (SOURCES below) from the
# working tree (committed or not), hashed together: the server's code and
# build files, and this script. This script holds the Zig version and every
# build flag, so a change to either is a new key. `macterm mcp` embeds two
# schemas of assets/, so they are sources too. Tests, the protocol schema and
# host scripts are not sources: a change to them is not a new build. A
# prebuilt named for a key is therefore the build of exactly that source
# (`macterm-<key>-<target>.tar.gz`; in the `server-prebuilt` release, see
# below).
#
# A build writes its manifest next to the tarballs: `macterm-<key>-server.json`
# with the key, the targets and the SHA-256 of each tarball. The other
# scripts and the workflows read the targets and check a build with
# `targets` and `verify`, and do not repeat the list or the check.
#
# In the `server-prebuilt` release, every file of a build has the tag of the
# run that uploaded it (`stage`): `macterm-<key>-<target>-<tag>.tar.gz` and
# `macterm-<key>-server-<tag>.json`. CI uses its run as the tag, so two runs
# never write an asset of the same name. A run uploads its manifest last.
# A run that stops before then leaves tarballs that no manifest names, and
# they do not change any build. `download` takes the oldest manifest of the
# key that verifies. It writes it as `macterm-<key>-server.json`, so a
# downloaded build reads as a local build. Get a tarball's name from the
# manifest (`file`). Do not make the name.
#
# The build needs macOS (lipo makes the universal binary) and Zig
# $ZIG_VERSION. Zig cannot link with Xcode 26.4 or later (zig#31658), so CI
# builds on macos-26 with Xcode 26.3 (.github/workflows/server-build.yml).
#
# Each tarball holds one file, `zmx`: the app and the remote installer still
# call the binary by that name.
set -euo pipefail

ZIG_VERSION="0.17.1"
# The asset names of the targets, as `ZmxHostTarget` names them.
TARGETS=(universal-macos x86_64-linux aarch64-linux)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES=(server/src server/build.zig server/build.zig.zon scripts/build-server.sh assets/palette.schema.json assets/project.schema.json)

existing_sources() {
  local path
  for path in "${SOURCES[@]}"; do
    [[ -e "$ROOT/$path" ]] && printf '%s\n' "$path"
  done
}

# The key from the objects of the sources in a tree.
key_from_tree() {
  local tree="$1" path id
  for path in "${SOURCES[@]}"; do
    # A source that the tree does not have hashes as "none".
    id="$(git -C "$ROOT" rev-parse -q --verify "$tree:$path" || echo none)"
    printf '%s %s\n' "$path" "$id"
  done | shasum -a 256 | cut -c1-16
}

# The key of the working tree. For a clean tree it is the key of HEAD.
server_key() {
  local index tree
  # An empty index of our own: `git add` hashes the files as they are on
  # disk, untracked ones too, and respects .gitignore (zig-out, .zig-cache).
  index="$(mktemp -u "${TMPDIR:-/tmp}/macterm-server-index.XXXXXX")"
  local paths=()
  while IFS= read -r p; do paths+=("$p"); done < <(existing_sources)
  if ! GIT_INDEX_FILE="$index" git -C "$ROOT" add -A -- "${paths[@]}" ||
    ! tree="$(GIT_INDEX_FILE="$index" git -C "$ROOT" write-tree)"; then
    rm -f "$index"
    return 1
  fi
  rm -f "$index"
  key_from_tree "$tree"
}

is_dirty() {
  local paths=()
  while IFS= read -r p; do paths+=("$p"); done < <(existing_sources)
  [[ -n "$(git -C "$ROOT" status --porcelain -- "${paths[@]}")" ]]
}

# Tar and gzip with no owner, no time and no name in the header, so the same
# binary gives the same bytes.
package() {
  local dir="$1" out="$2"
  touch -t 200001010000 "$dir/zmx"
  tar -c -f - --uid 0 --gid 0 --uname root --gname root -C "$dir" zmx | gzip -n -9 > "$out"
}

# The manifest of the build `key` in `dir`, from its tarballs.
write_manifest() {
  local dir="$1" key="$2"
  python3 -I - "$dir" "$key" "${TARGETS[@]}" <<'PY'
import hashlib, json, os, sys
folder, key, targets = sys.argv[1], sys.argv[2], sys.argv[3:]
files = {}
for target in targets:
    name = f"macterm-{key}-{target}.tar.gz"
    with open(os.path.join(folder, name), "rb") as f:
        files[target] = {"file": name, "sha256": hashlib.sha256(f.read()).hexdigest()}
manifest = {"key": key, "targets": targets, "files": files}
with open(os.path.join(folder, f"macterm-{key}-server.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
}

# Exit 0 when `dir` holds one manifest (of `key`, when given) whose targets
# are this script's and whose tarballs match their SHA-256. Prints the key.
verify() {
  local dir="$1" key="${2:-}"
  python3 -I - "$dir" "$key" "${TARGETS[@]}" <<'PY'
import glob, hashlib, json, os, sys
folder, key, targets = sys.argv[1], sys.argv[2], sys.argv[3:]
found = glob.glob(os.path.join(folder, f"macterm-{key or '*'}-server.json"))
if len(found) != 1:
    sys.exit(f"error: {folder} has {len(found)} server manifests, not 1")
with open(found[0]) as f:
    manifest = json.load(f)
if key and manifest.get("key") != key:
    sys.exit(f"error: {found[0]} is not the build {key}")
if manifest.get("targets") != targets:
    sys.exit(f"error: {found[0]} has other targets than {' '.join(targets)}")
for target in targets:
    entry = manifest["files"][target]
    path = os.path.join(folder, entry["file"])
    if not os.path.isfile(path):
        sys.exit(f"error: {path} is missing")
    with open(path, "rb") as f:
        if hashlib.sha256(f.read()).hexdigest() != entry["sha256"]:
            sys.exit(f"error: {path} does not match its SHA-256")
print(manifest["key"])
PY
}

# The path of the tarball of `target` in `dir`, from its one manifest.
tarball() {
  local dir="$1" target="$2"
  python3 -I - "$dir" "$target" <<'PY'
import glob, json, os, sys
folder, target = sys.argv[1], sys.argv[2]
found = glob.glob(os.path.join(folder, "macterm-*-server.json"))
if len(found) != 1:
    sys.exit(f"error: {folder} has {len(found)} server manifests, not 1")
with open(found[0]) as f:
    print(os.path.join(folder, json.load(f)["files"][target]["file"]))
PY
}

# Copy the build in `dir` to `out`, with `tag` in the name of each file,
# and a manifest that names the copies.
stage() {
  local dir="$1" tag="$2" out="$3"
  verify "$dir" >/dev/null
  mkdir -p "$out"
  python3 -I - "$dir" "$tag" "$out" <<'PY'
import glob, json, os, shutil, sys
folder, tag, out = sys.argv[1], sys.argv[2], sys.argv[3]
path = glob.glob(os.path.join(folder, "macterm-*-server.json"))[0]
with open(path) as f:
    manifest = json.load(f)
key = manifest["key"]
for target, entry in manifest["files"].items():
    name = f"macterm-{key}-{target}-{tag}.tar.gz"
    shutil.copyfile(os.path.join(folder, entry["file"]), os.path.join(out, name))
    entry["file"] = name
with open(os.path.join(out, f"macterm-{key}-server-{tag}.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
}

# Download the manifest `name` and the tarballs that it names into `dir`.
# Exit 0 when the build verifies.
download_manifest() {
  local repo="$1" release="$2" key="$3" name="$4" dir="$5" target path
  gh release download "$release" --repo "$repo" --dir "$dir" --pattern "$name" || return 1
  if [[ "$name" != "macterm-$key-server.json" ]]; then
    mv "$dir/$name" "$dir/macterm-$key-server.json" || return 1
  fi
  for target in "${TARGETS[@]}"; do
    path="$(tarball "$dir" "$target")" || return 1
    gh release download "$release" --repo "$repo" --dir "$dir" \
      --pattern "$(basename "$path")" || return 1
  done
  verify "$dir" "$key" >/dev/null
}

# Download the build of `key` from a release into `dir`, which must not
# exist. It tries the manifests of the key that are complete, the oldest
# first, and takes the first whose tarballs verify. Prints the name of the
# manifest that it took.
download() {
  local repo="$1" release="$2" key="$3" dir="$4"
  local id manifests name try
  [[ ! -e "$dir" ]] || { echo "error: $dir exists" >&2; return 1; }
  id="$(gh api "repos/$repo/releases/tags/$release" --jq .id)" || return 1
  # The manifest without a tag is the form before tags.
  manifests="$(gh api --paginate "repos/$repo/releases/$id/assets?per_page=100" \
    --jq ".[] | select(.state == \"uploaded\")
      | select(.name | test(\"^macterm-$key-server(-[^/]+)?\\\\.json\$\"))
      | \"\\(.created_at) \\(.name)\"" | sort)" || return 1
  [[ -n "$manifests" ]] || { echo "No build of $key in $release" >&2; return 1; }
  while read -r _ name; do
    try="$(mktemp -d "${TMPDIR:-/tmp}/macterm-server-download.XXXXXX")"
    if download_manifest "$repo" "$release" "$key" "$name" "$try"; then
      mkdir -p "$(dirname "$dir")"
      mv "$try" "$dir"
      echo "$name"
      return 0
    fi
    echo "warning: the build of $name does not verify" >&2
    rm -rf "$try"
  done <<<"$manifests"
  return 1
}

# Global, not local: the EXIT trap runs after build() returns, and under
# `set -u` bash 3.2 then stops on a local that is gone.
WORK=""

build() {
  local out="$1" key version upstream
  [[ "$(uname -s)" == Darwin ]] || { echo "error: the server build needs macOS (lipo)" >&2; exit 1; }
  if ! command -v zig >/dev/null 2>&1; then
    echo "error: the server build needs Zig $ZIG_VERSION, and zig is not on PATH" >&2
    exit 1
  fi
  if [[ "$(zig version)" != "$ZIG_VERSION" ]]; then
    echo "error: the server build needs Zig $ZIG_VERSION, and zig is $(zig version)" >&2
    exit 1
  fi
  key="$(server_key)"
  upstream="$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$ROOT/server/build.zig.zon")"
  [[ -n "$upstream" ]] || { echo "error: no version in server/build.zig.zon" >&2; exit 1; }
  # `zmx version` names the build for people. The key goes in its own option,
  # which `hello.build_key` carries.
  version="${upstream}+thdxg.${key}"

  mkdir -p "$out"
  out="$(cd "$out" && pwd)"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/macterm-server-build.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  local work="$WORK"

  local zig_target strip
  for zig_target in aarch64-macos x86_64-macos x86_64-linux-musl aarch64-linux-musl; do
    # Debug info stays in the Mac build, for crash reports. The Linux builds
    # go to hosts over ssh, so they are stripped.
    strip=false
    [[ "$zig_target" == *-linux-musl ]] && strip=true
    echo "Building the server for $zig_target ($version)"
    (cd "$ROOT/server" && zig build -Doptimize=ReleaseSafe -Dtarget="$zig_target" \
      -Dversion="$version" -Dkey="$key" -Dstrip="$strip" --prefix "$work/$zig_target")
  done

  mkdir -p "$work/universal-macos" "$work/x86_64-linux" "$work/aarch64-linux"
  lipo -create -output "$work/universal-macos/zmx" \
    "$work/aarch64-macos/bin/zmx" "$work/x86_64-macos/bin/zmx"
  # `lipo -archs`, not `-verify_arch`: the lipo of Xcode 27 takes the second
  # only before the file, and older ones only after it.
  local archs
  archs=" $(lipo -archs "$work/universal-macos/zmx") "
  [[ "$archs" == *" arm64 "* && "$archs" == *" x86_64 "* ]] ||
    { echo "error: the macOS build is not universal:$archs" >&2; exit 1; }
  cp "$work/x86_64-linux-musl/bin/zmx" "$work/x86_64-linux/zmx"
  cp "$work/aarch64-linux-musl/bin/zmx" "$work/aarch64-linux/zmx"
  "$work/universal-macos/zmx" version | grep -qF "$version"

  local target
  for target in "${TARGETS[@]}"; do
    package "$work/$target" "$out/macterm-$key-$target.tar.gz"
  done
  write_manifest "$out" "$key"
  echo "Built the server $key into $out"
}

case "${1:-}" in
  key) server_key ;;
  key-of)
    [[ -n "${2:-}" ]] || { echo "usage: $0 key-of <commit>" >&2; exit 2; }
    key_from_tree "$2^{tree}"
    ;;
  dirty) is_dirty ;;
  targets) printf '%s\n' "${TARGETS[@]}" ;;
  verify)
    [[ -n "${2:-}" ]] || { echo "usage: $0 verify <dir> [key]" >&2; exit 2; }
    verify "$2" "${3:-}"
    ;;
  build)
    [[ -n "${2:-}" ]] || { echo "usage: $0 build <dir>" >&2; exit 2; }
    build "$2"
    ;;
  file)
    [[ -n "${3:-}" ]] || { echo "usage: $0 file <dir> <target>" >&2; exit 2; }
    tarball "$2" "$3"
    ;;
  stage)
    [[ -n "${4:-}" ]] || { echo "usage: $0 stage <dir> <tag> <out>" >&2; exit 2; }
    stage "$2" "$3" "$4"
    ;;
  download)
    [[ -n "${5:-}" ]] || { echo "usage: $0 download <repo> <release> <key> <dir>" >&2; exit 2; }
    download "$2" "$3" "$4" "$5"
    ;;
  zig-version) echo "$ZIG_VERSION" ;;
  *)
    echo "usage: $0 key | key-of <commit> | dirty | targets | build <dir> | verify <dir> [key] | file <dir> <target> | stage <dir> <tag> <out> | download <repo> <release> <key> <dir> | zig-version" >&2
    exit 2
    ;;
esac
