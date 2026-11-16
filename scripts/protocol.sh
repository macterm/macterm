#!/usr/bin/env bash
# Write the files that the protocol schema makes (design/003 §3), or check
# them. The Zig messages in server/src/protocol/messages.zig are the source.
# The generator is its own program, server/tools/schema.zig, which
# `zig build schema` builds into server/zig-out/tools. The shipped server
# does not have it. It writes:
#
#   Macterm/Protocol/MactermProtocol.generated.swift   the app's Swift types
#   server/schema/protocol.json                        the metadata
#   server/schema/frames.json                          frames for the Swift tests
#
# Usage:
#   scripts/protocol.sh           build the generator, then write the files
#   scripts/protocol.sh --check   fail if a file is not current, or if the
#                                 schema breaks the add-only rule against the
#                                 metadata on $PROTOCOL_BASE (origin/main),
#                                 or changes who may send a message, or if a
#                                 reply or an event holds a secret (CI)
#   scripts/protocol.sh --check --base-release
#                                 the same rules against the metadata of the
#                                 latest release (a v<x.y.z> or
#                                 v<x.y.z>-beta.<n> tag), and an addition
#                                 needs a level above that release's. Before
#                                 a release has metadata, it checks nothing.
#
# Needs Zig 0.17 on PATH, or in $ZIG.
set -euo pipefail

PROJECT_ROOT="$PWD"
ZIG="${ZIG:-zig}"
BASE="${PROTOCOL_BASE:-origin/main}"
METADATA=server/schema/protocol.json

check=false
release=false
for arg in "$@"; do
  case "$arg" in
    --check) check=true ;;
    --base-release) release=true ;;
    *) echo "protocol.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done
if [[ "$release" == "true" && "$check" != "true" ]]; then
  echo "protocol.sh: --base-release needs --check" >&2
  exit 2
fi

(cd "$PROJECT_ROOT/server" && "$ZIG" build schema)
bin="$PROJECT_ROOT/server/zig-out/tools/macterm-schema"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ "$release" == "true" ]]; then
  # The newest release tag whose tree has the metadata. The rolling `tip`
  # tag is not a release. The suffix rule sorts v1.2.0 above v1.2.0-beta.1.
  tag=""
  while read -r t; do
    if git cat-file -e "$t:$METADATA" 2>/dev/null; then
      tag="$t"
      break
    fi
  done < <(git -c versionsort.suffix=-beta tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$')
  if [[ -z "$tag" ]]; then
    echo "protocol.sh: no release tag has $METADATA. The check against a release does not run."
    exit 0
  fi
  echo "protocol.sh: checking against the release $tag."
  git show "$tag:$METADATA" >"$tmp/base.json"
  "$bin" check --release "$tmp/base.json"
  exit 0
fi

outputs=(
  "swift:Macterm/Protocol/MactermProtocol.generated.swift"
  "metadata:$METADATA"
  "fixtures:server/schema/frames.json"
)

stale=false
for entry in "${outputs[@]}"; do
  what="${entry%%:*}"
  path="${entry#*:}"
  "$bin" "$what" >"$tmp/$what"
  if [[ "$check" == "true" ]]; then
    if ! diff -u "$path" "$tmp/$what"; then
      echo "protocol.sh: $path is not current. Run mise run protocol." >&2
      stale=true
    fi
  else
    mkdir -p "$(dirname "$path")"
    cp "$tmp/$what" "$path"
  fi
done

if [[ "$check" == "true" ]]; then
  [[ "$stale" == "true" ]] && exit 1
  # The metadata on the base branch. Before it has one, only the secret
  # check runs.
  if git cat-file -e "$BASE:$METADATA" 2>/dev/null; then
    git show "$BASE:$METADATA" >"$tmp/base.json"
    "$bin" check "$tmp/base.json"
  else
    echo "protocol.sh: $BASE has no $METADATA. Only the secret check runs."
    "$bin" check
  fi
fi
