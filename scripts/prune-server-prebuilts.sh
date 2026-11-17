#!/usr/bin/env bash
# Removes old builds from the `server-prebuilt` release.
#
#   scripts/prune-server-prebuilts.sh [--dry-run]
#
# It keeps these builds and removes all others:
#   - the build of main's key,
#   - the build of the key of the head commit of each open pull request, and
#     of its merge commit (CI on a pull request builds the merge commit),
#   - each build that has an asset from the last $KEEP_DAYS days.
# Setup downloads the build of its key, and the Zig fallback cannot link on
# macOS with Xcode 26.4 or later (zig#31658). Thus a checkout whose build is
# gone cannot run `mise run setup` on such a Mac.
#
# A build is all the assets of one key (`macterm-<key>-*`). The script removes
# a build as a whole, the manifest first: setup and CI take a build only when
# its manifest is there. When the script cannot find the key of main or of an
# open pull request, it removes nothing (fail closed).
#
# The key of a commit comes from that commit's own scripts/build-server.sh, so
# a change to the list of sources gives the key that CI gave that commit.
#
# Needs gh with write access to the release (GH_TOKEN in CI). The repository
# is GITHUB_REPOSITORY, or the `origin` remote.
set -euo pipefail

RELEASE="server-prebuilt"
KEEP_DAYS=14

dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
GIT_DIR_ABS="$(git -C "$ROOT" rev-parse --absolute-git-dir)"
work="$(mktemp -d "${TMPDIR:-/tmp}/macterm-prune.XXXXXX")"
# A ref of this run only, removed at the exit.
REF="refs/prune-server-prebuilts/$$"
trap 'git -C "$ROOT" update-ref -d "$REF" 2> /dev/null || true; rm -rf "$work"' EXIT

# Prints the key of a commit, with the build-server.sh of that commit.
key_of() {
  local rev="$1" dir
  dir="$(mktemp -d "$work/rev.XXXXXX")"
  mkdir -p "$dir/scripts"
  git -C "$ROOT" show "$rev:scripts/build-server.sh" > "$dir/scripts/build-server.sh" || return 1
  GIT_DIR="$GIT_DIR_ABS" bash "$dir/scripts/build-server.sh" key-of "$rev"
}

# A shallow clone (CI) fetches one commit. A full clone stays full.
depth=--no-tags
[[ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" == true ]] && depth=--depth=1

# Fetches a ref from origin and prints the key of its commit.
key_of_remote() {
  local ref="$1"
  git -C "$ROOT" fetch -q "$depth" origin "+$ref:$REF" || return 1
  key_of "$REF"
}

fail_closed() {
  echo "::warning::$1. No prebuilt is removed."
  exit 0
}

keep="$work/keep"
main_key="$(key_of_remote refs/heads/main)" || fail_closed "Cannot find the key of main"
echo "$main_key main" > "$keep"

prs="$(gh pr list --repo "$REPO" --state open --limit 1000 --json number --jq '.[].number')" ||
  fail_closed "Cannot list the open pull requests"
for pr in $prs; do
  key="$(key_of_remote "refs/pull/$pr/head")" || fail_closed "Cannot find the key of pull request $pr"
  echo "$key #$pr" >> "$keep"
  # A pull request with a conflict has no merge commit.
  if key="$(key_of_remote "refs/pull/$pr/merge" 2> /dev/null)"; then
    echo "$key #$pr-merge" >> "$keep"
  fi
done

# The cutoff as the API writes times, so that a string compare is a time compare.
cutoff="$(date -u -d "-$KEEP_DAYS days" +%Y-%m-%dT%H:%M:%SZ 2> /dev/null ||
  date -u -v-"$KEEP_DAYS"d +%Y-%m-%dT%H:%M:%SZ)"

release_id="$(gh api "repos/$REPO/releases/tags/$RELEASE" --jq .id)"
# One line for each asset: key, created_at, id, name. The manifest sorts first
# in its build, so it is removed first.
gh api --paginate "repos/$REPO/releases/$release_id/assets?per_page=100" \
  --jq '.[] | "\(.created_at) \(.id) \(.name)"' |
  awk '{
    if (match($3, /^macterm-[0-9a-f]+-/) == 0) next
    key = substr($3, 9, RLENGTH - 9)
    first = ($3 ~ /-server\.json$/) ? 0 : 1
    print key, first, $1, $2, $3
  }' | sort -k1,1 -k2,2n > "$work/assets"

# The newest asset of each key.
awk '{ if ($3 > newest[$1]) newest[$1] = $3 } END { for (k in newest) print k, newest[k] }' \
  "$work/assets" | sort > "$work/newest"

total="$(wc -l < "$work/assets" | tr -d ' ')"
removed=0
kept_builds=0
removed_builds=0
while read -r key newest; do
  if reason="$(awk -v k="$key" '$1 == k { print $2; exit }' "$keep")" && [[ -n "$reason" ]]; then
    echo "Keep $key ($reason)"
  elif [[ "$newest" > "$cutoff" ]]; then
    echo "Keep $key (new, $newest)"
  else
    removed_builds=$((removed_builds + 1))
    while read -r _ _ _ id name; do
      echo "Remove $name"
      removed=$((removed + 1))
      if [[ "$dry_run" != true ]]; then
        # Another run can remove it first. That is not an error.
        gh api -X DELETE "repos/$REPO/releases/assets/$id" > /dev/null ||
          echo "::warning::Cannot remove $name"
      fi
    done < <(awk -v k="$key" '$1 == k' "$work/assets")
    continue
  fi
  kept_builds=$((kept_builds + 1))
done < "$work/newest"

echo "Assets: $total before, $((total - removed)) after. Builds: $kept_builds kept, $removed_builds removed."
